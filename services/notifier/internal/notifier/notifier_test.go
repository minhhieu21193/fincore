package notifier

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/aws-sdk-go-v2/service/sqs/types"

	"github.com/minhhieu21193/fincore/services/notifier/internal/signature"
)

type fakeSQS struct {
	mu         sync.Mutex
	deleted    []string
	visibility map[string]int32
}

func (f *fakeSQS) ReceiveMessage(context.Context, *sqs.ReceiveMessageInput, ...func(*sqs.Options)) (*sqs.ReceiveMessageOutput, error) {
	return &sqs.ReceiveMessageOutput{}, nil
}

func (f *fakeSQS) DeleteMessage(_ context.Context, in *sqs.DeleteMessageInput, _ ...func(*sqs.Options)) (*sqs.DeleteMessageOutput, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.deleted = append(f.deleted, aws.ToString(in.ReceiptHandle))
	return &sqs.DeleteMessageOutput{}, nil
}

func (f *fakeSQS) ChangeMessageVisibility(_ context.Context, in *sqs.ChangeMessageVisibilityInput, _ ...func(*sqs.Options)) (*sqs.ChangeMessageVisibilityOutput, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.visibility == nil {
		f.visibility = map[string]int32{}
	}
	f.visibility[aws.ToString(in.ReceiptHandle)] = in.VisibilityTimeout
	return &sqs.ChangeMessageVisibilityOutput{}, nil
}

const body = `{"event_id":"e-1","type":"payment.captured","payment":{"id":"p-1","merchant_id":"m_1"}}`

func msg(handle string, receives string) types.Message {
	return types.Message{
		Body:          aws.String(body),
		ReceiptHandle: aws.String(handle),
		MessageId:     aws.String("id-" + handle),
		Attributes:    map[string]string{"ApproximateReceiveCount": receives},
	}
}

func newConsumer(url string, q *fakeSQS) *Consumer {
	return &Consumer{
		SQS:           q,
		QueueURL:      "q",
		Directory:     Directory{Default: url},
		Sender:        &Sender{HTTP: http.DefaultClient, Secret: []byte("k"), Attempts: 3, Backoff: time.Millisecond, Now: time.Now},
		Concurrency:   1,
		MaxVisibility: time.Minute,
	}
}

func TestDeliverRetriesThenSucceedsAndDeletes(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		if err := signature.Verify([]byte("k"), b, r.Header.Get(signature.Header), time.Now(), time.Minute); err != nil {
			t.Errorf("bad signature: %v", err)
		}
		if r.Header.Get("FinCore-Event-Id") != "e-1" {
			t.Errorf("missing event id header")
		}
		if calls.Add(1) < 3 {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	q := &fakeSQS{}
	newConsumer(srv.URL, q).Handle(context.Background(), msg("h1", "1"))
	if calls.Load() != 3 {
		t.Fatalf("calls = %d, want 3", calls.Load())
	}
	if len(q.deleted) != 1 || q.deleted[0] != "h1" {
		t.Fatalf("deleted = %v, want [h1]", q.deleted)
	}
}

func TestFailureLeavesMessageForRedeliveryWithBackoff(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer srv.Close()

	q := &fakeSQS{}
	newConsumer(srv.URL, q).Handle(context.Background(), msg("h2", "3"))
	if len(q.deleted) != 0 {
		t.Fatal("failed delivery must not delete the message")
	}
	if got := q.visibility["h2"]; got != 20 {
		t.Fatalf("visibility = %d, want 20s for third receive", got)
	}
}

func TestPermanentFailureIsNotRetriedInProcess(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		calls.Add(1)
		w.WriteHeader(http.StatusGone)
	}))
	defer srv.Close()

	q := &fakeSQS{}
	newConsumer(srv.URL, q).Handle(context.Background(), msg("h3", "1"))
	if calls.Load() != 1 {
		t.Fatalf("calls = %d, want 1", calls.Load())
	}
	if len(q.deleted) != 0 {
		t.Fatal("permanently failing message must go to the DLQ, not be deleted")
	}
}

func TestNoEndpointAcknowledges(t *testing.T) {
	q := &fakeSQS{}
	newConsumer("", q).Handle(context.Background(), msg("h4", "1"))
	if len(q.deleted) != 1 {
		t.Fatal("event for a merchant without endpoint should be acknowledged")
	}
}

func TestRedeliveryDelay(t *testing.T) {
	cases := map[int]time.Duration{0: 5 * time.Second, 1: 5 * time.Second, 2: 10 * time.Second, 4: 40 * time.Second, 20: 5 * time.Minute}
	for n, want := range cases {
		if got := RedeliveryDelay(n, 5*time.Minute); got != want {
			t.Errorf("RedeliveryDelay(%d) = %s, want %s", n, got, want)
		}
	}
}

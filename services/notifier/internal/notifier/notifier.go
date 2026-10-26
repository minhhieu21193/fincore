// Package notifier consumes payment events from SQS and delivers them to
// merchant webhooks.
//
// Delivery semantics: at-least-once. A message is deleted only after the
// merchant acknowledged it with a 2xx. On failure it is left on the queue
// with an increasing visibility timeout, so SQS redelivers it later; after
// the queue's maxReceiveCount the redrive policy moves it to the DLQ.
// Receivers deduplicate on the FinCore-Event-Id header.
package notifier

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"strconv"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/aws-sdk-go-v2/service/sqs/types"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"

	"github.com/minhhieu21193/fincore/internal/platform/httpx"
	"github.com/minhhieu21193/fincore/services/notifier/internal/signature"
)

var (
	deliveries = promauto.With(httpx.Registry).NewCounterVec(prometheus.CounterOpts{
		Name: "webhook_deliveries_total",
		Help: "Webhook delivery outcomes (success, retry_later, no_endpoint, malformed).",
	}, []string{"result"})
	deliveryDuration = promauto.With(httpx.Registry).NewHistogram(prometheus.HistogramOpts{
		Name:    "webhook_delivery_duration_seconds",
		Help:    "Time to deliver one webhook including in-process retries.",
		Buckets: prometheus.DefBuckets,
	})
	received = promauto.With(httpx.Registry).NewCounter(prometheus.CounterOpts{
		Name: "events_received_total",
		Help: "Messages received from the event queue.",
	})
)

// SQSAPI is the subset of the SQS client the consumer uses.
type SQSAPI interface {
	ReceiveMessage(ctx context.Context, in *sqs.ReceiveMessageInput, opts ...func(*sqs.Options)) (*sqs.ReceiveMessageOutput, error)
	DeleteMessage(ctx context.Context, in *sqs.DeleteMessageInput, opts ...func(*sqs.Options)) (*sqs.DeleteMessageOutput, error)
	ChangeMessageVisibility(ctx context.Context, in *sqs.ChangeMessageVisibilityInput, opts ...func(*sqs.Options)) (*sqs.ChangeMessageVisibilityOutput, error)
}

// Directory resolves a merchant's webhook endpoint.
type Directory struct {
	Endpoints map[string]string // merchant_id -> URL
	Default   string            // used when the merchant has no explicit endpoint
}

// Lookup returns the endpoint for merchantID, or "" if none.
func (d Directory) Lookup(merchantID string) string {
	if u, ok := d.Endpoints[merchantID]; ok {
		return u
	}
	return d.Default
}

// Sender POSTs signed webhooks with bounded in-process retries.
type Sender struct {
	HTTP     *http.Client
	Secret   []byte
	Attempts int
	Backoff  time.Duration
	Now      func() time.Time
}

// errPermanent marks responses that retrying will not fix (4xx other than 408/429).
var errPermanent = errors.New("permanent webhook failure")

// Deliver sends body to url. It returns nil on a 2xx response.
func (s *Sender) Deliver(ctx context.Context, url, eventID, eventType string, body []byte) error {
	var lastErr error
	for attempt := range s.Attempts {
		if attempt > 0 {
			select {
			case <-time.After(s.Backoff * time.Duration(1<<(attempt-1))):
			case <-ctx.Done():
				return ctx.Err()
			}
		}
		lastErr = s.once(ctx, url, eventID, eventType, body)
		if lastErr == nil || errors.Is(lastErr, errPermanent) {
			return lastErr
		}
	}
	return lastErr
}

func (s *Sender) once(ctx context.Context, url, eventID, eventType string, body []byte) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("%w: %w", errPermanent, err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("FinCore-Event-Id", eventID)
	req.Header.Set("FinCore-Event-Type", eventType)
	req.Header.Set(signature.Header, signature.Sign(s.Secret, body, s.Now()))
	resp, err := s.HTTP.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	switch {
	case resp.StatusCode >= 200 && resp.StatusCode < 300:
		return nil
	case resp.StatusCode == http.StatusRequestTimeout || resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode >= 500:
		return fmt.Errorf("webhook endpoint returned %d", resp.StatusCode)
	default:
		return fmt.Errorf("%w: endpoint returned %d", errPermanent, resp.StatusCode)
	}
}

// Consumer pulls events from SQS and hands them to the Sender.
type Consumer struct {
	SQS         SQSAPI
	QueueURL    string
	Directory   Directory
	Sender      *Sender
	Concurrency int
	// MaxVisibility caps the redelivery delay applied after a failure.
	MaxVisibility time.Duration
}

type event struct {
	EventID string `json:"event_id"`
	Type    string `json:"type"`
	Payment struct {
		ID         string `json:"id"`
		MerchantID string `json:"merchant_id"`
	} `json:"payment"`
}

// Run polls until ctx is cancelled. In-flight deliveries finish first.
func (c *Consumer) Run(ctx context.Context) {
	var wg sync.WaitGroup
	sem := make(chan struct{}, c.Concurrency)
	for ctx.Err() == nil {
		out, err := c.SQS.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
			QueueUrl:                    aws.String(c.QueueURL),
			MaxNumberOfMessages:         10,
			WaitTimeSeconds:             10,
			VisibilityTimeout:           30,
			MessageSystemAttributeNames: []types.MessageSystemAttributeName{types.MessageSystemAttributeNameApproximateReceiveCount},
		})
		if err != nil {
			if ctx.Err() == nil {
				slog.Warn("receive messages", "error", err)
				time.Sleep(2 * time.Second)
			}
			continue
		}
		for _, m := range out.Messages {
			received.Inc()
			sem <- struct{}{}
			wg.Go(func() {
				defer func() { <-sem }()
				c.Handle(context.WithoutCancel(ctx), m)
			})
		}
	}
	wg.Wait()
}

// Handle processes one message.
func (c *Consumer) Handle(ctx context.Context, m types.Message) {
	start := time.Now()
	body := []byte(aws.ToString(m.Body))
	var ev event
	if err := json.Unmarshal(body, &ev); err != nil || ev.EventID == "" {
		// Leave it: after maxReceiveCount it lands in the DLQ for inspection.
		deliveries.WithLabelValues("malformed").Inc()
		slog.Error("malformed event; leaving for DLQ", "message_id", aws.ToString(m.MessageId), "error", err)
		return
	}
	log := slog.With("event_id", ev.EventID, "event_type", ev.Type, "payment_id", ev.Payment.ID)

	url := c.Directory.Lookup(ev.Payment.MerchantID)
	if url == "" {
		deliveries.WithLabelValues("no_endpoint").Inc()
		log.Info("merchant has no webhook endpoint; acknowledging")
		c.delete(ctx, m, log)
		return
	}

	err := c.Sender.Deliver(ctx, url, ev.EventID, ev.Type, body)
	deliveryDuration.Observe(time.Since(start).Seconds())
	if err == nil {
		deliveries.WithLabelValues("success").Inc()
		log.Info("webhook delivered")
		c.delete(ctx, m, log)
		return
	}

	deliveries.WithLabelValues("retry_later").Inc()
	receives, _ := strconv.Atoi(m.Attributes[string(types.MessageSystemAttributeNameApproximateReceiveCount)])
	delay := RedeliveryDelay(receives, c.MaxVisibility)
	log.Warn("webhook delivery failed; SQS will redeliver", "error", err, "receive_count", receives, "retry_in", delay.String())
	if _, verr := c.SQS.ChangeMessageVisibility(ctx, &sqs.ChangeMessageVisibilityInput{
		QueueUrl:          aws.String(c.QueueURL),
		ReceiptHandle:     m.ReceiptHandle,
		VisibilityTimeout: int32(delay.Seconds()),
	}); verr != nil {
		log.Warn("change visibility", "error", verr)
	}
}

func (c *Consumer) delete(ctx context.Context, m types.Message, log *slog.Logger) {
	if _, err := c.SQS.DeleteMessage(ctx, &sqs.DeleteMessageInput{QueueUrl: aws.String(c.QueueURL), ReceiptHandle: m.ReceiptHandle}); err != nil {
		log.Warn("delete message (it will be redelivered and deduplicated by the receiver)", "error", err)
	}
}

// RedeliveryDelay is an exponential backoff on the SQS receive count:
// 5s, 10s, 20s, 40s ... capped at maxDelay.
func RedeliveryDelay(receiveCount int, maxDelay time.Duration) time.Duration {
	if receiveCount < 1 {
		receiveCount = 1
	}
	d := 5 * time.Second * time.Duration(math.Pow(2, float64(min(receiveCount-1, 16))))
	return min(d, maxDelay)
}

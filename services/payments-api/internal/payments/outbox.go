package payments

import (
	"context"
	"errors"
	"log/slog"
	"strconv"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/aws-sdk-go-v2/service/sqs/types"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"

	"github.com/minhhieu21193/fincore/internal/platform/httpx"
)

var (
	outboxPublished = promauto.With(httpx.Registry).NewCounter(prometheus.CounterOpts{
		Name: "outbox_events_published_total",
		Help: "Outbox events delivered to the event queue.",
	})
	outboxErrors = promauto.With(httpx.Registry).NewCounter(prometheus.CounterOpts{
		Name: "outbox_publish_errors_total",
		Help: "Failed outbox relay iterations.",
	})
	outboxBacklog = promauto.With(httpx.Registry).NewGauge(prometheus.GaugeOpts{
		Name: "outbox_backlog_events",
		Help: "Outbox events not yet published.",
	})
)

// SQSPublisher publishes outbox messages with SendMessageBatch.
type SQSPublisher struct {
	Client   *sqs.Client
	QueueURL string
}

// Publish implements Publisher. Batches are at most 10 messages (SQS limit),
// which RunRelay guarantees.
func (p *SQSPublisher) Publish(ctx context.Context, msgs []OutboxMessage) ([]int64, error) {
	entries := make([]types.SendMessageBatchRequestEntry, len(msgs))
	for i, m := range msgs {
		entries[i] = types.SendMessageBatchRequestEntry{
			Id:          aws.String(strconv.FormatInt(m.ID, 10)),
			MessageBody: aws.String(string(m.Payload)),
			MessageAttributes: map[string]types.MessageAttributeValue{
				"event_type": {DataType: aws.String("String"), StringValue: aws.String(m.EventType)},
				"event_id":   {DataType: aws.String("String"), StringValue: aws.String(m.EventID.String())},
			},
		}
	}
	out, err := p.Client.SendMessageBatch(ctx, &sqs.SendMessageBatchInput{QueueUrl: aws.String(p.QueueURL), Entries: entries})
	if err != nil {
		return nil, err
	}
	accepted := make([]int64, 0, len(out.Successful))
	for _, s := range out.Successful {
		id, err := strconv.ParseInt(aws.ToString(s.Id), 10, 64)
		if err == nil {
			accepted = append(accepted, id)
		}
	}
	if len(out.Failed) > 0 {
		return accepted, errors.New("some outbox messages were rejected: " + aws.ToString(out.Failed[0].Message))
	}
	return accepted, nil
}

// RunRelay drains the outbox until ctx is cancelled.
func RunRelay(ctx context.Context, store *Store, pub Publisher, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	lastBacklog := time.Time{}
	for {
		for {
			n, err := store.RelayOnce(ctx, pub, 10)
			outboxPublished.Add(float64(n))
			if err != nil {
				if ctx.Err() == nil {
					outboxErrors.Inc()
					slog.Warn("outbox relay", "error", err)
				}
				break
			}
			if n < 10 {
				break
			}
		}
		if time.Since(lastBacklog) > 10*time.Second {
			if n, err := store.OutboxBacklog(ctx); err == nil {
				outboxBacklog.Set(float64(n))
			}
			lastBacklog = time.Now()
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

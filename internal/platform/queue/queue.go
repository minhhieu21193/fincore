// Package queue builds an SQS client. On AWS it uses the default credential
// chain (EKS Pod Identity). Locally SQS_ENDPOINT points it at an
// SQS-compatible server (ElasticMQ) instead.
package queue

import (
	"context"
	"os"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/smithy-go/tracing/smithyoteltracing"
	"go.opentelemetry.io/otel"

	"github.com/minhhieu21193/fincore/internal/platform/config"
)

// NewSQS returns an SQS client configured from the environment.
func NewSQS(ctx context.Context) (*sqs.Client, error) {
	cfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(config.String("AWS_REGION", "ap-southeast-1")))
	if err != nil {
		return nil, err
	}
	endpoint := os.Getenv("SQS_ENDPOINT")
	return sqs.NewFromConfig(cfg, func(o *sqs.Options) {
		o.TracerProvider = smithyoteltracing.Adapt(otel.GetTracerProvider())
		if endpoint != "" {
			o.BaseEndpoint = aws.String(endpoint)
		}
	}), nil
}

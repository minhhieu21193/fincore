# syntax=docker/dockerfile:1.20@sha256:26147acbda4f14c5add9946e2fd2ed543fc402884fd75146bd342a7f6271dc1d
# checkov:skip=CKV_DOCKER_2:Kubernetes ignores Docker HEALTHCHECK; the chart defines startup/liveness/readiness probes (distroless has no shell to run one)
#
# One Dockerfile for every FinCore binary:
#   docker build -f build/Dockerfile --build-arg SERVICE=payments-api --build-arg CMD=payments-api .
# FAULT_RATE > 0 produces the deliberately bad build used in the canary demo.

FROM --platform=$BUILDPLATFORM golang:1.27.3-alpine3.23@sha256:754d5200fc3edae76d3b6598a9a3fac7e74981ee6a5413ab955025f185753ef2 AS build
ARG SERVICE
ARG CMD=${SERVICE}
ARG VERSION=dev
ARG COMMIT=unknown
ARG FAULT_RATE=0
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY internal ./internal
COPY services ./services
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    test -n "$SERVICE" && \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath \
      -ldflags "-s -w \
        -X github.com/minhhieu21193/fincore/internal/platform/buildinfo.Version=${VERSION} \
        -X github.com/minhhieu21193/fincore/internal/platform/buildinfo.Commit=${COMMIT} \
        -X github.com/minhhieu21193/fincore/internal/platform/buildinfo.FaultRate=${FAULT_RATE}" \
      -o /out/app ./services/${SERVICE}/cmd/${CMD}

FROM gcr.io/distroless/static-debian13:nonroot@sha256:18f4cc26c9ffa7f20a359298be7deadac5c607c8e03a02b8119f1a5fc2f82c99
COPY --from=build /out/app /app
USER 65532:65532
EXPOSE 8080 9090
ENTRYPOINT ["/app"]

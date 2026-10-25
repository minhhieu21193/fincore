# syntax=docker/dockerfile:1.20@sha256:26147acbda4f14c5add9946e2fd2ed543fc402884fd75146bd342a7f6271dc1d
# Local-only read-only git server for Argo CD on kind (see tools/gitserver).
FROM --platform=$BUILDPLATFORM golang:1.27.3-alpine3.23@sha256:754d5200fc3edae76d3b6598a9a3fac7e74981ee6a5413ab955025f185753ef2 AS build
ARG TARGETOS
ARG TARGETARCH
WORKDIR /src
COPY go.mod go.sum ./
COPY tools ./tools
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags "-s -w" -o /out/gitserver ./tools/gitserver

FROM alpine/git:2.54.0@sha256:e8ceedc73bd80992ae8d58a7d24c58b8322146c354f1d2e81a97db4452068ec0
# The repository is bind-mounted and owned by the host user.
RUN git config --system safe.directory '*' && git config --system uploadpack.allowAnySHA1InWant true
COPY --from=build /out/gitserver /usr/local/bin/gitserver
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/gitserver"]

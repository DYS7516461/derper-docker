# syntax=docker/dockerfile:1

ARG TAILSCALE_VERSION=v1.86.2
ARG GO_IMAGE=golang:1.25-bookworm

FROM ${GO_IMAGE} AS builder

ARG TAILSCALE_VERSION

ENV CGO_ENABLED=0

RUN go install tailscale.com/cmd/derper@${TAILSCALE_VERSION}

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /go/bin/derper /usr/local/bin/derper

EXPOSE 80/tcp 443/tcp 3478/udp

ENTRYPOINT ["derper"]

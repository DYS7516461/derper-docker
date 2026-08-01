# syntax=docker/dockerfile:1

ARG TAILSCALE_VERSION=v1.86.2
ARG GO_IMAGE=golang:1.25-bookworm

FROM ${GO_IMAGE} AS builder

ARG TAILSCALE_VERSION

ENV CGO_ENABLED=0

RUN go install tailscale.com/cmd/derper@${TAILSCALE_VERSION}

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libcap2-bin \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /go/bin/derper /usr/local/bin/derper

RUN useradd -r -s /usr/sbin/nologin -u 1000 derper \
    && mkdir -p /var/lib/derper/certs \
    && chown -R derper:derper /var/lib/derper \
    && setcap cap_net_bind_service=+ep /usr/local/bin/derper

EXPOSE 80/tcp 443/tcp 3478/udp

USER derper

ENTRYPOINT ["derper"]

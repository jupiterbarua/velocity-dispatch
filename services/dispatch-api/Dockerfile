# syntax=docker/dockerfile:1
#
# Multi-stage build using cargo-chef so a source-only change (no new/updated
# dependency) reuses the cached dependency-compilation layer instead of
# rebuilding every crate in the dependency graph from scratch. On this
# workspace that's the difference between a ~2 minute CI build and a
# ~20 second one — worth the extra stage.

FROM lukemathwalker/cargo-chef:latest-rust-1 AS chef
WORKDIR /app

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json --bin dispatch-api

FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
# This RUN builds *only* dependencies, cached as long as recipe.json (i.e.
# the dependency graph) doesn't change.
RUN cargo chef cook --release --recipe-path recipe.json -p dispatch-api
COPY . .
RUN cargo build --release -p dispatch-api

# ---- Runtime image -------------------------------------------------------
# debian-slim rather than distroless/scratch: sqlx's TLS stack and the AWS
# SDK both ultimately want a CA bundle and (via rustls-native-certs) access
# to the system trust store, and slim keeps that a one-line apt-get instead
# of hand-rolling a cert bundle into a scratch image.
FROM debian:bookworm-slim AS runtime
# curl is included solely so `docker compose`'s HEALTHCHECK (see
# docker-compose.yml) can probe GET /health from inside the container.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin appuser
USER appuser
WORKDIR /app

COPY --from=builder /app/target/release/dispatch-api /usr/local/bin/dispatch-api

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/dispatch-api"]

# ---- Local dev image ------------------------------------------------------
# Debug profile: no `lto`/`codegen-units = 1` from Cargo.toml's
# [profile.release] applies here, because this never invokes `--release`.
# That profile was chosen deliberately for the *production* binary (smaller,
# faster at runtime — see README's "Low-latency decisions"), but paid for
# with a genuinely slow from-scratch compile — minutes-to-an-hour-plus on a
# real laptop, not CI's beefier runners. For local iteration that trade-off
# is backwards: docker-compose.yml targets this `dev` stage instead, which
# compiles in a fraction of the time. CI (ci.yml) and deploy (deploy.yml)
# both explicitly pass `target: runtime` and never build this stage, so the
# actual deployed artifact is always the fully-optimized one — this stage
# exists purely to make `docker compose up --build` usable.
FROM chef AS dev-builder
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --recipe-path recipe.json -p dispatch-api
COPY . .
RUN cargo build -p dispatch-api

FROM debian:bookworm-slim AS dev
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin appuser
USER appuser
WORKDIR /app

COPY --from=dev-builder /app/target/debug/dispatch-api /usr/local/bin/dispatch-api

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/dispatch-api"]

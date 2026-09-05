# syntax=docker/dockerfile:1
#
# Multi-stage build using cargo-chef so a source-only change (no new/updated
# dependency) reuses the cached dependency-compilation layer instead of
# rebuilding every crate in the dependency graph from scratch. On this
# workspace that's the difference between a ~2 minute CI build and a
# ~20 second one — worth the extra stage.
#
# Every `cargo` invocation below also mounts BuildKit cache volumes for the
# Cargo registry and the build directory (`--mount=type=cache`). Without
# these, the `builder` and `dev-builder` stages below would each
# independently re-download this workspace's entire dependency source tree
# from crates.io from scratch — including the large AWS SDK crates —
# because Docker stages don't share a filesystem with each other or across
# separate build invocations. These cache mounts persist on the local
# Docker host across builds and across stages, so that download/compile
# cost is paid once, not every time `docker compose up --build` runs.

FROM lukemathwalker/cargo-chef:latest-rust-1 AS chef
WORKDIR /app

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json --bin dispatch-api

FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
# This RUN builds *only* dependencies, cached as long as recipe.json (i.e.
# the dependency graph) doesn't change.
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/app/target,sharing=locked \
    cargo chef cook --release --recipe-path recipe.json -p dispatch-api
COPY . .
# The binary is copied out of the cache-mounted /app/target before this RUN
# ends — a cache mount's contents don't persist into the image layer, so a
# later `COPY --from=builder` wouldn't be able to see anything left inside
# /app/target once this step finishes.
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/app/target,sharing=locked \
    cargo build --release -p dispatch-api && \
    cp target/release/dispatch-api /app/dispatch-api-bin

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

COPY --from=builder /app/dispatch-api-bin /usr/local/bin/dispatch-api

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
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/app/target,sharing=locked \
    cargo chef cook --recipe-path recipe.json -p dispatch-api
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/app/target,sharing=locked \
    cargo build -p dispatch-api && \
    cp target/debug/dispatch-api /app/dispatch-api-bin

FROM debian:bookworm-slim AS dev
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin appuser
USER appuser
WORKDIR /app

COPY --from=dev-builder /app/dispatch-api-bin /usr/local/bin/dispatch-api

EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/dispatch-api"]

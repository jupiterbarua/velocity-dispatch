# syntax=docker/dockerfile:1
#
# Every `cargo` invocation below mounts BuildKit cache volumes for the
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
RUN cargo chef prepare --recipe-path recipe.json --bin dispatch-worker

FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/app/target,sharing=locked \
    cargo chef cook --release --recipe-path recipe.json -p dispatch-worker
COPY . .
# The binary is copied out of the cache-mounted /app/target before this RUN
# ends — a cache mount's contents don't persist into the image layer, so a
# later `COPY --from=builder` wouldn't be able to see anything left inside
# /app/target once this step finishes.
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/app/target,sharing=locked \
    cargo build --release -p dispatch-worker && \
    cp target/release/dispatch-worker /app/dispatch-worker-bin

FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin appuser
USER appuser
WORKDIR /app

COPY --from=builder /app/dispatch-worker-bin /usr/local/bin/dispatch-worker

ENTRYPOINT ["/usr/local/bin/dispatch-worker"]

# ---- Local dev image ------------------------------------------------------
# Same rationale as the `dev` stage in services/dispatch-api/Dockerfile:
# skips `--release` (so none of Cargo.toml's [profile.release] lto/
# codegen-units=1 cost applies) so `docker compose up --build` finishes in
# minutes instead of a potential hour-plus on a real laptop. docker-compose.yml
# targets this stage; CI/deploy.yml explicitly target `runtime` and never
# build this one, so the deployed artifact is always the optimized build.
FROM chef AS dev-builder
COPY --from=planner /app/recipe.json recipe.json
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/app/target,sharing=locked \
    cargo chef cook --recipe-path recipe.json -p dispatch-worker
COPY . .
RUN --mount=type=cache,target=/usr/local/cargo/registry,sharing=locked \
    --mount=type=cache,target=/app/target,sharing=locked \
    cargo build -p dispatch-worker && \
    cp target/debug/dispatch-worker /app/dispatch-worker-bin

FROM debian:bookworm-slim AS dev
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin appuser
USER appuser
WORKDIR /app

COPY --from=dev-builder /app/dispatch-worker-bin /usr/local/bin/dispatch-worker

ENTRYPOINT ["/usr/local/bin/dispatch-worker"]

# syntax=docker/dockerfile:1
FROM lukemathwalker/cargo-chef:latest-rust-1 AS chef
WORKDIR /app

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json --bin dispatch-worker

FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json -p dispatch-worker
COPY . .
RUN cargo build --release -p dispatch-worker

FROM debian:bookworm-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin appuser
USER appuser
WORKDIR /app

COPY --from=builder /app/target/release/dispatch-worker /usr/local/bin/dispatch-worker

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
RUN cargo chef cook --recipe-path recipe.json -p dispatch-worker
COPY . .
RUN cargo build -p dispatch-worker

FROM debian:bookworm-slim AS dev
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin appuser
USER appuser
WORKDIR /app

COPY --from=dev-builder /app/target/debug/dispatch-worker /usr/local/bin/dispatch-worker

ENTRYPOINT ["/usr/local/bin/dispatch-worker"]

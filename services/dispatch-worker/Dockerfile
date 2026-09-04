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

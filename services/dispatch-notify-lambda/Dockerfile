# syntax=docker/dockerfile:1
#
# Builds the Lambda as a container image using the AWS-provided Rust base
# image for `provided.al2023`. Two deployment paths are documented in
# infra/terraform/lambda.tf: this container-image path, and a plain zip of
# the `bootstrap` binary built via `cargo lambda build --release`. The
# container path is included because it's what most teams with an existing
# Docker/ECR pipeline (like this project's dispatch-api/worker) actually use
# in practice — one build system for every deployable, not two.

FROM public.ecr.aws/lambda/provided:al2023 AS lambda-base

FROM lukemathwalker/cargo-chef:latest-rust-1 AS chef
WORKDIR /app

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path recipe.json --bin bootstrap

FROM chef AS builder
COPY --from=planner /app/recipe.json recipe.json
RUN cargo chef cook --release --recipe-path recipe.json -p dispatch-notify-lambda
COPY . .
RUN cargo build --release -p dispatch-notify-lambda

# Named `runtime` (not left anonymous) so CI/deploy.yml can pin
# `target: runtime` uniformly across all three services' Dockerfiles,
# instead of special-casing this one — see the same convention in
# dispatch-api/Dockerfile and dispatch-worker/Dockerfile.
FROM lambda-base AS runtime
COPY --from=builder /app/target/release/bootstrap /var/runtime/bootstrap
CMD ["bootstrap"]

use actix_web::{http::StatusCode, HttpResponse, ResponseError};
use serde::Serialize;
use thiserror::Error;

/// Alias so this doesn't force an unreadable, rustfmt-wrapped generic onto
/// one line (or several) wherever it's used — here and in `sqs.rs`'s
/// `publish` signature, which returns exactly this type. Boxed because
/// clippy's `result_large_err` flags the raw `SdkError` (it embeds a full
/// HTTP response and is ~368 bytes) as too large to return by value in a
/// `Result` — boxing moves that payload onto the heap so `Result<(), _>`
/// itself stays small. `Box<T>` gets `From<T>` for free from the standard
/// library, so the `?` operator in `sqs.rs::publish` still works unchanged.
pub(crate) type SqsSendError =
    Box<aws_sdk_sqs::error::SdkError<aws_sdk_sqs::operation::send_message::SendMessageError>>;

#[derive(Debug, Error)]
pub enum ApiError {
    #[error(transparent)]
    Core(#[from] dispatch_core::CoreError),

    #[error("database error")]
    Database(#[from] sqlx::Error),

    #[error("resource not found")]
    NotFound,
}

#[derive(Serialize)]
struct ErrorBody {
    error: String,
}

impl ResponseError for ApiError {
    fn status_code(&self) -> StatusCode {
        match self {
            ApiError::Core(dispatch_core::CoreError::NoDriverInRange { .. }) => {
                StatusCode::SERVICE_UNAVAILABLE
            }
            ApiError::Core(dispatch_core::CoreError::InvalidCoordinate { .. }) => {
                StatusCode::BAD_REQUEST
            }
            ApiError::Core(_) => StatusCode::UNPROCESSABLE_ENTITY,
            ApiError::NotFound => StatusCode::NOT_FOUND,
            ApiError::Database(_) => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }

    fn error_response(&self) -> HttpResponse {
        // Deliberately don't leak internal error detail (DB/SQS errors) to
        // the client — log it server-side (via `tracing::error!` at the call
        // site) and return a generic message. Core validation errors are
        // safe to echo back since they describe the caller's own input.
        let message = match self {
            ApiError::Database(_) => "internal server error".to_string(),
            other => other.to_string(),
        };
        HttpResponse::build(self.status_code()).json(ErrorBody { error: message })
    }
}

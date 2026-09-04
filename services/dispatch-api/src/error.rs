use actix_web::{http::StatusCode, HttpResponse, ResponseError};
use serde::Serialize;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum ApiError {
    #[error(transparent)]
    Core(#[from] dispatch_core::CoreError),

    #[error("database error")]
    Database(#[from] sqlx::Error),

    #[error("event publish error")]
    Publish(
        #[from]
        aws_sdk_sqs::error::SdkError<aws_sdk_sqs::operation::send_message::SendMessageError>,
    ),

    #[error("resource not found")]
    NotFound,

    #[error("invalid request: {0}")]
    BadRequest(String),
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
            ApiError::BadRequest(_) => StatusCode::BAD_REQUEST,
            ApiError::Database(_) | ApiError::Publish(_) => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }

    fn error_response(&self) -> HttpResponse {
        // Deliberately don't leak internal error detail (DB/SQS errors) to
        // the client — log it server-side (via `tracing::error!` at the call
        // site) and return a generic message. Core validation errors are
        // safe to echo back since they describe the caller's own input.
        let message = match self {
            ApiError::Database(_) | ApiError::Publish(_) => "internal server error".to_string(),
            other => other.to_string(),
        };
        HttpResponse::build(self.status_code()).json(ErrorBody { error: message })
    }
}

//! Unified error type for Operit.
//!
//! `OperitError` is the single cross-crate error type. It lives in the
//! lowest-level crate that every other crate already depends on
//! (`operit-util`), so it can be used everywhere without creating a
//! dependency cycle.
//!
//! ## Scope of this change (see architecture study §14.2 / §21.4)
//!
//! This module is the *type-level foundation*: the enum, the [`OperitResult`]
//! alias, and `From` conversions for the common `std` / `serde` / host / http
//! errors that every crate shares. Conversions provided out of the box:
//!
//! - [`std::io::Error`] → [`OperitError::Io`]
//! - [`serde_json::Error`] → [`OperitError::Json`]
//! - [`std::str::Utf8Error`] / [`std::string::FromUtf8Error`] → utf-8 variants
//! - [`operit_host_api::HostError`] → [`OperitError::Host`] (FFI/host boundary)
//! - [`reqwest::Error`] → [`OperitError::Http`]
//! - [`String`] / [`&str`] → [`OperitError::Message`]
//! - any other error → [`OperitError::External`] via [`OperitError::other`]
//!
//! Per-crate error enums (e.g. `SqliteStoreError`, `ModelConfigError`,
//! `AiServiceError`) are NOT removed here. Each crate adds
//! `impl From<LocalError> for OperitError` **in its own crate** — this is
//! legal under the orphan rule (local error type, foreign `OperitError`) and
//! avoids a cycle. That migration is mechanical and incremental; see
//! `operit-store`'s `SqliteStoreError` for the worked example.

use operit_host_api::HostError;
use thiserror::Error;

/// The unified Operit error type.
#[derive(Debug, Error)]
pub enum OperitError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("utf-8 decode error: {0}")]
    Utf8(#[from] std::str::Utf8Error),

    #[error("utf-8 conversion error: {0}")]
    FromUtf8(#[from] std::string::FromUtf8Error),

    #[error("http error: {0}")]
    Http(#[from] reqwest::Error),

    #[error("host error: {0}")]
    Host(#[from] HostError),

    #[error("operation timed out after {ms} ms")]
    Timeout { ms: u64 },

    #[error("operation cancelled")]
    Cancelled,

    #[error("not found: {0}")]
    NotFound(String),

    #[error("invalid argument: {0}")]
    InvalidArgument(String),

    #[error("{0}")]
    Message(String),

    #[error(transparent)]
    External(Box<dyn std::error::Error + Send + Sync + 'static>),
}

/// Convenience result alias used across crates.
pub type OperitResult<T> = Result<T, OperitError>;

impl OperitError {
    /// Wrap any foreign error type as [`OperitError::External`].
    ///
    /// Use this for error types that don't (yet) have a dedicated `From` impl,
    /// so `OperitError::other(some_fallible()?)` lets `?` propagate cleanly.
    pub fn other<E>(error: E) -> Self
    where
        E: std::error::Error + Send + Sync + 'static,
    {
        OperitError::External(Box::new(error))
    }

    /// Build a timeout error carrying the elapsed budget in milliseconds.
    ///
    /// Mirrors the tool-execution watchdog budget introduced in Fix J.
    pub fn timeout(ms: u64) -> Self {
        OperitError::Timeout { ms }
    }

    /// Build a cancellation error (used by the tool-execution watchdog, Fix J).
    pub fn cancelled() -> Self {
        OperitError::Cancelled
    }
}

impl From<String> for OperitError {
    fn from(value: String) -> Self {
        OperitError::Message(value)
    }
}

impl From<&str> for OperitError {
    fn from(value: &str) -> Self {
        OperitError::Message(value.to_string())
    }
}

//! `TracedMutex`: a drop-in `std::sync::Mutex` replacement that records *who*
//! currently holds the lock, so lock-contention deadlocks can be diagnosed from
//! device logs instead of guessed.
//!
//! Why this exists: on the iOS/WASM runtime the worker is single-threaded and
//! `std::sync::Mutex` is a spin lock. If one async task acquires the package
//! manager lock and then `.await`s without releasing, every other task that
//! calls `lock()` spins forever on the same thread (the holder can never resume
//! to release). That is exactly the 60s compose_dsl render freeze. `try_lock`
//! does NOT spin, so callers that can tolerate a miss (tool lifecycle
//! notifications / interception) should use `try_lock` and will instead get a
//! `pm.contention` log naming the holding task.
//!
//! Every `lock()` call records its own `file:line` via `#[track_caller]`, so no
//! call site needs manual labels.

use std::ops::{Deref, DerefMut};
use std::panic::Location;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex as StdMutex, MutexGuard, PoisonError};

use operit_util::ChainLogger::{self, TOOL_CHAIN};

/// Identity of the task currently holding the traced mutex.
#[derive(Clone, Copy)]
pub struct PmHolder {
    /// Monotonically increasing acquire id, used to match a guard's `Drop`.
    pub token: u64,
    /// `file:line` of the `lock()` call site that acquired it.
    pub loc: Location<'static>,
    /// Global lock-sequence number at acquire time (rough age proxy).
    pub seq: u64,
}

static PM_HOLDER: StdMutex<Option<PmHolder>> = StdMutex::new(None);
static PM_TOKEN: AtomicU64 = AtomicU64::new(0);
static PM_SEQ: AtomicU64 = AtomicU64::new(0);

pub struct TracedMutex<T> {
    inner: StdMutex<T>,
}

pub struct TracedGuard<'a, T> {
    inner: MutexGuard<'a, T>,
    token: u64,
}

impl<T> TracedMutex<T> {
    pub fn new(value: T) -> Self {
        Self {
            inner: StdMutex::new(value),
        }
    }

    /// Lock, recording the caller site (`file:line`) as the current holder.
    #[track_caller]
    pub fn lock(&self) -> Result<TracedGuard<'_, T>, PoisonError<TracedGuard<'_, T>>> {
        match self.inner.lock() {
            Ok(inner) => {
                let token = PM_TOKEN.fetch_add(1, Ordering::SeqCst) + 1;
                let seq = PM_SEQ.fetch_add(1, Ordering::SeqCst) + 1;
                {
                    let mut h = PM_HOLDER.lock().expect("pm holder meta poisoned");
                    *h = Some(PmHolder {
                        token,
                        loc: *Location::caller(),
                        seq,
                    });
                }
                Ok(TracedGuard { inner, token })
            }
            Err(e) => Err(PoisonError::new(TracedGuard {
                inner: e.into_inner(),
                token: 0,
            })),
        }
    }

    /// Non-blocking lock. On contention, logs who currently holds the lock and
    /// returns the holder info so the caller can decide how to proceed.
    pub fn try_lock(&self) -> Result<TracedGuard<'_, T>, Option<PmHolder>> {
        match self.inner.try_lock() {
            Ok(inner) => {
                let token = PM_TOKEN.fetch_add(1, Ordering::SeqCst) + 1;
                let seq = PM_SEQ.fetch_add(1, Ordering::SeqCst) + 1;
                {
                    let mut h = PM_HOLDER.lock().expect("pm holder meta poisoned");
                    *h = Some(PmHolder {
                        token,
                        loc: *Location::caller(),
                        seq,
                    });
                }
                Ok(TracedGuard { inner, token })
            }
            Err(_) => {
                let holder = PM_HOLDER.lock().expect("pm holder meta poisoned").clone();
                match &holder {
                    Some(h) => ChainLogger::warn(
                        TOOL_CHAIN,
                        "pm.contention",
                        &[
                            ("holder", format!("{}:{}", h.loc.file(), h.loc.line())),
                            ("token", h.token.to_string()),
                            ("seq", h.seq.to_string()),
                        ],
                    ),
                    None => ChainLogger::warn(
                        TOOL_CHAIN,
                        "pm.contention",
                        &[("holder", "unknown".to_string())],
                    ),
                }
                Err(holder)
            }
        }
    }
}

impl<T> Deref for TracedGuard<'_, T> {
    type Target = T;
    fn deref(&self) -> &T {
        &self.inner
    }
}

impl<T> DerefMut for TracedGuard<'_, T> {
    fn deref_mut(&mut self) -> &mut T {
        &mut self.inner
    }
}

impl<T> Drop for TracedGuard<'_, T> {
    fn drop(&mut self) {
        let mut h = PM_HOLDER.lock().expect("pm holder meta poisoned");
        if let Some(cur) = h.as_ref() {
            if cur.token == self.token {
                *h = None;
            }
        }
    }
}

//! Application-Not-Responding watchdog for the Rust core.
//!
//! operit1 shipped a ~400-line [`AnrMonitor`] on Android that sampled the main
//! thread and dumped a full thread trace on unresponsiveness. operit2's version
//! was a 2-line empty shell, so the signature bug class — a worker thread
//! self-deadlocking for ~60s — was invisible: you could only read source and
//! guess (see the architecture study, §12.1). This fills that gap.
//!
//! Design (cross-platform, lock-free on the hot path):
//! - The monitored thread calls [`AnrMonitor::beat()`] on its hot path. `beat`
//!   is cheap: it only stores a monotonic timestamp, and samples the calling
//!   thread's own backtrace at most once per [`SAMPLE_INTERVAL`]. No global
//!   mutex is taken on the hot path, so a stuck peer cannot block the beat.
//! - A single background watchdog thread (spawned by [`start_monitoring`])
//!   wakes every [`WATCHDOG_TICK`]; if the monitored thread has not beaten for
//!   longer than `threshold`, it emits an ANR report: "thread X unresponsive for
//!   Nms" plus the *last sampled stack* of that thread (where it was last seen
//!   alive). The report goes to stderr and is appended — lock-free — to the same
//!   `operit.log` file the panic hook already knows about, so it shows up in the
//!   on-device log viewer without touching `AppLogger`'s own STATE mutex.
//!
//! Limitations (call them out, don't hide them):
//! - This monitors one Rust thread (the one that calls `beat`). The historical
//!   60s freeze was a worker deadlock; beating on the Flutter↔Rust dispatch
//!   thread catches the case where the core stops answering the UI. A Dart UI
//!   thread-only freeze is out of reach from Rust and needs a Dart-side guard.
//! - We capture the monitored thread's *own* last-alive stack, not every
//!   thread's stack. A full all-threads capture needs platform APIs
//!   (Mach `task_threads` / `/proc`); intentionally out of scope for Fix C.
//! - `wasm32` has no threads and no `native_call` entry point, so everything
//!   here is a no-op there.

use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Mutex, Once, OnceLock};
use std::time::{Duration, Instant};

#[cfg(not(target_arch = "wasm32"))]
use std::thread;

/// How often the watchdog wakes to check liveness.
const WATCHDOG_TICK: Duration = Duration::from_secs(1);
/// Minimum gap between backtrace samples taken on the monitored thread.
const SAMPLE_INTERVAL: Duration = Duration::from_secs(2);

/// Immutable monitor configuration, set once by [`start_monitoring`].
struct AnrConfig {
    name: String,
    start: Instant,
    threshold_ms: i64,
}

static CONFIG: OnceLock<AnrConfig> = OnceLock::new();
static STARTED: Once = Once::new();
static LAST_BEAT_MS: AtomicI64 = AtomicI64::new(0);
static LAST_SAMPLE_MS: AtomicI64 = AtomicI64::new(i64::MIN);
static LAST_BACKTRACE: Mutex<String> = Mutex::new(String::new());
static REPORTED: AtomicBool = AtomicBool::new(false);

/// Lightweight ANR watchdog. See the module docs for the contract.
pub struct AnrMonitor;

impl AnrMonitor {
    /// Starts monitoring the thread that will call [`beat`]. Spawns a single
    /// background watchdog thread. Idempotent: only the first call takes effect.
    /// No-op on `wasm32` (no threads / no dispatch entry point).
    #[cfg(not(target_arch = "wasm32"))]
    pub fn start_monitoring(name: &str, threshold: Duration) {
        STARTED.call_once(|| {
            let _ = CONFIG.set(AnrConfig {
                name: name.to_string(),
                start: Instant::now(),
                threshold_ms: threshold.as_millis().min(i64::MAX as u128) as i64,
            });
            LAST_BEAT_MS.store(0, Ordering::Relaxed);
            let _ = thread::Builder::new()
                .name("anr-watchdog".to_string())
                .spawn(watchdog_loop);
        });
    }

    /// No-op variant for platforms without threads.
    #[cfg(target_arch = "wasm32")]
    pub fn start_monitoring(_name: &str, _threshold: Duration) {}

    /// Records liveness from the monitored thread. Cheap on the hot path;
    /// samples the calling thread's own backtrace at most once per
    /// [`SAMPLE_INTERVAL`] so a later ANR report can show where the thread was
    /// last seen alive. No-op before [`start_monitoring`] or on `wasm32`.
    pub fn beat() {
        #[cfg(not(target_arch = "wasm32"))]
        {
            let Some(config) = CONFIG.get() else { return };
            let elapsed_ms = config.start.elapsed().as_millis().min(i64::MAX as u128) as i64;
            LAST_BEAT_MS.store(elapsed_ms, Ordering::Relaxed);
            if elapsed_ms - LAST_SAMPLE_MS.load(Ordering::Relaxed)
                >= SAMPLE_INTERVAL.as_millis() as i64
            {
                LAST_SAMPLE_MS.store(elapsed_ms, Ordering::Relaxed);
                if let Ok(mut slot) = LAST_BACKTRACE.lock() {
                    *slot = std::backtrace::Backtrace::force_capture().to_string();
                }
            }
            // Resume reporting once the thread is responsive again.
            if REPORTED.load(Ordering::Relaxed) {
                REPORTED.store(false, Ordering::Relaxed);
            }
        }
    }

    /// Emits an ANR report immediately, regardless of the timer.
    pub fn report_now() {
        #[cfg(not(target_arch = "wasm32"))]
        {
            if CONFIG.get().is_some() {
                emit_report();
            }
        }
    }
}

#[cfg(not(target_arch = "wasm32"))]
fn watchdog_loop() {
    loop {
        thread::sleep(WATCHDOG_TICK);
        let Some(config) = CONFIG.get() else { return };
        let since_beat =
            config.start.elapsed().as_millis() as i64 - LAST_BEAT_MS.load(Ordering::Relaxed);
        if since_beat >= config.threshold_ms && !REPORTED.load(Ordering::Relaxed) {
            REPORTED.store(true, Ordering::Relaxed);
            emit_report();
        }
    }
}

#[cfg(not(target_arch = "wasm32"))]
fn emit_report() {
    let Some(config) = CONFIG.get() else { return };
    let since_beat =
        config.start.elapsed().as_millis() as i64 - LAST_BEAT_MS.load(Ordering::Relaxed);
    let backtrace = LAST_BACKTRACE
        .try_lock()
        .map(|guard| guard.clone())
        .unwrap_or_default();
    let report = format!(
        "ANR: thread '{}' unresponsive for {}ms (threshold {}ms).\n\
         Last sampled stack of '{}':\n{}",
        config.name, since_beat, config.threshold_ms, config.name, backtrace
    );
    // Always surface to stderr (lock-free, never blocked by other mutexes).
    eprintln!("[ANR] {report}");
    // Append to the operit.log path the panic hook already knows about, so the
    // report lands in the same on-device log file the app viewer reads, without
    // touching AppLogger's own STATE mutex (which a deadlock might hold).
    if let Some(path) = crate::AppLogger::PANIC_LOG_PATH.get() {
        use std::fs::OpenOptions;
        use std::io::Write as _;
        let _ = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .and_then(|mut file| file.write_all(format!("[ANR] {report}\n").as_bytes()));
    }
    // Best-effort: also record into AppLogger's in-memory ring so the report is
    // visible in-app. Guarded so a poisoned STATE can never kill the watchdog.
    let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        crate::AppLogger::AppLogger::e("ANR", &report);
    }));
}

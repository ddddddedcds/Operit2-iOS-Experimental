use std::collections::VecDeque;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use operit_host_api::{
    HostError, HostResult, ManagedRuntimeHost, ManagedRuntimeProcess, ManagedRuntimeProgram,
    RuntimeCommandOutput, RuntimeProcessRequest,
};

const MANAGED_RUNTIME_STDIO_BUFFER_BYTES: usize = 64 * 1024;
const MANAGED_RUNTIME_SINGLE_FRAME_MIN_BYTES: usize = 4 * 1024;

/// Starts iOS MCP runtimes as direct system processes (jailbroken system shell).
#[derive(Clone, Default)]
pub struct IosManagedRuntimeHost;

impl IosManagedRuntimeHost {
    /// Creates an iOS managed runtime host running programs on the system shell.
    pub fn new() -> Self {
        Self
    }
}

struct IosManagedRuntimeProcess {
    child: Mutex<Child>,
    stdin: Mutex<ChildStdin>,
    stdoutRx: Mutex<Receiver<String>>,
    stderrLines: Arc<Mutex<VecDeque<String>>>,
}

impl ManagedRuntimeProcess for IosManagedRuntimeProcess {
    /// Writes one protocol line to the managed runtime stdin.
    fn writeLine(&self, line: &str) -> HostResult<()> {
        let mut stdin = self
            .stdin
            .lock()
            .map_err(|_| HostError::new("stdin mutex poisoned"))?;
        writeManagedRuntimeLine(&mut *stdin, line)
    }

    /// Writes multiple protocol lines to the managed runtime stdin.
    fn writeLines(&self, lines: &[String]) -> HostResult<()> {
        let mut stdin = self
            .stdin
            .lock()
            .map_err(|_| HostError::new("stdin mutex poisoned"))?;
        writeManagedRuntimeLines(&mut *stdin, lines)
    }

    /// Reads one protocol line from the managed runtime stdout queue.
    fn readStdoutLine(&self, timeoutMs: u64) -> HostResult<Option<String>> {
        let receiver = self
            .stdoutRx
            .lock()
            .map_err(|_| HostError::new("stdout mutex poisoned"))?;
        match receiver.recv_timeout(Duration::from_millis(timeoutMs)) {
            Ok(line) => Ok(Some(line)),
            Err(mpsc::RecvTimeoutError::Timeout) => Ok(None),
            Err(mpsc::RecvTimeoutError::Disconnected) => Ok(None),
        }
    }

    /// Drains buffered stderr lines collected from the managed runtime.
    fn drainStderr(&self) -> HostResult<String> {
        let mut lines = self
            .stderrLines
            .lock()
            .map_err(|_| HostError::new("stderr mutex poisoned"))?;
        Ok(joinManagedRuntimeStderrLines(&mut lines))
    }

    /// Returns whether the managed runtime process is still alive.
    fn isRunning(&self) -> HostResult<bool> {
        let mut child = self
            .child
            .lock()
            .map_err(|_| HostError::new("child mutex poisoned"))?;
        Ok(child.try_wait()?.is_none())
    }

    /// Terminates the managed runtime process.
    fn kill(&self) -> HostResult<()> {
        let mut child = self
            .child
            .lock()
            .map_err(|_| HostError::new("child mutex poisoned"))?;
        match child.try_wait()? {
            Some(_) => Ok(()),
            None => {
                child.kill()?;
                Ok(())
            }
        }
    }
}

impl ManagedRuntimeHost for IosManagedRuntimeHost {
    /// Returns the persistent iOS managed runtime workspace directory on the system filesystem.
    fn runtimeWorkspaceDir(&self) -> HostResult<String> {
        let dir = iosRuntimeWorkspaceDir();
        std::fs::create_dir_all(&dir)?;
        Ok(dir)
    }

    /// Resolves a managed runtime executable on the jailbroken system shell.
    fn resolveRuntimeExecutable(
        &self,
        program: ManagedRuntimeProgram,
        executablePath: Option<&str>,
    ) -> HostResult<String> {
        Ok(match executablePath.map(str::trim) {
            Some(value) if !value.is_empty() => value.to_string(),
            // 系统 shell 通过 PATH 解析这些命令，不硬编码绝对路径（越狱环境
            // node/python 可能装在 /usr/bin、/var/jb/usr/bin 等不同位置）。
            _ => match program {
                ManagedRuntimeProgram::Node => "node".to_string(),
                ManagedRuntimeProgram::Python => "python3".to_string(),
                ManagedRuntimeProgram::Uv => "uv".to_string(),
                ManagedRuntimeProgram::Pnpm => "pnpm".to_string(),
            },
        })
    }

    /// Starts a persistent iOS managed runtime process with piped stdio.
    fn startRuntimeProcess(
        &self,
        request: RuntimeProcessRequest,
    ) -> HostResult<Box<dyn ManagedRuntimeProcess>> {
        let executable = self
            .resolveRuntimeExecutable(request.program.clone(), request.executablePath.as_deref())?;
        let mut command = std::process::Command::new(&executable);
        if let Some(cwd) = request.cwd.as_deref() {
            command.current_dir(cwd);
        }
        command.args(request.args);
        command.envs(request.env);
        command.stdin(Stdio::piped());
        command.stdout(Stdio::piped());
        command.stderr(Stdio::piped());

        let mut child = command
            .spawn()
            .map_err(|error| HostError::new(format!("failed to start {executable}: {error}")))?;
        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| HostError::new("managed runtime process has no stdin"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| HostError::new("managed runtime process has no stdout"))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| HostError::new("managed runtime process has no stderr"))?;

        let (stdoutTx, stdoutRx) = mpsc::channel();
        thread::spawn(move || {
            for line in BufReader::with_capacity(MANAGED_RUNTIME_STDIO_BUFFER_BYTES, stdout)
                .lines()
                .flatten()
            {
                let _ = stdoutTx.send(line);
            }
        });

        let stderrLines = Arc::new(Mutex::new(VecDeque::new()));
        let stderrLinesForThread = stderrLines.clone();
        thread::spawn(move || {
            for line in BufReader::with_capacity(MANAGED_RUNTIME_STDIO_BUFFER_BYTES, stderr)
                .lines()
                .flatten()
            {
                if let Ok(mut lines) = stderrLinesForThread.lock() {
                    lines.push_back(line);
                    while lines.len() > 400 {
                        lines.pop_front();
                    }
                }
            }
        });

        Ok(Box::new(IosManagedRuntimeProcess {
            child: Mutex::new(child),
            stdin: Mutex::new(stdin),
            stdoutRx: Mutex::new(stdoutRx),
            stderrLines,
        }))
    }

    /// Runs a one-shot iOS managed runtime command and captures output.
    fn runRuntimeCommand(
        &self,
        request: RuntimeProcessRequest,
    ) -> HostResult<RuntimeCommandOutput> {
        let executable = self
            .resolveRuntimeExecutable(request.program.clone(), request.executablePath.as_deref())?;
        let mut command = std::process::Command::new(&executable);
        if let Some(cwd) = request.cwd.as_deref() {
            command.current_dir(cwd);
        }
        command.args(request.args);
        command.envs(request.env);
        let output = command
            .output()
            .map_err(|error| HostError::new(format!("failed to run {executable}: {error}")))?;
        Ok(RuntimeCommandOutput {
            exitCode: output.status.code(),
            stdout: String::from_utf8_lossy(&output.stdout).to_string(),
            stderr: String::from_utf8_lossy(&output.stderr).to_string(),
        })
    }
}

/// Returns the persistent managed-runtime workspace inside the iOS data root.
fn iosRuntimeWorkspaceDir() -> String {
    Path::new("/var/mobile/.operit")
        .join("managed_runtime")
        .to_string_lossy()
        .to_string()
}

/// Writes one newline-terminated managed runtime frame.
///
/// Generic over `Write` so the framing can be unit-tested without spawning a
/// child process. This is a protocol boundary worth testing: a malformed frame
/// (missing or doubled newline) hangs the MCP runtime rather than erroring.
#[allow(non_snake_case)]
fn writeManagedRuntimeLine(stdin: &mut impl Write, line: &str) -> HostResult<()> {
    let lineBytes = line.as_bytes();
    match lineBytes.len() >= MANAGED_RUNTIME_SINGLE_FRAME_MIN_BYTES {
        true => writeManagedRuntimeLargeLine(stdin, lineBytes),
        false => writeManagedRuntimeSmallLine(stdin, lineBytes),
    }
}

/// Writes a small managed runtime line without per-message heap allocation.
#[allow(non_snake_case)]
fn writeManagedRuntimeSmallLine(stdin: &mut impl Write, lineBytes: &[u8]) -> HostResult<()> {
    stdin.write_all(lineBytes)?;
    stdin.write_all(b"\n")?;
    stdin.flush()?;
    Ok(())
}

/// Writes a large managed runtime line as one contiguous pipe frame.
#[allow(non_snake_case)]
fn writeManagedRuntimeLargeLine(stdin: &mut impl Write, lineBytes: &[u8]) -> HostResult<()> {
    let mut frame = Vec::with_capacity(lineBytes.len() + 1);
    frame.extend_from_slice(lineBytes);
    frame.push(b'\n');
    stdin.write_all(&frame)?;
    stdin.flush()?;
    Ok(())
}

/// Writes many managed runtime lines through one contiguous pipe frame.
#[allow(non_snake_case)]
fn writeManagedRuntimeLines(stdin: &mut impl Write, lines: &[String]) -> HostResult<()> {
    let frameBytes = lines.iter().map(|line| line.len() + 1).sum();
    let mut frame = Vec::with_capacity(frameBytes);
    for line in lines {
        frame.extend_from_slice(line.as_bytes());
        frame.push(b'\n');
    }
    stdin.write_all(&frame)?;
    stdin.flush()?;
    Ok(())
}

/// Joins buffered stderr lines, ensuring every line is newline-terminated.
fn joinManagedRuntimeStderrLines(lines: &mut VecDeque<String>) -> String {
    let mut output = String::new();
    while let Some(line) = lines.pop_front() {
        output.push_str(&line);
        if !line.ends_with('\n') {
            output.push('\n');
        }
    }
    output
}

#[cfg(test)]
mod managed_runtime_tests {
    use super::{
        joinManagedRuntimeStderrLines, writeManagedRuntimeLine, writeManagedRuntimeLines,
        MANAGED_RUNTIME_SINGLE_FRAME_MIN_BYTES,
    };
    use std::collections::VecDeque;

    #[test]
    fn small_line_is_written_with_exactly_one_trailing_newline() {
        let mut sink = Vec::new();
        writeManagedRuntimeLine(&mut sink, r#"{"jsonrpc":"2.0"}"#).unwrap();
        assert_eq!(String::from_utf8(sink).unwrap(), "{\"jsonrpc\":\"2.0\"}\n");
    }

    #[test]
    fn large_line_stays_one_contiguous_frame_with_one_newline() {
        // Past the threshold the writer buffers into a single frame; it must
        // still emit exactly one trailing newline or the peer blocks forever.
        let payload = "x".repeat(MANAGED_RUNTIME_SINGLE_FRAME_MIN_BYTES + 10);
        let mut sink = Vec::new();
        writeManagedRuntimeLine(&mut sink, &payload).unwrap();
        let written = String::from_utf8(sink).unwrap();
        assert_eq!(written, format!("{payload}\n"));
        assert_eq!(written.matches('\n').count(), 1);
    }

    #[test]
    fn write_lines_joins_with_newlines_and_keeps_order() {
        let lines = vec!["first".to_string(), "second".to_string(), String::new()];
        let mut sink = Vec::new();
        writeManagedRuntimeLines(&mut sink, &lines).unwrap();
        assert_eq!(String::from_utf8(sink).unwrap(), "first\nsecond\n\n");
    }

    #[test]
    fn stderr_join_terminates_lines_and_drains_queue() {
        let mut lines: VecDeque<String> =
            VecDeque::from(vec!["boom".to_string(), "already\n".to_string()]);
        assert_eq!(joinManagedRuntimeStderrLines(&mut lines), "boom\nalready\n");
        assert!(lines.is_empty());
    }
}

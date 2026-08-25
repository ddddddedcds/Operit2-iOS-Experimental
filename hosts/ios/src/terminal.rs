use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use operit_host_api::{
    HiddenTerminalCommandOutput, HostError, HostResult, TerminalCloseOutput, TerminalCommandOutput,
    TerminalHost, TerminalInfo, TerminalInputOutput, TerminalScreenOutput, TerminalSessionInfo,
    TerminalSessionListEntry, TerminalTypeInfo,
};
use operit_host_native_common::{NativePtyShellCommand, NativePtyTerminalHost};
use operit_util::AndroidPathRewriter::rewrite_vfs_mount_paths;

const SHELL_TERMINAL_TYPE: &str = "shell";
const PLATFORM: &str = "ios";
const SYSTEM_SHELL_TERMINAL: &str = "shell";
const NATIVE_TERMINAL: &str = "native";

/// Full PATH injected into every spawned shell. Covers both the stock system
/// dirs and the rootless (/var/jb/*) jailbreak dirs, so ordinary commands like
/// `uname` resolve regardless of whether the process runs in the jailbreak view or
/// the real root (HANDOVER 8.4: inherited app PATH was missing /usr/bin etc.
/// and `uname` failed with "not found").
const IOS_SHELL_PATH: &str = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:\
/sbin:/bin:/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/usr/local/bin";

/// Minimal deterministic environment for iOS shells. PATH is mandatory
/// (do not rely on the parent's inherited PATH), SHELL matches the /bin/sh
/// program the host probes.
fn iosShellEnvironment() -> Vec<(String, String)> {
    vec![
        ("PATH".to_string(), IOS_SHELL_PATH.to_string()),
        ("SHELL".to_string(), "/bin/sh".to_string()),
    ]
}

/// Physical sandbox root backing the VFS android mount on iOS. Matches the
/// compat target PathMapper and the static rewriter resolve to.
fn iosAndroidCompatRoot() -> std::path::PathBuf {
    std::path::Path::new("/var/mobile/.operit/runtime").join("android-compat")
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum IosTerminalBackend {
    SystemShell,
}

#[derive(Default)]
struct IosTerminalState {
    sessionBackends: BTreeMap<String, IosTerminalBackend>,
}

/// Hosts privileged system /bin/sh terminals on iOS.
#[derive(Clone)]
pub struct IosTerminalHost {
    state: Arc<Mutex<IosTerminalState>>,
    systemShell: NativePtyTerminalHost,
    systemShellAvailable: bool,
}

impl Default for IosTerminalHost {
    /// Creates the iOS terminal host using a real system-shell capability probe.
    fn default() -> Self {
        Self::new()
    }
}

impl IosTerminalHost {
    /// Creates the iOS terminal host and checks whether a real system shell can
    /// actually start in a PTY. Tries `/bin/sh` first (stock-ish hosts), then
    /// falls back to the jailbroken rootless layout `/var/jb/bin/sh`.
    pub fn new() -> Self {
        let (systemShell, systemShellAvailable) = Self::probeSystemShell();
        Self {
            state: Arc::new(Mutex::new(IosTerminalState::default())),
            systemShell,
            systemShellAvailable,
        }
    }

    /// Probes candidate system-shell paths and returns the first working host.
    fn probeSystemShell() -> (NativePtyTerminalHost, bool) {
        for program in ["/bin/sh", "/var/jb/bin/sh"] {
            let shell = NativePtyTerminalHost::customShell(NativePtyShellCommand {
                program: program.to_string(),
                arguments: vec!["-i".to_string()],
                description: format!("Privileged system {program} terminal"),
                processWorkingDirectory: "session".to_string(),
                defaultSessionWorkingDirectory: "process-current".to_string(),
                environment: iosShellEnvironment(),
                sessionWorkingDirectoryEnvironment: "none".to_string(),
            });
            if let Ok(shell) = shell {
                if shell.probe("/").is_ok() {
                    return (shell, true);
                }
            }
        }
        // 最后兜底：无可用系统 shell，用默认构造（probe 也会失败，标记不可用）。
        let fallback = NativePtyTerminalHost::systemShell();
        let fallbackAvailable = fallback.probe("/").is_ok();
        (fallback, fallbackAvailable)
    }

    /// Selects the jailbroken system /bin/sh when a privileged PTY is available.
    fn primaryBackend(&self) -> IosTerminalBackend {
        IosTerminalBackend::SystemShell
    }

    /// Resolves one manually selected terminal implementation and type to its backend.
    fn requestedBackend(
        &self,
        terminal: &str,
        terminalType: &str,
    ) -> HostResult<IosTerminalBackend> {
        match (terminal.trim(), terminalType.trim()) {
            (SYSTEM_SHELL_TERMINAL, SHELL_TERMINAL_TYPE) if self.systemShellAvailable => {
                Ok(IosTerminalBackend::SystemShell)
            }
            (SYSTEM_SHELL_TERMINAL, SHELL_TERMINAL_TYPE) => Err(HostError::new(
                "iOS system /bin/sh is unavailable because this host cannot start a privileged PTY",
            )),
            (implementation, kind) => Err(HostError::new(format!(
                "Unsupported iOS terminal implementation and type: {implementation}/{kind}"
            ))),
        }
    }

    /// Returns the public terminal implementation name for one iOS backend.
    fn terminalName(backend: IosTerminalBackend) -> &'static str {
        match backend {
            IosTerminalBackend::SystemShell => SYSTEM_SHELL_TERMINAL,
        }
    }

    /// Stores the owner backend for one session identifier.
    fn recordSession(&self, sessionId: &str, backend: IosTerminalBackend) -> HostResult<()> {
        let mut state = self.lockState()?;
        state.sessionBackends.insert(sessionId.to_string(), backend);
        Ok(())
    }

    /// Removes the owner backend registration for one closed session identifier.
    fn removeSession(&self, sessionId: &str) -> HostResult<()> {
        let mut state = self.lockState()?;
        state.sessionBackends.remove(sessionId);
        Ok(())
    }

    /// Resolves the explicitly registered backend for one existing session identifier.
    fn sessionBackend(&self, sessionId: &str) -> HostResult<IosTerminalBackend> {
        let state = self.lockState()?;
        state
            .sessionBackends
            .get(sessionId)
            .copied()
            .ok_or_else(|| {
                HostError::new(format!(
                    "iOS terminal session backend is not registered: {sessionId}"
                ))
            })
    }

    /// Locks the session-backend registry.
    fn lockState(&self) -> HostResult<std::sync::MutexGuard<'_, IosTerminalState>> {
        self.state
            .lock()
            .map_err(|_| HostError::new("iOS terminal state mutex poisoned"))
    }

    /// Starts a PTY session in one exact iOS terminal backend.
    fn startSession(
        &self,
        backend: IosTerminalBackend,
        sessionName: &str,
        workingDir: &str,
        rows: u16,
        cols: u16,
    ) -> HostResult<String> {
        let sessionName = requiredText(sessionName, "session_name")?;
        let workingDir = requiredText(workingDir, "working_directory")?;
        let rows = positiveDimension(rows, "rows")?;
        let cols = positiveDimension(cols, "cols")?;
        let sessionId = match backend {
            IosTerminalBackend::SystemShell => self.systemShell.startPtySession(
                &sessionName,
                NATIVE_TERMINAL,
                SHELL_TERMINAL_TYPE,
                &workingDir,
                rows,
                cols,
            )?,
        };
        self.recordSession(&sessionId, backend)?;
        Ok(sessionId)
    }

    /// Creates or reuses the backend-default persistent session for a plugin executor.
    fn createOrGetBackendSession(
        &self,
        backend: IosTerminalBackend,
        sessionName: &str,
    ) -> HostResult<TerminalSessionInfo> {
        let sessionName = requiredText(sessionName, "session_name")?;
        let data = match backend {
            IosTerminalBackend::SystemShell => {
                systemSessionInfo(self.systemShell.createOrGetSession(&sessionName)?)
            }
        };
        self.recordSession(&data.sessionId, backend)?;
        Ok(data)
    }

    /// Executes one complete command in an already registered iOS terminal session.
    fn executeSession(
        &self,
        backend: IosTerminalBackend,
        sessionId: &str,
        command: &str,
        timeoutMs: u64,
    ) -> HostResult<TerminalCommandOutput> {
        let command = requiredText(command, "command")?;
        // The native shell bypasses the VFS: rewrite mount-form paths
        // (/mnt/android/sdcard/…, top-level /data/…) to their physical compat
        // dirs so commands from path-rewritten plugins resolve on iOS.
        let command = rewrite_vfs_mount_paths(&command, &iosAndroidCompatRoot().to_string_lossy());
        match backend {
            IosTerminalBackend::SystemShell => systemCommandOutput(
                self.systemShell
                    .executeInSession(sessionId, &command, timeoutMs)?,
            ),
        }
    }
}

impl TerminalHost for IosTerminalHost {
    /// Describes the real system shell capability, including privileged availability.
    fn terminalInfo(&self) -> HostResult<TerminalInfo> {
        let primaryBackend = self.primaryBackend();
        let primaryTerminal = Self::terminalName(primaryBackend).to_string();
        let systemShell = TerminalTypeInfo {
            terminal: SYSTEM_SHELL_TERMINAL.to_string(),
            terminalType: SHELL_TERMINAL_TYPE.to_string(),
            available: self.systemShellAvailable,
            description: "iOS system /bin/sh; requires a jailbroken or otherwise privileged host"
                .to_string(),
        };
        let types = vec![systemShell];
        Ok(TerminalInfo {
            platform: PLATFORM.to_string(),
            terminal: primaryTerminal,
            terminalType: SHELL_TERMINAL_TYPE.to_string(),
            types,
        })
    }

    /// Starts one manually selected iOS PTY terminal.
    fn startPtySession(
        &self,
        sessionName: &str,
        terminal: &str,
        terminalType: &str,
        workingDir: &str,
        rows: u16,
        cols: u16,
    ) -> HostResult<String> {
        let backend = self.requestedBackend(terminal, terminalType)?;
        self.startSession(backend, sessionName, workingDir, rows, cols)
    }

    /// Drains raw output bytes from one iOS terminal.
    fn readPtySession(&self, sessionId: &str) -> HostResult<Vec<u8>> {
        match self.sessionBackend(sessionId)? {
            IosTerminalBackend::SystemShell => self.systemShell.readPtySession(sessionId),
        }
    }

    /// Writes raw terminal input to one iOS terminal.
    fn writePtySession(&self, sessionId: &str, data: &[u8]) -> HostResult<usize> {
        match self.sessionBackend(sessionId)? {
            IosTerminalBackend::SystemShell => self.systemShell.writePtySession(sessionId, data),
        }
    }

    /// Resizes one iOS terminal PTY.
    fn resizePtySession(&self, sessionId: &str, rows: u16, cols: u16) -> HostResult<()> {
        match self.sessionBackend(sessionId)? {
            IosTerminalBackend::SystemShell => {
                self.systemShell.resizePtySession(sessionId, rows, cols)
            }
        }
    }

    /// Returns the exit status for one iOS terminal PTY after it has closed.
    fn pollPtyExitCode(&self, sessionId: &str) -> HostResult<Option<i32>> {
        match self.sessionBackend(sessionId)? {
            IosTerminalBackend::SystemShell => self.systemShell.pollPtyExitCode(sessionId),
        }
    }

    /// Closes one iOS terminal PTY and removes its backend registration.
    fn closePtySession(&self, sessionId: &str) -> HostResult<()> {
        match self.sessionBackend(sessionId)? {
            IosTerminalBackend::SystemShell => self.systemShell.closePtySession(sessionId)?,
        }
        self.removeSession(sessionId)
    }

    /// Lists active system-shell sessions with their exact terminal identities.
    fn listSessions(&self) -> HostResult<Vec<TerminalSessionListEntry>> {
        let mut sessions = Vec::new();
        if self.systemShellAvailable {
            for session in self.systemShell.listSessions()? {
                let session = systemSessionListEntry(session);
                self.recordSession(&session.sessionId, IosTerminalBackend::SystemShell)?;
                sessions.push(session);
            }
        }
        Ok(sessions)
    }

    /// Creates or reuses the Host-selected terminal backend for a plugin session.
    fn createOrGetSession(&self, sessionName: &str) -> HostResult<TerminalSessionInfo> {
        self.createOrGetBackendSession(self.primaryBackend(), sessionName)
    }

    /// Executes one complete command in the terminal backend registered for the session.
    fn executeInSession(
        &self,
        sessionId: &str,
        command: &str,
        timeoutMs: u64,
    ) -> HostResult<TerminalCommandOutput> {
        self.executeSession(
            self.sessionBackend(sessionId)?,
            sessionId,
            command,
            timeoutMs,
        )
    }

    /// Executes a hidden command through the Host-selected persistent terminal backend.
    fn executeHiddenCommand(
        &self,
        command: &str,
        executorKey: &str,
        timeoutMs: u64,
    ) -> HostResult<HiddenTerminalCommandOutput> {
        let executorKey = requiredText(executorKey, "executor_key")?;
        let session = self.createOrGetSession(&format!("hidden:{executorKey}"))?;
        let result = self.executeSession(
            self.sessionBackend(&session.sessionId)?,
            &session.sessionId,
            command,
            timeoutMs,
        )?;
        Ok(HiddenTerminalCommandOutput {
            command: result.command,
            output: result.output,
            exitCode: result.exitCode,
            executorKey,
            platform: result.platform,
            terminal: result.terminal,
            terminalType: result.terminalType,
            timedOut: result.timedOut,
        })
    }

    /// Sends UTF-8 text or one named control sequence to a registered iOS session.
    fn inputInSession(
        &self,
        sessionId: &str,
        input: Option<&str>,
        control: Option<&str>,
    ) -> HostResult<TerminalInputOutput> {
        let content = match (input, control) {
            (Some(value), None) => value,
            (None, Some(value)) => controlSequence(value)?,
            (Some(_), Some(_)) => {
                return Err(HostError::new(
                    "iOS terminal input accepts either text or one control sequence",
                ));
            }
            (None, None) => {
                return Err(HostError::new(
                    "iOS terminal input requires text or one control sequence",
                ));
            }
        };
        let acceptedChars = self.writePtySession(sessionId, content.as_bytes())?;
        Ok(TerminalInputOutput {
            sessionId: sessionId.to_string(),
            acceptedChars,
        })
    }

    /// Closes one iOS terminal session and returns its public close response.
    fn closeSession(&self, sessionId: &str) -> HostResult<TerminalCloseOutput> {
        let sessionId = requiredText(sessionId, "session_id")?;
        self.closePtySession(&sessionId)?;
        Ok(TerminalCloseOutput {
            sessionId,
            success: true,
            message: "iOS terminal session closed".to_string(),
        })
    }

    /// Returns the retained screen model for one registered iOS terminal session.
    fn getSessionScreen(&self, sessionId: &str) -> HostResult<TerminalScreenOutput> {
        match self.sessionBackend(sessionId)? {
            IosTerminalBackend::SystemShell => {
                systemScreenOutput(self.systemShell.getSessionScreen(sessionId)?)
            }
        }
    }
}

/// Applies the public iOS system-shell identity to one shared PTY session response.
fn systemSessionInfo(mut data: TerminalSessionInfo) -> TerminalSessionInfo {
    data.platform = PLATFORM.to_string();
    data.terminal = SYSTEM_SHELL_TERMINAL.to_string();
    data.terminalType = SHELL_TERMINAL_TYPE.to_string();
    data
}

/// Applies the public iOS system-shell identity to one shared PTY command response.
fn systemCommandOutput(mut data: TerminalCommandOutput) -> HostResult<TerminalCommandOutput> {
    if data.terminalType != SHELL_TERMINAL_TYPE {
        return Err(HostError::new(
            "system /bin/sh returned an unexpected terminal type",
        ));
    }
    data.platform = PLATFORM.to_string();
    data.terminal = SYSTEM_SHELL_TERMINAL.to_string();
    Ok(data)
}

/// Applies the public iOS system-shell identity to one shared PTY session-list entry.
fn systemSessionListEntry(mut data: TerminalSessionListEntry) -> TerminalSessionListEntry {
    data.platform = PLATFORM.to_string();
    data.terminal = SYSTEM_SHELL_TERMINAL.to_string();
    data.terminalType = SHELL_TERMINAL_TYPE.to_string();
    data
}

/// Applies the public iOS system-shell identity to one shared PTY screen response.
fn systemScreenOutput(mut data: TerminalScreenOutput) -> HostResult<TerminalScreenOutput> {
    if data.terminalType != SHELL_TERMINAL_TYPE {
        return Err(HostError::new(
            "system /bin/sh returned an unexpected terminal type",
        ));
    }
    data.platform = PLATFORM.to_string();
    data.terminal = SYSTEM_SHELL_TERMINAL.to_string();
    Ok(data)
}

/// Validates a required non-blank terminal request field.
fn requiredText(value: &str, field: &str) -> HostResult<String> {
    let normalized = value.trim();
    if normalized.is_empty() {
        Err(HostError::new(format!(
            "iOS terminal {field} must not be blank"
        )))
    } else {
        Ok(normalized.to_string())
    }
}

/// Validates a positive terminal geometry dimension.
fn positiveDimension(value: u16, field: &str) -> HostResult<u16> {
    if value == 0 {
        Err(HostError::new(format!(
            "iOS terminal {field} must be positive"
        )))
    } else {
        Ok(value)
    }
}

/// Maps a supported iOS terminal control name into its UTF-8 byte sequence.
fn controlSequence(control: &str) -> HostResult<&'static str> {
    match control.trim() {
        "interrupt" => Ok("\u{3}"),
        "eof" => Ok("\u{4}"),
        "newline" => Ok("\n"),
        value => Err(HostError::new(format!(
            "unsupported iOS terminal control sequence: {value}"
        ))),
    }
}

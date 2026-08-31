use operit_host_api::HostManager::HostManager;
use operit_tools::tools::packTool::RuntimePackageManager::RuntimePackageManager;
use operit_tools::tools::AIToolHandler::AIToolHandler;

/// Holds the ToolPkg execution dependencies owned by one runtime instance.
#[derive(Clone)]
pub struct ToolPkgBridgeRuntime {
    tool_handler: AIToolHandler,
    host_manager: HostManager,
}

impl ToolPkgBridgeRuntime {
    /// Creates bridge runtime state for one application runtime.
    pub fn new(tool_handler: AIToolHandler, host_manager: HostManager) -> Self {
        Self {
            tool_handler,
            host_manager,
        }
    }

    /// Returns a snapshot of this runtime's package manager.
    ///
    /// **Non-blocking.** Returns `None` instead of blocking when the
    /// package-manager mutex is currently held by another thread (e.g. during a
    /// `compose_dsl` script execution that itself borrowed the manager). The
    /// old blocking implementation (`.lock().expect(..)`) froze the WASM worker
    /// thread for up to 60s: a tool/lifecycle hook fired inline on the same
    /// worker thread while that mutex was already owned elsewhere, so the
    /// re-entrant lock waited forever. Callers must treat `None` as
    /// "best-effort snapshot unavailable this call" and skip the package-dependent
    /// work rather than deadlocking. Use [`try_package_manager`] only when a
    /// typed `Option` is not needed.
    pub fn package_manager(&self) -> Option<RuntimePackageManager> {
        self.tool_handler
            .getOrCreatePackageManager()
            .try_lock()
            .ok()
            .map(|guard| guard.clone())
    }

    /// Non-blocking variant of [`package_manager`].
    ///
    /// Returns `None` instead of blocking when the package-manager mutex is
    /// currently held by another thread. The blocking `package_manager` used to
    /// freeze the WASM worker thread for up to 60s whenever a compose_dsl
    /// render triggered a tool call while that mutex was contended: tool
    /// lifecycle notifications/interception ran inline on the same worker thread
    /// and waited on a lock owned elsewhere. Callers that only deliver
    /// best-effort events (notifications) or can safely fall back to `Allow`
    /// (interception) should use this so a contended lock can never stall tool
    /// execution.
    pub fn try_package_manager(&self) -> Option<RuntimePackageManager> {
        self.tool_handler
            .getOrCreatePackageManager()
            .try_lock()
            .ok()
            .map(|guard| guard.clone())
    }

    /// Returns this runtime's tool handler.
    pub fn tool_handler(&self) -> AIToolHandler {
        self.tool_handler.clone()
    }

    /// Returns the host capabilities attached to this ToolPkg runtime.
    pub fn host_manager(&self) -> HostManager {
        self.host_manager.clone()
    }
}

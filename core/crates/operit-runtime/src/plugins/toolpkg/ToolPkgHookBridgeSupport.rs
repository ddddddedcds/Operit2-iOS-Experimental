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
    pub fn package_manager(&self) -> RuntimePackageManager {
        self.tool_handler
            .getOrCreatePackageManager()
            .lock()
            .expect("package manager mutex poisoned")
            .clone()
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
        match self.tool_handler.getOrCreatePackageManager().try_lock() {
            Ok(guard) => Some(guard.clone()),
            // Contention already logged (pm.contention) by TracedMutex::try_lock;
            // returning None keeps tool execution non-blocking (no 60s freeze).
            Err(_) => None,
        }
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

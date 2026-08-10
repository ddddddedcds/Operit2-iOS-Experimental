#![allow(non_snake_case)]

#[cfg(target_os = "ios")]
use std::path::PathBuf;
#[cfg(target_os = "ios")]
use std::sync::Arc;

#[cfg(target_os = "ios")]
use operit_host_api::HostManager::HostManager;
#[cfg(target_os = "ios")]
use operit_host_api::RuntimeStorageHost;

// 越狱 iOS 专属模块（我们维护）：终端（portable_pty）、设备自动化（ios-mcp）、
// system_operation（屏幕截图/OCR 走 ios-mcp）、device_agent（AutoGLM 循环）、
// runtime（managed runtime host 的 iOS 实现）。
#[cfg(target_os = "ios")]
pub mod bridge;
pub mod managed_runtime;
pub mod terminal;

pub use operit_host_apple_native::{
    AppleAudioPlaybackHost as IosAudioPlaybackHost, AppleBluetoothHost as IosBluetoothHost,
    AppleFileSystemHost as IosFileSystemHost,
    AppleHostRuntimeEventSchedulerHost as IosHostRuntimeEventSchedulerHost,
    AppleHostRuntimeTaskSchedulerHost as IosHostRuntimeTaskSchedulerHost,
    AppleHttpHost as IosHttpHost, AppleLocalInferenceCommand as IosLocalInferenceCommand,
    AppleLocalInferenceHost as IosLocalInferenceHost, AppleMusicCommand as IosMusicCommand,
    AppleRuntimeStorageHost as IosRuntimeStorageHost,
    AppleTtsPlaybackCommand as IosTtsPlaybackCommand, AppleTtsPlaybackHost as IosTtsPlaybackHost,
    AppleTtsSynthesisHost as IosTtsSynthesisHost,
};
#[cfg(target_os = "ios")]
pub use managed_runtime::IosManagedRuntimeHost;
pub use terminal::IosTerminalHost;

// `AppleSystemOperationHost` is wrapped as a newtype on iOS (see the `system_operation`
// module) that routes screenshot/OCR through ios-mcp. On other targets keep the plain alias.
#[cfg(not(target_os = "ios"))]
pub use operit_host_apple_native::AppleSystemOperationHost as IosSystemOperationHost;

#[cfg(target_os = "ios")]
pub mod ios_mcp;
#[cfg(target_os = "ios")]
pub mod device_automation;
#[cfg(target_os = "ios")]
pub use device_automation::IosDeviceAutomationHost;
#[cfg(target_os = "ios")]
pub mod system_operation;
#[cfg(target_os = "ios")]
pub use system_operation::IosSystemOperationHost;

#[cfg(target_os = "ios")]
pub mod device_agent;
#[cfg(target_os = "ios")]
pub use device_agent::run_device_agent_loop;

/// Creates the iOS-owned runtime host manager for explicit storage roots.
///
/// 合并说明（2026-08-10 merge upstream/main）：以上游装配为主体（新增
/// runtimeStorageWriteHost / archiveStagingHost / hostRuntimeTaskSchedulerHost），
/// 保留我们的 deviceAutomationHost；managed runtime 用我们 runtime 模块的
/// `IosManagedRuntimeHost`（不采用上游 managed_runtime 模块，避免同名导出冲突）。
#[cfg(target_os = "ios")]
pub fn createRuntimeHostManager(
    runtimeRoot: PathBuf,
    workspaceRoot: PathBuf,
    webVisitHost: Arc<dyn operit_host_api::WebVisitHost>,
) -> HostManager {
    let runtimeStorageWriteHost =
        Arc::new(operit_host_native_common::NativeRuntimeStorageHost::new(
            runtimeRoot.clone(),
            workspaceRoot.clone(),
        ));
    let runtimeStorageHost = Arc::new(IosRuntimeStorageHost::new(runtimeRoot, workspaceRoot));
    let runtimeSqliteHost = runtimeStorageHost.clone();
    let hostSecretStore = runtimeStorageHost.clone();
    let archiveStagingHost = Arc::new(operit_host_native_common::NativeArchiveStagingHost::new(
        runtimeStorageHost
            .runtimeRootDir()
            .expect("iOS runtime storage root must be configured"),
    ));
    let mut hostManager = HostManager::withFileSystemWebVisitAndSystemOperationHosts(
        Arc::new(IosFileSystemHost::new()),
        webVisitHost,
        Arc::new(IosSystemOperationHost::new()),
    );
    hostManager.httpHost = Some(Arc::new(IosHttpHost::new()));
    hostManager.managedRuntimeHost =
        Some(Arc::new(IosManagedRuntimeHost::new(Arc::new(IosTerminalHost::new()))));
    hostManager.runtimeStorageHost = Some(runtimeStorageHost);
    hostManager.runtimeSqliteHost = Some(runtimeSqliteHost);
    hostManager = hostManager.withHostSecretStore(hostSecretStore);
    hostManager = hostManager.withArchiveStagingHost(archiveStagingHost);
    hostManager = hostManager.withRuntimeStorageWriteHost(runtimeStorageWriteHost);
    hostManager = hostManager
        .withHostRuntimeEventSchedulerHost(Arc::new(IosHostRuntimeEventSchedulerHost::new()));
    hostManager = hostManager
        .withHostRuntimeTaskSchedulerHost(Arc::new(IosHostRuntimeTaskSchedulerHost::new()));
    hostManager.withDeviceAutomationHost(Arc::new(IosDeviceAutomationHost::new()))
}

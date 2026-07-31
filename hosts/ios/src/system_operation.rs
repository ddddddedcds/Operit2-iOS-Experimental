#![cfg(target_os = "ios")]
//! iOS `SystemOperationHost` that wraps `AppleSystemOperationHost` and routes
//! screenshot / OCR through the `ios-mcp` jailbreak tweak instead of the macOS
//! native paths (which are unavailable on iOS).
//!
//! Only `captureScreenshot` and `recognizeText` are overridden. Every other method
//! is forwarded verbatim to the inner `AppleSystemOperationHost`, so macOS behaviour
//! is untouched and this module is iOS-only.

use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

use operit_host_api::{
    AppListData, AppOperationData, AppUsageTimeResultData, DeviceInfoData, HostError, HostResult,
    LocationData, NotificationData, OCRLanguage, OCRQuality, SystemOperationHost, SystemSettingData,
};
use operit_host_apple_native::AppleSystemOperationHost;

use crate::ios_mcp::IosMcpClient;

pub struct IosSystemOperationHost {
    inner: AppleSystemOperationHost,
    mcp: IosMcpClient,
}

impl IosSystemOperationHost {
    pub fn new() -> Self {
        Self {
            inner: AppleSystemOperationHost::new(),
            mcp: IosMcpClient::new(),
        }
    }
}

impl SystemOperationHost for IosSystemOperationHost {
    fn captureScreenshot(&self) -> HostResult<String> {
        let (png, _w, _h) = self
            .mcp
            .screenshot_png()
            .map_err(|e| HostError::new(format!("iOS screenshot via ios-mcp failed: {e}")))?;
        let dir = std::env::temp_dir().join("operit-runtime").join("temp");
        fs::create_dir_all(&dir)
            .map_err(|e| HostError::new(format!("failed to create temp dir: {e}")))?;
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let path = dir.join(format!("ios_screen_{nanos}.png"));
        fs::write(&path, &png).map_err(|e| HostError::new(format!("failed to write PNG: {e}")))?;
        Ok(path.to_string_lossy().into_owned())
    }

    fn recognizeText(
        &self,
        imagePath: &str,
        language: OCRLanguage,
        _quality: OCRQuality,
    ) -> HostResult<String> {
        let langs: &[&str] = match language {
            OCRLanguage::Latin => &["en-US"],
            OCRLanguage::Chinese => &["zh-Hans"],
            OCRLanguage::Japanese => &["ja-JP"],
            OCRLanguage::Korean => &["ko-KR"],
        };
        // ios-mcp `ocr_screen` always OCRs the live screen and ignores any image input,
        // so `imagePath` is intentionally not forwarded on iOS.
        self.mcp
            .ocr_screen(langs)
            .map_err(|e| HostError::new(format!("iOS OCR via ios-mcp failed (imagePath={imagePath} ignored): {e}")))
    }

    fn getSystemLanguageCode(&self) -> HostResult<String> {
        self.inner.getSystemLanguageCode()
    }
    fn toast(&self, message: &str) -> HostResult<()> {
        self.inner.toast(message)
    }
    fn sendNotification(&self, title: &str, message: &str) -> HostResult<()> {
        self.inner.sendNotification(title, message)
    }
    fn modifySystemSetting(
        &self,
        namespace: &str,
        setting: &str,
        value: &str,
    ) -> HostResult<SystemSettingData> {
        self.inner.modifySystemSetting(namespace, setting, value)
    }
    fn getSystemSetting(&self, namespace: &str, setting: &str) -> HostResult<SystemSettingData> {
        self.inner.getSystemSetting(namespace, setting)
    }
    fn installApp(&self, path: &str) -> HostResult<AppOperationData> {
        self.inner.installApp(path)
    }
    fn uninstallApp(&self, packageName: &str) -> HostResult<AppOperationData> {
        self.inner.uninstallApp(packageName)
    }
    fn listInstalledApps(&self, includeSystemApps: bool) -> HostResult<AppListData> {
        self.inner.listInstalledApps(includeSystemApps)
    }
    fn startApp(&self, packageName: &str) -> HostResult<AppOperationData> {
        self.inner.startApp(packageName)
    }
    fn stopApp(&self, packageName: &str) -> HostResult<AppOperationData> {
        self.inner.stopApp(packageName)
    }
    fn getNotifications(&self, limit: i32, includeOngoing: bool) -> HostResult<NotificationData> {
        self.inner.getNotifications(limit, includeOngoing)
    }
    fn getAppUsageTime(
        &self,
        packageName: &str,
        sinceHours: i32,
        limit: i32,
        includeSystemApps: bool,
    ) -> HostResult<AppUsageTimeResultData> {
        self.inner
            .getAppUsageTime(packageName, sinceHours, limit, includeSystemApps)
    }
    fn getDeviceLocation(
        &self,
        timeout: i32,
        highAccuracy: bool,
        includeAddress: bool,
    ) -> HostResult<LocationData> {
        self.inner
            .getDeviceLocation(timeout, highAccuracy, includeAddress)
    }
    fn getDeviceInfo(&self) -> HostResult<DeviceInfoData> {
        self.inner.getDeviceInfo()
    }
}

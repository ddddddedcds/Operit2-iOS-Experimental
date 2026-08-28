"use strict";
Object.defineProperty(exports, "__esModule", {
    value: true
});
exports.default = Screen;
const deepseek_harness_web_runtime_js_1 = require("../../shared/deepseek_harness_web_runtime.js");
const dsh_subagent_js_1 = require("../../packages/dsh_subagent.js");
const subagent_panel_js_1 = require("./subagent_panel.js");
const update_controls_js_1 = require("./update_controls.js");
const MOBILE_LAYOUT_CSS_RESOURCE_KEY = "dsh_mobile_layout_css";
const MOBILE_LAYOUT_CSS_OUTPUT_NAME = "mobile_optimize.css";
const SCREEN_UTILS_DEX_RESOURCE_KEY = "dsh_screen_utils_dex";
const SCREEN_UTILS_DEX_OUTPUT_NAME = "screen_utils.dex";
const SCREEN_UTILS_CLASS = "com.deepseek.harness.utils.ScreenUtils";
let mobileLayoutAssetsPromise = null;
let webViewLifecycleGeneration = 0;

function getRuntimeGlobal(name) {
    return globalThis[name];
}

function parseScreenInfo(value) {
    const parsed = typeof value === "string" ? JSON.parse(value) : value;
    const record = (parsed && typeof parsed === "object" ? parsed : {});
    const widthDp = Number(record.widthDp);
    const widthPx = Number(record.widthPx);
    const density = Number(record.density);
    return {
        widthDp: Number.isFinite(widthDp) ? widthDp : 0,
        widthPx: Number.isFinite(widthPx) ? widthPx : 0,
        density: Number.isFinite(density) ? density : 0,
        isSmallScreen: record.isSmallScreen === true || widthDp > 0 && widthDp <= 600,
    };
}
async function loadMobileLayoutAssets() {
    if (mobileLayoutAssetsPromise)
        return mobileLayoutAssetsPromise;
    mobileLayoutAssetsPromise = (async () => {
        const toolPkg = getRuntimeGlobal("ToolPkg");
        const tools = getRuntimeGlobal("Tools");
        const java = getRuntimeGlobal("Java");
        if (!toolPkg || typeof toolPkg.readResource !== "function") {
            throw new Error("ToolPkg.readResource is unavailable");
        }
        if (!tools?.Files || typeof tools.Files.read !== "function") {
            throw new Error("Tools.Files.read is unavailable");
        }
        const cssPath = await toolPkg.readResource(MOBILE_LAYOUT_CSS_RESOURCE_KEY, MOBILE_LAYOUT_CSS_OUTPUT_NAME, true);
        const cssResult = await tools.Files.read({
            path: String(cssPath),
            environment: "android",
        });
        const css = String(cssResult?.content ?? "").trim();
        if (!css)
            throw new Error("mobile layout CSS resource is empty");
        let screenInfo = {
            widthDp: 0,
            widthPx: 0,
            density: 0,
            isSmallScreen: false,
        };
        try {
            if (!java || typeof java.loadDex !== "function" || typeof java.callStatic !== "function") {
                throw new Error("Java DEX bridge is unavailable");
            }
            const dexPath = await toolPkg.readResource(SCREEN_UTILS_DEX_RESOURCE_KEY, SCREEN_UTILS_DEX_OUTPUT_NAME, true);
            java.loadDex(String(dexPath), {});
            const context = typeof java.getApplicationContext === "function" ?
                java.getApplicationContext() :
                null;
            const rawInfo = java.callStatic(SCREEN_UTILS_CLASS, "getScreenInfo", context);
            screenInfo = parseScreenInfo(rawInfo);
        } catch (error) {
            console.warn("DeepSeek Harness native screen detection failed", error);
        }
        return {
            css,
            screenInfo
        };
    })();
    try {
        return await mobileLayoutAssetsPromise;
    } catch (error) {
        mobileLayoutAssetsPromise = null;
        throw error;
    }
}
async function applyMobileLayoutCss(controller, assets) {
    const script = `
(function() {
  const cssText = ${JSON.stringify(assets.css)};
  const nativeWidthDp = ${JSON.stringify(assets.screenInfo.widthDp)};
  const styleId = "dsh-mobile-layout-overrides";
  let style = document.getElementById(styleId);
  if (!style) {
    style = document.createElement("style");
    style.id = styleId;
    document.head.appendChild(style);
  }
  style.textContent = cssText;

  const root = document.documentElement;
  const updateCompactMode = function() {
    const webWidth = Number(window.innerWidth || 0);
    const compact = (nativeWidthDp > 0 && nativeWidthDp <= 600) || webWidth <= 600;
    root.dataset.dshCompact = compact ? "true" : "false";
    root.dataset.dshScreenWidthDp = String(nativeWidthDp || 0);
    root.dataset.dshWebWidth = String(webWidth || 0);
  };
  updateCompactMode();
  if (!window.__dshMobileLayoutResizeBound) {
    window.__dshMobileLayoutResizeBound = true;
    window.addEventListener("resize", updateCompactMode, { passive: true });
  }
})();
`;
    await controller.evaluateJavascript(script);
}

function clampProgress(value) {
    return Math.max(0, Math.min(100, Math.round(value)));
}

function appendInstallationOutput(current, incoming) {
    const combined = current ? `${current}\n${incoming}` : incoming;
    return combined.slice(-12000);
}

function formatVisibleInstallationOutput(output) {
    const lines = output.split(/\r?\n/);
    if (lines.length <= 18) {
        return output;
    }
    return [...lines.slice(0, 5), "...", ...lines.slice(-12)].join("\n");
}

function formatStartupFailure(result) {
    if (result.diagnostic !== undefined && result.diagnostic.trim()) {
        return `${result.message}\n\n${result.diagnostic.trim()}`;
    }
    if (result.logTail !== undefined && result.logTail.trim()) {
        return `${result.message}\n\n${result.logTail.trim()}`;
    }
    return result.message;
}

function formatInstallFailure(result) {
    if (result.diagnostic !== undefined && result.diagnostic.trim()) {
        return `${result.message}\n\n${result.diagnostic.trim()}`;
    }
    return result.message;
}

function formatInstallExecution(result) {
    const details = [];
    if (result.executedCommand !== undefined && result.executedCommand.trim()) {
        details.push(`执行命令: ${result.executedCommand.trim()}`);
    }
    if (result.installExitCode !== undefined) {
        details.push(`退出码: ${result.installExitCode}`);
    }
    if (result.installTimedOut !== undefined) {
        details.push(`是否超时: ${result.installTimedOut ? "是" : "否"}`);
    }
    if (result.installOutput !== undefined && result.installOutput.trim()) {
        details.push(`原始输出:\n${result.installOutput.trim()}`);
    }
    return details.join("\n");
}

function errorMessage(error) {
    if (error instanceof Error && error.message)
        return error.message;
    return String(error || "未知错误");
}

function Screen(ctx) {
    const {
        UI
    } = ctx;
    const colors = ctx.MaterialTheme.colorScheme;
    const webViewController = ctx.createWebViewController("deepseek_harness_webview");
    const [initialized, setInitialized] = ctx.useState("initialized", false);
    const [loading, setLoading] = ctx.useState("loading", false);
    const [serverUrl, setServerUrl] = ctx.useState("serverUrl", "");
    const [errorText, setErrorText] = ctx.useState("errorText", "");
    const [statusText, setStatusText] = ctx.useState("statusText", "正在准备 DeepSeek Harness");
    const [progress, setProgress] = ctx.useState("progress", 0);
    const [outputText, setOutputText] = ctx.useState("outputText", "");
    const [runtimeAction, setRuntimeAction] = ctx.useState("runtimeAction", "");
    const [installedVersion, setInstalledVersion] = ctx.useState("installedVersion", "");
    const [latestVersion, setLatestVersion] = ctx.useState("latestVersion", "");
    const [reloadToken, setReloadToken] = ctx.useState("reloadToken", "0");
    const [pageLoading, setPageLoading] = ctx.useState("pageLoading", false);
    const [checkingUpdate, setCheckingUpdate] = ctx.useState("checkingUpdate", false);
    const [updateNotice, setUpdateNotice] = ctx.useState("updateNotice", "");
    const [manualUpdateAvailable, setManualUpdateAvailable] = ctx.useState("manualUpdateAvailable", false);
    const [resetting, setResetting] = ctx.useState("resetting", false);
    const [resetNotice, setResetNotice] = ctx.useState("resetNotice", "");
    const [settingsOpen, setSettingsOpen] = ctx.useState("settingsOpen", false);
    const [subagentPanelOpen, setSubagentPanelOpen] = ctx.useState("subagentPanelOpen", false);
    const [subagentPanelLoading, setSubagentPanelLoading] = ctx.useState("subagentPanelLoading", false);
    const [subagentPanelCleaning, setSubagentPanelCleaning] = ctx.useState("subagentPanelCleaning", false);
    const [subagentPanelState, setSubagentPanelState] = ctx.useState("subagentPanelState", null);
    const [subagentPanelError, setSubagentPanelError] = ctx.useState("subagentPanelError", "");
    const [subagentPanelCleanupNotice, setSubagentPanelCleanupNotice] = ctx.useState("subagentPanelCleanupNotice", "");
    const webViewGeneration = webViewLifecycleGeneration;
    async function refreshSubagentPanel() {
        if (subagentPanelLoading || subagentPanelCleaning)
            return;
        setSubagentPanelLoading(true);
        setSubagentPanelError("");
        setSubagentPanelCleanupNotice("");
        try {
            const state = await (0, dsh_subagent_js_1.dsh_subagent_panel)({});
            if (!state || typeof state !== "object" || !Array.isArray(state.agents)) {
                throw new Error("Sub-Agent 面板返回了无效状态。");
            }
            setSubagentPanelState(state);
        }
        catch (error) {
            console.error("DeepSeek Harness Sub-Agent panel refresh failed", error);
            setSubagentPanelError(errorMessage(error));
        }
        finally {
            setSubagentPanelLoading(false);
        }
    }
    async function cleanupSubagentPanel() {
        if (subagentPanelLoading || subagentPanelCleaning)
            return;
        setSubagentPanelCleaning(true);
        setSubagentPanelError("");
        setSubagentPanelCleanupNotice("");
        try {
            const result = await (0, dsh_subagent_js_1.dsh_subagent_cleanup)({});
            if (!result || typeof result !== "object" || !result.state || !Array.isArray(result.state.agents)) {
                throw new Error("清理结果无效。");
            }
            setSubagentPanelState(result.state);
            const removed = Math.max(0, Math.round(Number(result.removed) || 0));
            const failures = Array.isArray(result.failures) ? result.failures.length : 0;
            setSubagentPanelCleanupNotice(failures > 0
                ? `已清理 ${removed} 条，${failures} 条清理失败`
                : removed > 0 ? `已清理 ${removed} 条已结束任务` : "没有可清理的已结束任务");
        }
        catch (error) {
            console.error("DeepSeek Harness Sub-Agent cleanup failed", error);
            setSubagentPanelError(errorMessage(error));
        }
        finally {
            setSubagentPanelCleaning(false);
        }
    }
    function toggleSettings() {
        setSettingsOpen(!settingsOpen);
        if (settingsOpen) {
            setSubagentPanelOpen(false);
        }
    }
    function closeSettings() {
        setSettingsOpen(false);
        setSubagentPanelOpen(false);
    }
    async function openSubagentFromSettings() {
        setSettingsOpen(false);
        setSubagentPanelOpen(true);
        await refreshSubagentPanel();
    }
    async function runUpdateAction() {
        if (manualUpdateAvailable) {
            await installAndStart();
        }
        else {
            await checkForUpdates();
        }
    }
    async function startInstalledRuntime(forceRestart) {
        setLoading(true);
        setRuntimeAction("");
        setPageLoading(false);
        setErrorText("");
        setStatusText("正在启动 DeepSeek Harness Web");
        setProgress(40);
        try {
            const result = await (0, deepseek_harness_web_runtime_js_1.startDeepSeekHarnessWebServer)({
                forceRestart,
                onProgress: (event) => {
                    setStatusText(event.message);
                    setProgress(clampProgress(event.progress));
                },
            });
            if (!result.success) {
                setErrorText(formatStartupFailure(result));
                setStatusText(result.message);
                return false;
            }
            setServerUrl(result.url);
            setPageLoading(true);
            setReloadToken(`${Date.now()}`);
            setProgress(90);
            setStatusText("正在加载 DeepSeek Harness");
            return true;
        } catch (error) {
            console.error("DeepSeek Harness startup failed", error);
            setErrorText("无法从 Linux 运行时启动 DeepSeek Harness。");
            setStatusText("DeepSeek Harness 启动失败");
            return false;
        } finally {
            setLoading(false);
        }
    }
    async function restoreOrInspect() {
        const hasExistingPage = Boolean(serverUrl) && !errorText;
        if (hasExistingPage) {
            setRuntimeAction("");
            setStatusText("DeepSeek Harness 已就绪");
            setProgress(100);
            return;
        }
        setLoading(true);
        setRuntimeAction("");
        setServerUrl("");
        setPageLoading(false);
        setErrorText("");
        setOutputText("");
        setStatusText("正在启动 DeepSeek Harness 服务");
        setProgress(10);
        try {
            const status = await (0, deepseek_harness_web_runtime_js_1.readDeepSeekHarnessWebServerStatus)();
            if (status.success) {
                setServerUrl(status.url);
                setPageLoading(true);
                setReloadToken(`${Date.now()}`);
                setProgress(90);
                setStatusText("正在加载 DeepSeek Harness");
                return;
            }
            if (await (0, deepseek_harness_web_runtime_js_1.isDeepSeekHarnessRuntimeInstalled)()) {
                await startInstalledRuntime(false);
                return;
            }
            await inspectAndRoute();
        } catch (error) {
            console.error("DeepSeek Harness restore failed", error);
            setErrorText("无法启动 DeepSeek Harness Web。");
            setStatusText("DeepSeek Harness 启动失败");
        } finally {
            setLoading(false);
        }
    }
    function appendControlLog(current, line) {
        const text = typeof line === "string" ? line.trim() : "";
        if (!text)
            return current;
        return appendInstallationOutput(current, `[${new Date().toLocaleTimeString("zh-CN", { hour12: false, timeZone: "Asia/Shanghai" })}] ${text}`);
    }
    async function checkForUpdates() {
        if (!runtimeReady || checkingUpdate || loading) {
            return;
        }
        let controlLog = "";
        setCheckingUpdate(true);
        setManualUpdateAvailable(false);
        setResetNotice("");
        setUpdateNotice("正在检查 DSH 更新...");
        controlLog = appendControlLog(controlLog, "开始检查 DSH 更新");
        setOutputText(controlLog);
        try {
            const inspection = await (0, deepseek_harness_web_runtime_js_1.inspectDeepSeekHarnessRuntime)({
                onProgress: (event) => {
                    if (event.message) {
                        setUpdateNotice(event.message);
                        controlLog = appendControlLog(controlLog, event.message);
                        setOutputText(controlLog);
                    }
                },
            });
            if (inspection.installedVersion !== undefined) {
                setInstalledVersion(inspection.installedVersion);
            }
            if (inspection.latestVersion !== undefined) {
                setLatestVersion(inspection.latestVersion);
            }
            if (inspection.status === "ready") {
                const version = inspection.latestVersion || inspection.installedVersion;
                const message = version ? `已是最新版本 ${version}` : "当前已是最新版本";
                setUpdateNotice(message);
                controlLog = appendControlLog(controlLog, message);
                setOutputText(controlLog);
                if (version) {
                    try {
                        controlLog = appendControlLog(controlLog, `正在读取 ${version} 的发行说明`);
                        setOutputText(controlLog);
                        const release = await (0, deepseek_harness_web_runtime_js_1.readDeepSeekHarnessReleaseNotes)(version);
                        if (release) {
                            const published = release.publishedAt ? new Date(release.publishedAt).toLocaleString("zh-CN", { hour12: false, timeZone: "Asia/Shanghai" }) : "";
                            controlLog = appendInstallationOutput(controlLog, `\n${release.name}${published ? `\n发布于 ${published}` : ""}\n${release.body}\n${release.url}`);
                        }
                        else {
                            controlLog = appendControlLog(controlLog, `未找到 ${version} 对应的 GitHub Release`);
                        }
                        setOutputText(controlLog);
                    }
                    catch (error) {
                        console.warn("DeepSeek Harness release notes read failed", error);
                        controlLog = appendControlLog(controlLog, `发行说明读取失败：${errorMessage(error)}`);
                        setOutputText(controlLog);
                    }
                }
                return;
            }
            if (inspection.status === "update_available") {
                setManualUpdateAvailable(true);
                const message = `发现更新 ${inspection.latestVersion || "新版本"}`;
                setUpdateNotice(message);
                controlLog = appendControlLog(controlLog, message);
                setOutputText(controlLog);
                return;
            }
            if (inspection.status === "uninitialized") {
                const message = "DSH 运行时尚未安装";
                setUpdateNotice(message);
                controlLog = appendControlLog(controlLog, message);
                setOutputText(controlLog);
                return;
            }
            const message = inspection.message || "检查更新失败";
            setUpdateNotice(message);
            controlLog = appendControlLog(controlLog, message);
            setOutputText(controlLog);
        } catch (error) {
            console.error("DeepSeek Harness manual update check failed", error);
            setUpdateNotice("检查更新失败");
        } finally {
            setCheckingUpdate(false);
        }
    }
    async function resetRuntime() {
        if (!runtimeReady || resetting || checkingUpdate || loading) {
            return;
        }
        let controlLog = "";
        webViewLifecycleGeneration += 1;
        setResetting(true);
        setSubagentPanelOpen(false);
        setSubagentPanelState(null);
        setSubagentPanelError("");
        setResetNotice("正在删除 DSH 运行时...");
        setUpdateNotice("");
        setServerUrl("");
        setPageLoading(false);
        setErrorText("");
        setOutputText("");
        setInstalledVersion("");
        setLatestVersion("");
        setManualUpdateAvailable(false);
        setRuntimeAction("initialize");
        setStatusText("正在删除 DSH 运行时...");
        setProgress(0);
        try {
            const result = await (0, deepseek_harness_web_runtime_js_1.resetDeepSeekHarnessRuntime)({
                onProgress: (message) => {
                    controlLog = appendControlLog(controlLog, message);
                    setOutputText(controlLog);
                    setResetNotice(message);
                    setStatusText(message);
                },
            });
            if (!result.success) {
                const message = result.message || "DSH 重置失败";
                setRuntimeAction("");
                setErrorText(message);
                setStatusText("DeepSeek Harness 重置失败");
                setResetNotice(message);
                return;
            }
            setServerUrl("");
            setPageLoading(false);
            setErrorText("");
            setInstalledVersion("");
            setLatestVersion("");
            setManualUpdateAvailable(false);
            setRuntimeAction("initialize");
            setStatusText("DeepSeek Harness 已重置完成。");
            setProgress(0);
            setResetNotice("已重置完成");
        }
        catch (error) {
            console.error("DeepSeek Harness reset failed", error);
            setRuntimeAction("");
            setErrorText("DSH 重置失败");
            setStatusText("DeepSeek Harness 重置失败");
            setResetNotice("DSH 重置失败");
        }
        finally {
            setResetting(false);
        }
    }
    async function inspectAndRoute() {
        setLoading(true);
        setRuntimeAction("");
        setServerUrl("");
        setPageLoading(false);
        setErrorText("");
        setOutputText("");
        setInstalledVersion("");
        setLatestVersion("");
        setStatusText("正在检查 DeepSeek Harness");
        setProgress(5);
        try {
            const inspection = await (0, deepseek_harness_web_runtime_js_1.inspectDeepSeekHarnessRuntime)({
                onProgress: (event) => {
                    setStatusText(event.message);
                    setProgress(clampProgress(event.progress));
                },
            });
            if (inspection.installedVersion !== undefined) {
                setInstalledVersion(inspection.installedVersion);
            }
            if (inspection.latestVersion !== undefined) {
                setLatestVersion(inspection.latestVersion);
            }
            if (inspection.status === "ready") {
                await startInstalledRuntime(false);
                return;
            }
            if (inspection.status === "uninitialized") {
                setRuntimeAction("initialize");
                setStatusText(inspection.message);
                setProgress(0);
                return;
            }
            if (inspection.status === "update_available") {
                setRuntimeAction("update");
                setStatusText(inspection.message);
                setProgress(0);
                return;
            }
            if (inspection.diagnostic !== undefined && inspection.diagnostic.trim()) {
                setErrorText(`${inspection.message}\n\n${inspection.diagnostic.trim()}`);
            } else {
                setErrorText(inspection.message);
            }
            setStatusText("DeepSeek Harness 检查失败");
        } catch (error) {
            console.error("DeepSeek Harness inspection failed", error);
            setErrorText("无法检查 DeepSeek Harness 运行时。");
            setStatusText("DeepSeek Harness 检查失败");
        } finally {
            setLoading(false);
        }
    }
    async function installAndStart() {
        let installationOutput = "";
        setManualUpdateAvailable(false);
        setResetNotice("");
        setUpdateNotice("");
        setLoading(true);
        setRuntimeAction("");
        setServerUrl("");
        setPageLoading(false);
        setErrorText("");
        setOutputText("");
        setStatusText("正在准备 DeepSeek Harness 安装");
        setProgress(12);
        try {
            const result = await (0, deepseek_harness_web_runtime_js_1.installDeepSeekHarnessRuntime)({
                onProgress: (event) => {
                    setStatusText(event.message);
                    setProgress(clampProgress(event.progress));
                    if (event.output !== undefined && event.output) {
                        installationOutput = appendInstallationOutput(installationOutput, event.output);
                        setOutputText(installationOutput);
                    }
                },
            });
            if (!result.success) {
                const executionDetails = formatInstallExecution(result);
                if (executionDetails) {
                    setOutputText(executionDetails);
                }
                setErrorText(formatInstallFailure(result));
                setStatusText(result.message);
                return;
            }
            await startInstalledRuntime(false);
        } catch (error) {
            console.error("DeepSeek Harness installation failed", error);
            setErrorText("DeepSeek Harness 安装未能完成。");
            setStatusText("DeepSeek Harness 安装失败");
        } finally {
            setLoading(false);
        }
    }
    const actionButtons = [];
    if (!loading && !resetting && !errorText && runtimeAction === "initialize") {
        actionButtons.push(UI.Button({
            fillMaxWidth: true,
            height: 48,
            shape: {
                cornerRadius: 8
            },
            contentPadding: {
                horizontal: 16,
                vertical: 0
            },
            onClick: installAndStart,
        }, UI.Row({
            fillMaxWidth: true,
            horizontalArrangement: "center",
            verticalAlignment: "center",
        }, [
            UI.Icon({
                name: "terminal",
                size: 18,
                tint: colors.onPrimary
            }),
            UI.Spacer({
                width: 8
            }),
            UI.Text({
                text: "初始化 DeepSeek Harness",
                style: "labelLarge",
                color: colors.onPrimary,
            }),
        ])));
    }
    if (!loading && !resetting && !errorText && runtimeAction === "update") {
        actionButtons.push(UI.Button({
            fillMaxWidth: true,
            height: 48,
            shape: {
                cornerRadius: 8
            },
            contentPadding: {
                horizontal: 16,
                vertical: 0
            },
            onClick: installAndStart,
        }, UI.Row({
            fillMaxWidth: true,
            horizontalArrangement: "center",
            verticalAlignment: "center",
        }, [
            UI.Icon({
                name: "bolt",
                size: 18,
                tint: colors.onPrimary
            }),
            UI.Spacer({
                width: 8
            }),
            UI.Text({
                text: "安装更新",
                style: "labelLarge",
                color: colors.onPrimary,
            }),
        ])), UI.OutlinedButton({
            fillMaxWidth: true,
            height: 48,
            shape: {
                cornerRadius: 8
            },
            contentPadding: {
                horizontal: 16,
                vertical: 0
            },
            onClick: async () => {
                await startInstalledRuntime(false);
            },
        }, UI.Row({
            fillMaxWidth: true,
            horizontalArrangement: "center",
            verticalAlignment: "center",
        }, [
            UI.Icon({
                name: "Code",
                size: 18,
                tint: colors.primary
            }),
            UI.Spacer({
                width: 8
            }),
            UI.Text({
                text: "继续使用当前版本",
                style: "labelLarge",
                color: colors.primary,
            }),
        ])));
    }
    if (!loading && !resetting && errorText) {
        actionButtons.push(UI.Button({
            fillMaxWidth: true,
            height: 48,
            shape: {
                cornerRadius: 8
            },
            contentPadding: {
                horizontal: 16,
                vertical: 0
            },
            onClick: inspectAndRoute,
        }, UI.Row({
            fillMaxWidth: true,
            horizontalArrangement: "center",
            verticalAlignment: "center",
        }, [
            UI.Icon({
                name: "refresh",
                size: 18,
                tint: colors.onPrimary
            }),
            UI.Spacer({
                width: 8
            }),
            UI.Text({
                text: "重新检查",
                style: "labelLarge",
                color: colors.onPrimary,
            }),
        ])));
    }
    const stalledWithoutPage = !serverUrl && !loading && !resetting && !checkingUpdate && !errorText && runtimeAction === "";
    if (stalledWithoutPage) {
        actionButtons.push(UI.OutlinedButton({
            fillMaxWidth: true,
            height: 48,
            shape: {
                cornerRadius: 8
            },
            contentPadding: {
                horizontal: 16,
                vertical: 0
            },
            onClick: async () => {
                setInitialized(true);
                await restoreOrInspect();
            },
        }, UI.Row({
            fillMaxWidth: true,
            horizontalArrangement: "center",
            verticalAlignment: "center",
        }, [
            UI.Icon({
                name: "refresh",
                size: 18,
                tint: colors.primary
            }),
            UI.Spacer({
                width: 8
            }),
            UI.Text({
                text: "重新连接 DeepSeek Harness",
                style: "labelLarge",
                color: colors.primary,
            }),
        ])));
    }
    const runtimeReady = Boolean(serverUrl) && !loading && !errorText && runtimeAction === "";
    const controlsEnabled = runtimeReady && !checkingUpdate && !resetting;
    const updateControls = (0, update_controls_js_1.createDshUpdateControls)({
        UI,
        colors,
        controlsEnabled,
        settingsOpen,
        onSettings: toggleSettings,
    });
    const panelTaskCount = subagentPanelState && Number.isFinite(Number(subagentPanelState.count))
        ? Number(subagentPanelState.count)
        : 0;
    const panelRunningCount = subagentPanelState && Number.isFinite(Number(subagentPanelState.running))
        ? Number(subagentPanelState.running)
        : 0;
    const toolbarNotice = subagentPanelOpen
        ? subagentPanelCleaning
            ? "正在清理已结束任务"
            : subagentPanelLoading
                ? "正在刷新 Sub-Agent 状态"
                : subagentPanelError
                    ? "Sub-Agent 面板刷新失败"
                    : `${panelRunningCount} 个运行中 · 共 ${panelTaskCount} 个任务`
        : resetNotice || updateNotice || (runtimeReady
            ? (pageLoading ? "正在加载 DSH 页面" : "版本状态未检查")
            : "等待 DSH 服务");
    const updateToolbar = UI.Surface({
        fillMaxWidth: true,
        containerColor: colors.surfaceVariant,
        contentColor: colors.onSurfaceVariant,
    }, UI.Row({
        fillMaxWidth: true,
        padding: {
            horizontal: 12,
            vertical: 8
        },
        verticalAlignment: "center",
        horizontalArrangement: "spaceBetween",
    }, [
        UI.Column({
            weight: 1,
            spacing: 2
        }, [
            UI.Text({
                text: toolbarNotice,
                style: "labelMedium",
                color: colors.onSurfaceVariant,
                maxLines: 1,
                overflow: "ellipsis",
            }),
            ...(installedVersion || latestVersion ?
                [UI.Text({
                    text: `${installedVersion || "未安装"} → ${latestVersion || "检查中"}`,
                    style: "labelSmall",
                    color: colors.onSurfaceVariant.copy({
                        alpha: 0.72
                    }),
                    maxLines: 1,
                    overflow: "ellipsis",
                })] :
                []),
        ]),
        updateControls,
    ]));
    const busy = loading || pageLoading || resetting;
    const showProgress = busy;
    let stateLabel = "准备中";
    let stateIcon = "Code";
    let stateContainerColor = colors.surfaceVariant;
    let stateContentColor = colors.onSurfaceVariant;
    if (errorText) {
        stateLabel = "需要处理";
        stateIcon = "error";
        stateContainerColor = colors.errorContainer;
        stateContentColor = colors.onErrorContainer;
    } else if (busy) {
        stateLabel = "进行中";
        stateIcon = "sync";
        stateContainerColor = colors.secondaryContainer;
        stateContentColor = colors.onSecondaryContainer;
    } else if (resetNotice === "已重置完成") {
        stateLabel = "已重置完成";
        stateIcon = "check_circle";
        stateContainerColor = colors.primaryContainer;
        stateContentColor = colors.onPrimaryContainer;
    } else if (runtimeAction === "initialize") {
        stateLabel = "首次使用";
        stateIcon = "terminal";
        stateContainerColor = colors.tertiaryContainer;
        stateContentColor = colors.onTertiaryContainer;
    } else if (runtimeAction === "update") {
        stateLabel = "发现更新";
        stateIcon = "bolt";
        stateContainerColor = colors.tertiaryContainer;
        stateContentColor = colors.onTertiaryContainer;
    }
    const versionSummary = [];
    if (installedVersion || latestVersion) {
        versionSummary.push(UI.Column({
            fillMaxWidth: true,
            spacing: 12,
        }, [
            UI.HorizontalDivider({
                color: stateContentColor.copy({
                    alpha: 0.18
                }),
                thickness: 1,
            }),
            UI.Row({
                fillMaxWidth: true,
                horizontalArrangement: "spaceBetween",
                verticalAlignment: "center",
            }, [
                UI.Column({
                    weight: 1,
                    spacing: 2
                }, [
                    UI.Text({
                        text: "当前版本",
                        style: "labelSmall",
                        color: stateContentColor.copy({
                            alpha: 0.72
                        }),
                    }),
                    UI.Text({
                        text: installedVersion || "未安装",
                        style: "bodyMedium",
                        fontWeight: "semiBold",
                        color: stateContentColor,
                        maxLines: 1,
                        overflow: "ellipsis",
                    }),
                ]),
                UI.Column({
                    weight: 1,
                    spacing: 2,
                    horizontalAlignment: "end"
                }, [
                    UI.Text({
                        text: "最新版本",
                        style: "labelSmall",
                        color: stateContentColor.copy({
                            alpha: 0.72
                        }),
                    }),
                    UI.Text({
                        text: latestVersion || "检查中",
                        style: "bodyMedium",
                        fontWeight: "semiBold",
                        color: stateContentColor,
                        maxLines: 1,
                        overflow: "ellipsis",
                    }),
                ]),
            ]),
        ]));
    }
    const progressSummary = [];
    if (showProgress) {
        progressSummary.push(UI.Column({
            fillMaxWidth: true,
            spacing: 8,
        }, [
            UI.HorizontalDivider({
                color: stateContentColor.copy({
                    alpha: 0.18
                }),
                thickness: 1,
            }),
            UI.Row({
                fillMaxWidth: true,
                horizontalArrangement: "spaceBetween",
                verticalAlignment: "center",
            }, [
                UI.Text({
                    text: "当前进度",
                    style: "labelSmall",
                    color: stateContentColor.copy({
                        alpha: 0.72
                    }),
                }),
                UI.Text({
                    text: `${clampProgress(progress)}%`,
                    style: "labelMedium",
                    fontWeight: "semiBold",
                    color: stateContentColor,
                }),
            ]),
            UI.LinearProgressIndicator({
                fillMaxWidth: true,
                progress: clampProgress(progress) / 100,
                color: stateContentColor,
            }),
        ]));
    }
    const showOverlay = loading || !serverUrl || Boolean(errorText) || runtimeAction !== "";
    const overlay = UI.LazyColumn({
        fillMaxSize: true,
        padding: {
            horizontal: 20,
            vertical: 24
        },
        spacing: 18,
        background: colors.surface,
    }, [
        UI.Row({
            fillMaxWidth: true,
            verticalAlignment: "center",
        }, [
            UI.Surface({
                width: 42,
                height: 42,
                shape: {
                    cornerRadius: 8
                },
                containerColor: colors.primaryContainer,
                contentColor: colors.onPrimaryContainer,
            }, UI.Box({
                fillMaxSize: true,
                contentAlignment: "center",
            }, UI.Icon({
                name: "Code",
                size: 22,
                tint: colors.onPrimaryContainer,
            }))),
            UI.Spacer({
                width: 12
            }),
            UI.Column({
                weight: 1,
                spacing: 2
            }, [
                UI.Text({
                    text: "DeepSeek Harness",
                    style: "titleMedium",
                    fontWeight: "bold",
                    color: colors.onSurface,
                    maxLines: 1,
                    overflow: "ellipsis",
                }),
                UI.Text({
                    text: "DSH 运行时",
                    style: "labelMedium",
                    color: colors.onSurfaceVariant,
                }),
            ]),
            UI.Surface({
                shape: {
                    cornerRadius: 6
                },
                containerColor: stateContainerColor,
                contentColor: stateContentColor,
            }, UI.Text({
                text: stateLabel,
                padding: {
                    horizontal: 10,
                    vertical: 6
                },
                style: "labelSmall",
                fontWeight: "semiBold",
                color: stateContentColor,
                maxLines: 1,
            })),
        ]),
        UI.Surface({
            fillMaxWidth: true,
            shape: {
                cornerRadius: 8
            },
            containerColor: stateContainerColor,
            contentColor: stateContentColor,
        }, UI.Column({
            fillMaxWidth: true,
            padding: 16,
            spacing: 12,
        }, [
            UI.Row({
                fillMaxWidth: true,
                verticalAlignment: "center",
            }, [
                UI.Icon({
                    name: stateIcon,
                    size: 22,
                    tint: stateContentColor,
                    spin: busy,
                    spinDurationMs: 850,
                }),
                UI.Spacer({
                    width: 10
                }),
                UI.Column({
                    weight: 1,
                    spacing: 3
                }, [
                    UI.Text({
                        text: "当前状态",
                        style: "labelSmall",
                        color: stateContentColor.copy({
                            alpha: 0.72
                        }),
                    }),
                    UI.Text({
                        text: statusText,
                        style: "titleMedium",
                        fontWeight: "semiBold",
                        color: stateContentColor,
                        maxLines: 3,
                    }),
                ]),
            ]),
            ...(errorText ?
                [UI.Text({
                    text: errorText,
                    style: "bodySmall",
                    color: stateContentColor,
                    maxLines: 10,
                    overflow: "ellipsis",
                })] :
                []),
            ...versionSummary,
            ...progressSummary,
        ])),
        ...(outputText ?
            [UI.Surface({
                fillMaxWidth: true,
                shape: {
                    cornerRadius: 8
                },
                containerColor: colors.surfaceVariant,
                contentColor: colors.onSurfaceVariant,
            }, UI.Column({
                fillMaxWidth: true,
                padding: 14,
                spacing: 10,
            }, [
                UI.Row({
                    verticalAlignment: "center"
                }, [
                    UI.Icon({
                        name: "terminal",
                        size: 18,
                        tint: colors.onSurfaceVariant,
                    }),
                    UI.Spacer({
                        width: 8
                    }),
                    UI.Text({
                        text: resetNotice ? "操作输出" : "安装输出",
                        style: "labelMedium",
                        fontWeight: "semiBold",
                        color: colors.onSurfaceVariant,
                    }),
                ]),
                UI.HorizontalDivider({
                    color: colors.outlineVariant.copy({
                        alpha: 0.55
                    }),
                    thickness: 1,
                }),
                UI.SelectionContainer({}, UI.Text({
                    text: formatVisibleInstallationOutput(outputText),
                    style: "bodySmall",
                    fontFamily: "monospace",
                    fontSize: 11,
                    color: colors.onSurfaceVariant,
                    maxLines: 16,
                    overflow: "ellipsis",
                })),
            ]))] :
            []),
        ...(!runtimeReady && !errorText && !busy && runtimeAction === "" ?
            [UI.Surface({
                fillMaxWidth: true,
                shape: {
                    cornerRadius: 8
                },
                containerColor: colors.surfaceVariant,
                contentColor: colors.onSurfaceVariant,
            }, UI.Column({
                fillMaxWidth: true,
                padding: 14,
                spacing: 10,
            }, [
                UI.Row({
                    verticalAlignment: "center"
                }, [
                    UI.Icon({
                        name: "info",
                        size: 18,
                        tint: colors.onSurfaceVariant,
                    }),
                    UI.Spacer({
                        width: 8,
                    }),
                    UI.Text({
                        text: "DeepSeek Harness 尚未就绪",
                        style: "labelMedium",
                        fontWeight: "semiBold",
                        color: colors.onSurfaceVariant,
                    }),
                ]),
                UI.Text({
                    text: "DSH 运行时当前未在设备上提供可用服务。常见原因：运行时尚未初始化、安装尚未完成，或后台服务进程未启动。可先点“初始化 DeepSeek Harness”安装运行时，或点下方“重新连接”刷新状态。如已安装仍无法连接，请在系统日志中检索 deepseek_harness 相关条目排查。",
                    style: "bodySmall",
                    color: colors.onSurfaceVariant,
                    maxLines: 14,
                    overflow: "ellipsis",
                }),
            ]))] :
            []),
        ...(actionButtons.length > 0 ?
            [UI.Column({
                fillMaxWidth: true,
                spacing: 10,
            }, actionButtons)] :
            []),
    ]);
    const webContent = serverUrl ?
        UI.Box({
            fillMaxSize: true,
            background: colors.surface
        }, [
            UI.WebView({
                key: `deepseek_harness_webview_${reloadToken}`,
                controller: webViewController,
                fillMaxSize: true,
                url: serverUrl,
                javaScriptEnabled: true,
                domStorageEnabled: true,
                allowFileAccess: false,
                allowContentAccess: false,
                supportZoom: false,
                useWideViewPort: true,
                loadWithOverviewMode: true,
                safeBrowsingEnabled: true,
                onPageStarted: () => {
                    setPageLoading(true);
                    setProgress(92);
                    setStatusText("正在加载 DeepSeek Harness Web 资源");
                },
                onProgressChanged: (event) => {
                    setProgress(Math.max(92, clampProgress(event.progress)));
                },
                onPageFinished: () => {
                    setProgress(100);
                    setStatusText("DeepSeek Harness 已就绪");
                    setPageLoading(false);
                    void loadMobileLayoutAssets()
                        .then((assets) => applyMobileLayoutCss(webViewController, assets))
                        .then(() => {
                            console.log("[DSH Sidebar] mobile layout CSS applied");
                        })
                        .catch((error) => {
                            console.warn("[DSH Sidebar] mobile layout injection failed", error);
                        });
                },
                onReceivedError: async () => {
                    if (webViewGeneration !== webViewLifecycleGeneration) {
                        return;
                    }
                    const failure = await (0, deepseek_harness_web_runtime_js_1.readDeepSeekHarnessWebFailure)();
                    if (webViewGeneration !== webViewLifecycleGeneration) {
                        return;
                    }
                    setPageLoading(false);
                    setServerUrl("");
                    const message = typeof failure === "string" && failure.trim()
                        ? failure.trim()
                        : "DeepSeek Harness Web 页面加载失败，请重新检查。";
                    setErrorText(message);
                    setStatusText("DeepSeek Harness 页面加载失败");
                },
            }),
            showOverlay ? overlay : UI.Spacer({
                height: 0
            }),
        ]) :
        overlay;
    const subagentPanelContent = (0, subagent_panel_js_1.createDshSubagentPanel)({
        UI,
        colors,
        panelState: subagentPanelState,
        panelLoading: subagentPanelLoading,
        panelCleaning: subagentPanelCleaning,
        cleanupNotice: subagentPanelCleanupNotice,
        panelError: subagentPanelError,
        onRefresh: refreshSubagentPanel,
        onClear: cleanupSubagentPanel,
    });
    const settingsContent = UI.Surface({
        fillMaxSize: true,
        containerColor: colors.surface,
        contentColor: colors.onSurface,
    }, UI.LazyColumn({
        fillMaxSize: true,
        padding: { horizontal: 16, vertical: 16 },
        spacing: 12,
    }, [
        UI.Row({
            fillMaxWidth: true,
            verticalAlignment: "center",
        }, [
            UI.Button({
                width: 36,
                height: 36,
                contentPadding: { horizontal: 0, vertical: 0 },
                contentDescription: "返回 DeepSeek Harness",
                onClick: closeSettings,
            }, UI.Icon({ name: "arrow_back", size: 18, tint: colors.onSurface })),
            UI.Spacer({ width: 10 }),
            UI.Column({ weight: 1, spacing: 1 }, [
                UI.Text({ text: "DeepSeek Harness 设置", style: "titleMedium", fontWeight: "bold", color: colors.onSurface }),
                UI.Text({ text: "运行时与 Sub-Agent 工具", style: "labelSmall", color: colors.onSurfaceVariant }),
            ]),
        ]),
        UI.HorizontalDivider({ color: colors.outlineVariant, thickness: 1 }),
        UI.Row({
            fillMaxWidth: true,
            spacing: 8,
        }, [
            UI.Button({
                weight: 1,
                height: 82,
                enabled: controlsEnabled,
                onClick: runUpdateAction,
                contentPadding: { horizontal: 6, vertical: 8 },
            }, UI.Column({ fillMaxWidth: true, horizontalAlignment: "center", spacing: 5 }, [
                UI.Icon({ name: checkingUpdate ? "sync" : manualUpdateAvailable ? "bolt" : "refresh", size: 20, tint: colors.onPrimary, spin: checkingUpdate, spinDurationMs: 850 }),
                UI.Text({ text: manualUpdateAvailable ? "安装更新" : "检查更新", style: "labelMedium", color: colors.onPrimary, maxLines: 1, overflow: "ellipsis" }),
                UI.Text({ text: "检查运行时版本", style: "labelSmall", color: colors.onPrimary.copy({ alpha: 0.78 }), maxLines: 1, overflow: "ellipsis" }),
            ])),
            UI.Button({
                weight: 1,
                height: 82,
                enabled: controlsEnabled,
                onClick: resetRuntime,
                contentPadding: { horizontal: 6, vertical: 8 },
            }, UI.Column({ fillMaxWidth: true, horizontalAlignment: "center", spacing: 5 }, [
                UI.Icon({ name: resetting ? "sync" : "delete", size: 20, tint: colors.onPrimary, spin: resetting, spinDurationMs: 850 }),
                UI.Text({ text: "重置运行时", style: "labelMedium", color: colors.onPrimary, maxLines: 1, overflow: "ellipsis" }),
                UI.Text({ text: "清理运行时", style: "labelSmall", color: colors.onPrimary.copy({ alpha: 0.78 }), maxLines: 1, overflow: "ellipsis" }),
            ])),
            UI.OutlinedButton({
                weight: 1,
                height: 82,
                enabled: !subagentPanelLoading && !subagentPanelCleaning && !resetting,
                onClick: openSubagentFromSettings,
                contentPadding: { horizontal: 6, vertical: 8 },
            }, UI.Column({ fillMaxWidth: true, horizontalAlignment: "center", spacing: 5 }, [
                UI.Icon({ name: subagentPanelLoading ? "sync" : "dashboard", size: 20, tint: colors.primary, spin: subagentPanelLoading, spinDurationMs: 850 }),
                UI.Text({ text: "监控面板", style: "labelMedium", color: colors.primary, maxLines: 1, overflow: "ellipsis" }),
                UI.Text({ text: `${panelRunningCount} 运行 · ${panelTaskCount} 总数`, style: "labelSmall", color: colors.onSurfaceVariant, maxLines: 1, overflow: "ellipsis" }),
            ])),
        ]),
        UI.Surface({
            fillMaxWidth: true,
            height: 190,
            shape: { cornerRadius: 8 },
            containerColor: colors.surfaceVariant,
            contentColor: colors.onSurfaceVariant,
        }, UI.LazyColumn({
            fillMaxSize: true,
            padding: 12,
            spacing: 2,
        }, [
            UI.Row({ verticalAlignment: "center" }, [
                UI.Icon({ name: "terminal", size: 16, tint: colors.onSurfaceVariant }),
                UI.Spacer({ width: 7 }),
                UI.Text({ text: "操作输出", style: "labelMedium", fontWeight: "semiBold", color: colors.onSurfaceVariant }),
            ]),
            UI.HorizontalDivider({ color: colors.outlineVariant, thickness: 1 }),
            UI.SelectionContainer({}, UI.Text({
                text: outputText ? formatVisibleInstallationOutput(outputText) : "暂无输出",
                style: "bodySmall",
                fontFamily: "monospace",
                fontSize: 11,
                color: colors.onSurfaceVariant,
            })),
        ])),
    ]));
    const mainContent = settingsOpen
        ? settingsContent
        : UI.Box({
        fillMaxSize: true,
        background: colors.surface,
    }, [
        webContent,
        subagentPanelOpen
            ? UI.Surface({
                fillMaxSize: true,
                containerColor: colors.surface,
                contentColor: colors.onSurface,
            }, subagentPanelContent)
            : UI.Spacer({ height: 0 }),
    ]);
    return UI.Box({
        fillMaxSize: true,
        background: colors.surface,
        onLoad: async () => {
            const idleWithoutPage = !serverUrl && !loading && !errorText && runtimeAction === "";
            if (!initialized || idleWithoutPage) {
                setInitialized(true);
                await restoreOrInspect();
            }
        },
    }, UI.Column({
        fillMaxSize: true,
        spacing: 0,
    }, [
        updateToolbar,
        UI.Box({
            fillMaxWidth: true,
            weight: 1,
            background: colors.surface,
        }, mainContent),
    ]));
}
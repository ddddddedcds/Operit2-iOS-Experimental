#[allow(non_snake_case)]
/// Builds the JavaScript prelude exposed to executable tool scripts.
pub fn buildExecutionPreludeSource() -> String {
    r#"
        function __operitGetActiveCallRuntime() {
            var root = typeof globalThis !== 'undefined'
                ? globalThis
                : (typeof window !== 'undefined' ? window : this);
            var runtime =
                root &&
                root.__operit_call_runtime_ref &&
                typeof root.__operit_call_runtime_ref === 'object'
                    ? root.__operit_call_runtime_ref
                    : __operit_call_runtime;
            return runtime && typeof runtime === 'object' ? runtime : __operit_call_runtime;
        }
        function __operitInvokeCallRuntime(methodName, argsLike) {
            var runtime = __operitGetActiveCallRuntime();
            var method = runtime ? runtime[methodName] : undefined;
            if (typeof method !== 'function') {
                return undefined;
            }
            return method.apply(runtime, Array.prototype.slice.call(argsLike || []));
        }
        function __operitInvokeCallRuntimeConsole(methodName, argsLike) {
            var runtime = __operitGetActiveCallRuntime();
            var runtimeConsole = runtime && runtime.console ? runtime.console : null;
            var method = runtimeConsole ? runtimeConsole[methodName] : undefined;
            if (typeof method !== 'function') {
                return undefined;
            }
            return method.apply(runtimeConsole, Array.prototype.slice.call(argsLike || []));
        }
        var sendIntermediateResult = function() { return __operitInvokeCallRuntime('sendIntermediateResult', arguments); };
        var emit = function() { return __operitInvokeCallRuntime('emit', arguments); };
        var delta = function() { return __operitInvokeCallRuntime('delta', arguments); };
        var log = function() { return __operitInvokeCallRuntime('log', arguments); };
        var update = function() { return __operitInvokeCallRuntime('update', arguments); };
        var done = function() { return __operitInvokeCallRuntime('done', arguments); };
        var complete = function() { return __operitInvokeCallRuntime('complete', arguments); };
        var getEnv = function() { return __operitInvokeCallRuntime('getEnv', arguments); };
        var getPluginConfigDir = function() { return __operitInvokeCallRuntime('getPluginConfigDir', arguments); };
        var getState = function() { return __operitInvokeCallRuntime('getState', arguments); };
        var getLang = function() { return __operitInvokeCallRuntime('getLang', arguments); };
        var getCallerName = function() { return __operitInvokeCallRuntime('getCallerName', arguments); };
        var getChatId = function() { return __operitInvokeCallRuntime('getChatId', arguments); };
        var getCallerCardId = function() { return __operitInvokeCallRuntime('getCallerCardId', arguments); };
        var __handleAsync = function() { return __operitInvokeCallRuntime('handleAsync', arguments); };
        var console = {
            log: function() { return __operitInvokeCallRuntimeConsole('log', arguments); },
            info: function() { return __operitInvokeCallRuntimeConsole('info', arguments); },
            warn: function() { return __operitInvokeCallRuntimeConsole('warn', arguments); },
            error: function() { return __operitInvokeCallRuntimeConsole('error', arguments); }
        };
        var reportDetailedError = function() { return __operitInvokeCallRuntime('reportDetailedError', arguments); };
        // ── iOS 兼容层：Android 专属全局的安全 stub ─────────────────────────
        // 市场 ToolPkg（Android 生态）常直接调用 Java/OkHttp/SystemManager 等
        // Android 宿主 API。iOS 上没有这些宿主实现，直接引用会 ReferenceError
        // 导致整个插件脚本崩。这里在它们缺失时注入"无限链 Proxy stub"：
        // 属性读取返回嵌套 stub，函数调用返回 undefined 并 warn 一次（no-op 降级），
        // 插件 UI/数据逻辑可继续运行，只有系统级调用静默失效。
        function __operitAndroidStub(name) {
            var warned = false;
            var proxy;
            var handler = {
                get: function(target, prop) {
                    if (typeof prop === 'symbol') { return undefined; }
                    var key = String(prop);
                    if (key === 'toString' || key === 'valueOf' || key === 'then' ||
                        key === 'constructor' || key === 'toJSON') { return undefined; }
                    return __operitAndroidStub(name + '.' + key);
                },
                apply: function() {
                    if (!warned) {
                        warned = true;
                        try {
                            console.warn('[iOS 兼容层] Android API ' + name +
                                ' 在 iOS 不可用，调用已降级为 no-op');
                        } catch (ignored) {}
                    }
                    return proxy;
                },
                construct: function() {
                    if (!warned) {
                        warned = true;
                        try {
                            console.warn('[iOS 兼容层] Android API ' + name +
                                ' 在 iOS 不可用，new 调用已降级为 no-op');
                        } catch (ignored) {}
                    }
                    return proxy;
                }
            };
            var fn = function() { return proxy; };
            proxy = new Proxy(fn, handler);
            return proxy;
        }
        var __operitAndroidGlobals = [
            'Java', 'Android', 'PackageManager', 'ContentProvider',
            'SystemManager', 'DeviceController', 'OkHttpClientBuilder',
            'OkHttpClient', 'RequestBuilder', 'OkHttp'
        ];
        for (var __i = 0; __i < __operitAndroidGlobals.length; __i++) {
            var __g = __operitAndroidGlobals[__i];
            if (typeof globalThis[__g] === 'undefined') {
                globalThis[__g] = __operitAndroidStub(__g);
            }
        }
        var ToolPkg = globalThis.ToolPkg;
        var Tools = globalThis.Tools;
        var Java = globalThis.Java;
        var Android = globalThis.Android;
        var PackageManager = globalThis.PackageManager;
        var ContentProvider = globalThis.ContentProvider;
        var SystemManager = globalThis.SystemManager;
        var DeviceController = globalThis.DeviceController;
        var OperitComposeDslRuntime = globalThis.OperitComposeDslRuntime;
        var CryptoJS = globalThis.CryptoJS;
        var Jimp = globalThis.Jimp;
        var UINode = globalThis.UINode;
        var PluginConfig = globalThis.PluginConfig;
        var RuntimeContext = globalThis.RuntimeContext;
        var withContext = globalThis.withContext;
        var OkHttpClientBuilder = globalThis.OkHttpClientBuilder;
        var OkHttpClient = globalThis.OkHttpClient;
        var RequestBuilder = globalThis.RequestBuilder;
        var OkHttp = globalThis.OkHttp;
        var pako = globalThis.pako;
        var _ = globalThis._;
        var dataUtils = globalThis.dataUtils;
        var toolCall = globalThis.toolCall;
    "#
    .to_string()
}

#[allow(non_snake_case)]
/// Loads the runtime bridge script used by JavaScript execution.
pub fn buildExecutionRuntimeBridgeScript() -> String {
    let script = include_str!("JsExecutionRuntimeBridge.script.js");
    script.to_string()
}

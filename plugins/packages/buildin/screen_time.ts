/* METADATA
{
    "name": "screen_time",
    "display_name": {
        "zh": "屏幕使用时间（锁应用）",
        "en": "Screen Time (lock apps)"
    },
    "description": {
        "zh": "用苹果官方屏幕使用时间（FamilyControls）锁定/解锁应用，iOS 16+。AI 可直接按 bundle id 锁/解锁任意应用（无需选应用授权）。需配套 native 桥 Tools.Net.screenTimeAuthorize / screenTimeLock / screenTimeUnlock（连 127.0.0.1:8891 驱动 App 内 Swift ScreenTimeServer）。",
        "en": "Lock/unlock apps via Apple's official Screen Time (FamilyControls) API, iOS 16+. AI can lock/unlock any app directly by bundle id (no picker needed). Requires companion native bridge Tools.Net.screenTimeAuthorize / screenTimeLock / screenTimeUnlock (talking to 127.0.0.1:8891 to drive the in-app Swift ScreenTimeServer)."
    },
    "enabledByDefault": true,
    "category": "System",
    "tools": [
        {
            "name": "screen_time_authorize",
            "description": {
                "zh": "请求屏幕使用时间授权（首次使用必须调用一次；系统会弹出授权，用户允许后 AI 才能锁应用）。",
                "en": "Request Screen Time authorization (must be called once before locking; the system shows a consent prompt)."
            },
            "parameters": []
        },
        {
            "name": "screen_time_lock",
            "description": {
                "zh": "锁定指定应用（给它盖盾牌，打开会被拦截）。参数 bundle_id 为目标应用的 Bundle ID，例如 com.tencent.xin。可选 title/subtitle/button 自定义屏蔽页文案（AI 可自由发挥，如「保持活力与激情」）——不传则用默认文案。",
                "en": "Lock (shield) the given app by Bundle ID, e.g. com.tencent.xin. Optional title/subtitle/button customize the shield screen text (AI may write anything); defaults are used when omitted."
            },
            "parameters": [
                {
                    "name": "bundle_id",
                    "description": {
                        "zh": "要锁定的应用的 Bundle ID。",
                        "en": "Bundle ID of the app to lock."
                    },
                    "type": "string",
                    "required": true
                },
                {
                    "name": "title",
                    "description": {
                        "zh": "屏蔽页主标题（AI 自由编写，例如「保持活力与激情」）。",
                        "en": "Shield screen main title (AI-written, e.g. \"Stay energized\")."
                    },
                    "type": "string",
                    "required": false
                },
                {
                    "name": "subtitle",
                    "description": {
                        "zh": "屏蔽页副标题（例如「专注时不使用该应用」）。",
                        "en": "Shield screen subtitle (e.g. \"Don't open this app while focusing\")."
                    },
                    "type": "string",
                    "required": false
                },
                {
                    "name": "button",
                    "description": {
                        "zh": "屏蔽页主按钮文字（默认「好的」）。",
                        "en": "Shield screen primary button label (default \"OK\")."
                    },
                    "type": "string",
                    "required": false
                }
            ]
        },
        {
            "name": "screen_time_unlock",
            "description": {
                "zh": "解除所有应用的锁定（移除盾牌）。",
                "en": "Unlock (unshield) all apps."
            },
            "parameters": []
        },
        {
            "name": "screen_time_monitor_start",
            "description": {
                "zh": "启动使用时长监控：监控指定应用（按 Bundle ID 逗号分隔），当日累计使用超过 minutes 分钟时，系统扩展会记录超时事件（吃醋巡检的「后台看你使用情况」）。之后用 screen_time_usage 查超时报告。",
                "en": "Start overuse monitoring for the given apps (comma-separated Bundle IDs): when daily cumulative usage exceeds `minutes`, the DeviceActivity extension records an overuse event. Query results with screen_time_usage."
            },
            "parameters": [
                {
                    "name": "bundle_ids",
                    "description": {
                        "zh": "要监控的应用 Bundle ID，逗号分隔，例如 com.tencent.xin,com.ss.iphone.ugc.Aweme。",
                        "en": "Comma-separated Bundle IDs to monitor, e.g. com.tencent.xin,com.ss.iphone.ugc.Aweme."
                    },
                    "type": "string",
                    "required": true
                },
                {
                    "name": "minutes",
                    "description": {
                        "zh": "当日累计使用多少分钟算过度（阈值）。",
                        "en": "Daily cumulative usage threshold in minutes."
                    },
                    "type": "number",
                    "required": true
                }
            ]
        },
        {
            "name": "screen_time_monitor_stop",
            "description": {
                "zh": "停止所有使用时长监控。",
                "en": "Stop all overuse monitoring."
            },
            "parameters": []
        },
        {
            "name": "screen_time_usage",
            "description": {
                "zh": "查询哪些被监控应用已超时（读系统扩展写入的 App Group 报告）。",
                "en": "Query which monitored apps have exceeded their usage threshold (reads the extension's App Group report)."
            },
            "parameters": []
        }
    ]
}*/

type ScreenTimeLockParams = {
    bundle_id?: string;
    title?: string;
    subtitle?: string;
    button?: string;
};

type ScreenTimeMonitorStartParams = {
    bundle_ids?: string;
    minutes?: number;
};

async function screen_time_authorize() {
    try {
        // @ts-ignore Tools.Net 由 native 运行时注入
        return await Tools.Net.screenTimeAuthorize({});
    } catch (e) {
        return `屏幕使用时间授权失败：${String(e)}。native 桥 Tools.Net.screenTimeAuthorize 尚未注册或 iOS < 16。`;
    }
}

async function screen_time_lock(params: ScreenTimeLockParams = {}) {
    const bundle_id = (params.bundle_id ?? "").trim();
    if (!bundle_id) {
        return "缺少参数 bundle_id：请提供要锁定的应用的 Bundle ID，例如 com.tencent.xin。";
    }
    // 自定义文案按 | 拼接传给 Swift 服务（AI 写的标题/副标题/按钮）。
    const parts = [bundle_id];
    if (params.title || params.subtitle || params.button) {
        parts.push(params.title ?? "", params.subtitle ?? "", params.button ?? "");
    }
    try {
        // @ts-ignore
        return await Tools.Net.screenTimeLock({ bundle_id: parts.join("|") });
    } catch (e) {
        return `锁定失败：${String(e)}。native 桥 Tools.Net.screenTimeLock 尚未注册或 iOS < 16。`;
    }
}

async function screen_time_unlock() {
    try {
        // @ts-ignore
        return await Tools.Net.screenTimeUnlock({});
    } catch (e) {
        return `解锁失败：${String(e)}。native 桥 Tools.Net.screenTimeUnlock 尚未注册或 iOS < 16。`;
    }
}

async function screen_time_monitor_start(params: ScreenTimeMonitorStartParams = {}) {
    const bundle_ids = (params.bundle_ids ?? "").trim();
    const minutes = params.minutes ?? 60;
    if (!bundle_ids) {
        return "缺少参数 bundle_ids：请提供要监控的应用 Bundle ID（逗号分隔）。";
    }
    try {
        // @ts-ignore
        return await Tools.Net.screenTimeMonitorStart({ bundle_ids, minutes });
    } catch (e) {
        return `监控启动失败：${String(e)}。native 桥 Tools.Net.screenTimeMonitorStart 尚未注册或 iOS < 16。`;
    }
}

async function screen_time_monitor_stop() {
    try {
        // @ts-ignore
        return await Tools.Net.screenTimeMonitorStop({});
    } catch (e) {
        return `停止监控失败：${String(e)}。native 桥 Tools.Net.screenTimeMonitorStop 尚未注册或 iOS < 16。`;
    }
}

async function screen_time_usage() {
    try {
        // @ts-ignore
        return await Tools.Net.screenTimeUsage({});
    } catch (e) {
        return `查询使用情况失败：${String(e)}。native 桥 Tools.Net.screenTimeUsage 尚未注册或 iOS < 16。`;
    }
}

exports.screen_time_authorize = screen_time_authorize;
exports.screen_time_lock = screen_time_lock;
exports.screen_time_unlock = screen_time_unlock;
exports.screen_time_monitor_start = screen_time_monitor_start;
exports.screen_time_monitor_stop = screen_time_monitor_stop;
exports.screen_time_usage = screen_time_usage;
exports.main = screen_time_authorize;

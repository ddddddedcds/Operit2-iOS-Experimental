/* METADATA
{
    "name": "notify",
    "display_name": {
        "zh": "通知与灵动岛",
        "en": "Notifications & Live Activities"
    },
    "description": {
        "zh": "让 AI 主动联系用户：本地通知（可延迟=定时提醒）和灵动岛/锁屏实时活动（可更新/结束）。需配套 native 桥 Tools.Net.notify / liveActivityStart / liveActivityUpdate / liveActivityEnd（连 127.0.0.1:8893 驱动 App 内 Swift NotifyServer）。",
        "en": "Let the AI reach the user proactively: local notifications (optionally delayed = scheduled reminder) and Dynamic Island / lock-screen Live Activities (updatable / endable). Requires companion native bridge Tools.Net.notify / liveActivityStart / liveActivityUpdate / liveActivityEnd (talking to 127.0.0.1:8893 to drive the in-app Swift NotifyServer)."
    },
    "enabledByDefault": true,
    "category": "System",
    "tools": [
        {
            "name": "notify",
            "description": {
                "zh": "给用户发一条系统通知（横幅）。delay_seconds 大于 0 时是定时提醒（例如 600 = 10 分钟后提醒）。首次调用会请求通知权限。",
                "en": "Send the user a system notification banner. delay_seconds > 0 schedules it (e.g. 600 = remind in 10 minutes). First call requests notification permission."
            },
            "parameters": [
                {
                    "name": "title",
                    "description": {
                        "zh": "通知标题（简短，例如「搞定啦」）。",
                        "en": "Notification title, e.g. \"Done\"."
                    },
                    "type": "string",
                    "required": true
                },
                {
                    "name": "body",
                    "description": {
                        "zh": "通知正文。",
                        "en": "Notification body."
                    },
                    "type": "string",
                    "required": true
                },
                {
                    "name": "delay_seconds",
                    "description": {
                        "zh": "延迟秒数（默认 0 = 立即发送；>0 为定时提醒）。",
                        "en": "Delay in seconds (default 0 = immediate; >0 schedules)."
                    },
                    "type": "number",
                    "required": false
                }
            ]
        },
        {
            "name": "live_activity_start",
            "description": {
                "zh": "在灵动岛/锁屏启动一个实时活动（iOS 16.1+，iPhone 14 Pro 及以上显示在灵动岛）。用于持续展示状态（如倒计时、进度、监控中）。",
                "en": "Start a Live Activity on the Dynamic Island / lock screen (iOS 16.1+, shown on the island on iPhone 14 Pro+). Use for persistent status (countdown, progress, monitoring)."
            },
            "parameters": [
                {
                    "name": "title",
                    "description": {
                        "zh": "实时活动标题。",
                        "en": "Live activity title."
                    },
                    "type": "string",
                    "required": true
                },
                {
                    "name": "body",
                    "description": {
                        "zh": "实时活动内容（可后续用 live_activity_update 更新）。",
                        "en": "Live activity content (updatable later via live_activity_update)."
                    },
                    "type": "string",
                    "required": true
                }
            ]
        },
        {
            "name": "live_activity_update",
            "description": {
                "zh": "更新当前实时活动的内容（例如倒计时每秒/每分钟刷新）。",
                "en": "Update the current Live Activity content."
            },
            "parameters": [
                {
                    "name": "title",
                    "description": {
                        "zh": "新的标题。",
                        "en": "New title."
                    },
                    "type": "string",
                    "required": true
                },
                {
                    "name": "body",
                    "description": {
                        "zh": "新的内容。",
                        "en": "New body."
                    },
                    "type": "string",
                    "required": true
                }
            ]
        },
        {
            "name": "live_activity_end",
            "description": {
                "zh": "结束当前的实时活动（从灵动岛/锁屏移除）。",
                "en": "End the current Live Activity (remove from island / lock screen)."
            },
            "parameters": []
        }
    ]
}*/

type NotifyParams = {
    title?: string;
    body?: string;
    delay_seconds?: number;
};

async function notify(params: NotifyParams = {}) {
    const title = (params.title ?? "").trim();
    const body = params.body ?? "";
    const delay_seconds = params.delay_seconds ?? 0;
    if (!title) {
        return "缺少参数 title：请提供通知标题。";
    }
    try {
        // @ts-ignore Tools.Net 由 native 运行时注入
        return await Tools.Net.notify({ title, body, delay_seconds });
    } catch (e) {
        return `发送通知失败：${String(e)}。native 桥 Tools.Net.notify 尚未注册或 iOS 不支持。`;
    }
}

async function live_activity_start(params: NotifyParams = {}) {
    const title = (params.title ?? "").trim();
    const body = params.body ?? "";
    if (!title) {
        return "缺少参数 title：请提供实时活动标题。";
    }
    try {
        // @ts-ignore
        return await Tools.Net.liveActivityStart({ title, body });
    } catch (e) {
        return `启动实时活动失败：${String(e)}。native 桥 Tools.Net.liveActivityStart 尚未注册或 iOS < 16.1。`;
    }
}

async function live_activity_update(params: NotifyParams = {}) {
    const title = (params.title ?? "").trim();
    const body = params.body ?? "";
    try {
        // @ts-ignore
        return await Tools.Net.liveActivityUpdate({ title, body });
    } catch (e) {
        return `更新实时活动失败：${String(e)}。native 桥 Tools.Net.liveActivityUpdate 尚未注册。`;
    }
}

async function live_activity_end() {
    try {
        // @ts-ignore
        return await Tools.Net.liveActivityEnd({});
    } catch (e) {
        return `结束实时活动失败：${String(e)}。native 桥 Tools.Net.liveActivityEnd 尚未注册。`;
    }
}

exports.notify = notify;
exports.live_activity_start = live_activity_start;
exports.live_activity_update = live_activity_update;
exports.live_activity_end = live_activity_end;
exports.main = notify;

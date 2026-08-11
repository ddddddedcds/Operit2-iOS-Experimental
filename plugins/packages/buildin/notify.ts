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
        },
        {
            "name": "notifications_list",
            "description": {
                "zh": "读取设备上最近收到的通知（来自所有 app，含被拦截的）。返回时间、app、标题、正文。可用于 AI 感知用户收到的消息/提醒。",
                "en": "Read the most recent device notifications (from all apps, including blocked ones). Returns time, app, title, body. Lets the AI be aware of the user's incoming messages/reminders."
            },
            "parameters": [
                {
                    "name": "limit",
                    "description": {
                        "zh": "返回条数（默认 20，最多 100）。",
                        "en": "Number of notifications to return (default 20, max 100)."
                    },
                    "type": "number",
                    "required": false
                }
            ]
        },
        {
            "name": "notifications_block",
            "description": {
                "zh": "屏蔽某个 app 的通知（横幅/锁屏/声音全不显示），不影响 app 本身使用。例：屏蔽某群通知轰炸的 app。",
                "en": "Block one app's notifications (banner/lock-screen/sound all hidden) without affecting the app itself. E.g. silence a noisy app."
            },
            "parameters": [
                {
                    "name": "bundle_id",
                    "description": {
                        "zh": "App 的 bundle id，如 com.tencent.mqq。",
                        "en": "App bundle id, e.g. com.tencent.mqq."
                    },
                    "type": "string",
                    "required": true
                }
            ]
        },
        {
            "name": "notifications_unblock",
            "description": {
                "zh": "恢复某个 app 的通知显示（与 notifications_block 相反）。",
                "en": "Restore one app's notifications (opposite of notifications_block)."
            },
            "parameters": [
                {
                    "name": "bundle_id",
                    "description": {
                        "zh": "App 的 bundle id。",
                        "en": "App bundle id."
                    },
                    "type": "string",
                    "required": true
                }
            ]
        },
        {
            "name": "notifications_blocked",
            "description": {
                "zh": "列出当前通知被屏蔽的所有 app 的 bundle id。",
                "en": "List bundle ids of all apps whose notifications are currently blocked."
            },
            "parameters": []
        },
        {
            "name": "app_usage_report",
            "description": {
                "zh": "读取前台 app 使用情况：当前正在用哪个 app（用了多久）+ 最近使用历史 + 各 app 累计时长。可用于感知用户在干什么、提醒休息、统计使用习惯。",
                "en": "Read foreground-app usage: which app is currently in use (and for how long) + recent usage history + per-app total time. Lets the AI know what the user is doing, remind breaks, or track habits."
            },
            "parameters": [
                {
                    "name": "limit",
                    "description": {
                        "zh": "返回最近多少条使用记录（默认 20，最多 100）。",
                        "en": "Number of recent usage entries to return (default 20, max 100)."
                    },
                    "type": "number",
                    "required": false
                }
            ]
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

async function notifications_list(params: { limit?: number } = {}) {
    const limit = params.limit ?? 20;
    try {
        // @ts-ignore
        return await Tools.Net.notificationsList({ limit });
    } catch (e) {
        return `读取通知失败：${String(e)}。native 桥 Tools.Net.notificationsList 尚未注册。`;
    }
}

async function notifications_block(params: { bundle_id: string } = { bundle_id: "" }) {
    const bid = (params.bundle_id ?? "").trim();
    if (!bid) {
        return "缺少参数 bundle_id：请提供要屏蔽通知的 app 的 bundle id。";
    }
    try {
        // @ts-ignore
        return await Tools.Net.notificationsBlock({ bundle_id: bid });
    } catch (e) {
        return `屏蔽通知失败：${String(e)}。native 桥 Tools.Net.notificationsBlock 尚未注册。`;
    }
}

async function notifications_unblock(params: { bundle_id: string } = { bundle_id: "" }) {
    const bid = (params.bundle_id ?? "").trim();
    if (!bid) {
        return "缺少参数 bundle_id：请提供要恢复通知的 app 的 bundle id。";
    }
    try {
        // @ts-ignore
        return await Tools.Net.notificationsUnblock({ bundle_id: bid });
    } catch (e) {
        return `恢复通知失败：${String(e)}。native 桥 Tools.Net.notificationsUnblock 尚未注册。`;
    }
}

async function notifications_blocked() {
    try {
        // @ts-ignore
        return await Tools.Net.notificationsBlocked({});
    } catch (e) {
        return `查询通知屏蔽名单失败：${String(e)}。native 桥 Tools.Net.notificationsBlocked 尚未注册。`;
    }
}

async function app_usage_report(params: { limit?: number } = {}) {
    const limit = params.limit ?? 20;
    try {
        // @ts-ignore
        return await Tools.Net.appUsageReport({ limit });
    } catch (e) {
        return `读取使用情况失败：${String(e)}。native 桥 Tools.Net.appUsageReport 尚未注册。`;
    }
}

exports.notify = notify;
exports.live_activity_start = live_activity_start;
exports.live_activity_update = live_activity_update;
exports.live_activity_end = live_activity_end;
exports.notifications_list = notifications_list;
exports.notifications_block = notifications_block;
exports.notifications_unblock = notifications_unblock;
exports.notifications_blocked = notifications_blocked;
exports.app_usage_report = app_usage_report;
exports.main = notify;

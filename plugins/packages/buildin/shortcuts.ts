/* METADATA
{
    "name": "shortcuts",
    "display_name": {
        "zh": "快捷指令",
        "en": "Shortcuts"
    },
    "description": {
        "zh": "运行用户在 iOS「快捷指令」App 里建好的自动化（非越狱/越狱均可用）。AI 说「把勿扰模式打开」之类时，先问/确认用户已建对应快捷指令名，再调用 run_shortcut。需配套 native 桥 Tools.Net.runShortcut（连 127.0.0.1:8891 经 OperitLocalServer 路由驱动 App 内 Swift ShortcutsServer）。",
        "en": "Run the user's iOS Shortcuts automations (works on both jailed and jailbroken devices). When the user asks for something system-level (e.g. toggle Do Not Disturb), ask/confirm the shortcut name exists, then call run_shortcut. Requires companion native bridge Tools.Net.runShortcut (talking to 127.0.0.1:8891 via OperitLocalServer to drive the in-app Swift ShortcutsServer)."
    },
    "enabledByDefault": true,
    "category": "System",
    "tools": [
        {
            "name": "run_shortcut",
            "description": {
                "zh": "运行一个 iOS 快捷指令（按名称）。用户在「快捷指令」App 里建好的自动化都能跑。",
                "en": "Run one iOS Shortcut by name. Any automation the user created in the Shortcuts app can be triggered."
            },
            "parameters": [
                {
                    "name": "name",
                    "description": {
                        "zh": "快捷指令的名称（用户在建快捷指令时起的名字），例如「打开勿扰模式」。",
                        "en": "The shortcut's display name, e.g. \"打开勿扰模式\"."
                    },
                    "type": "string",
                    "required": true
                }
            ]
        }
    ]
}*/

type ShortcutRunParams = {
    name?: string;
};

async function run_shortcut(params: ShortcutRunParams = {}) {
    const name = (params.name ?? "").trim();
    if (!name) {
        return "缺少参数 name：请提供要运行的快捷指令名称。";
    }
    try {
        // @ts-ignore Tools.Net 由 native 运行时注入
        return await Tools.Net.runShortcut({ name });
    } catch (e) {
        return `运行快捷指令失败：${String(e)}。native 桥 Tools.Net.runShortcut 尚未注册。`;
    }
}

exports.run_shortcut = run_shortcut;
exports.main = run_shortcut;

/* METADATA
{
    "name": "device_automation",
    "display_name": {
        "zh": "设备自动化（AutoGLM 子代理）",
        "en": "Device Automation (AutoGLM subagent)"
    },
    "description": {
        "zh": "将设备自动化封装为可供主聊天 AI 调用的子代理工具包：给定自然语言目标，由 AutoGLM 云端大脑看屏决策、ios-mcp 系统级手执行，循环直至完成。需配套 native 桥 Tools.Net.deviceAgentStart / deviceAgentStop / deviceAgentStatus（通过 loopback TCP 127.0.0.1:8890 驱动 operit_agent_daemon）。",
        "en": "Wraps device automation as a subagent tool callable by the main chat AI: given a natural-language goal, AutoGLM (cloud VLM) decides and ios-mcp (system-level hand) executes, looping until done. Requires companion native bridge Tools.Net.deviceAgentStart / deviceAgentStop / deviceAgentStatus (talking to loopback TCP 127.0.0.1:8890 to drive operit_agent_daemon)."
    },
    "enabledByDefault": false,
    "category": "System",
    "tools": [
        {
            "name": "run_subagent_main",
            "description": {
                "zh": "给定自然语言目标，自动操控设备完成它（截图→AutoGLM 决策→ios-mcp 执行→回采，循环至 finish 或人工接管）。",
                "en": "Drive the device to accomplish a natural-language goal (screenshot -> AutoGLM decision -> ios-mcp execute -> re-observe, loop until finish or Take_over)."
            },
            "parameters": [
                {
                    "name": "goal",
                    "description": {
                        "zh": "要完成的自然语言任务，例如「打开设置并截一张图」。",
                        "en": "The natural-language task to accomplish, e.g. \"Open Settings and take a screenshot\"."
                    },
                    "type": "string",
                    "required": true
                }
            ]
        },
        {
            "name": "stop",
            "description": {
                "zh": "停止正在运行的设备自动化循环（发 stop 给 daemon）。",
                "en": "Stop the running device-automation loop (send stop to the daemon)."
            },
            "parameters": []
        },
        {
            "name": "status",
            "description": {
                "zh": "查询设备自动化 daemon 当前状态（running / idle 等）。",
                "en": "Query the device-automation daemon status (running / idle, etc.)."
            },
            "parameters": []
        }
    ]
}*/

type DeviceAutomationParams = {
    goal?: string;
};

// 注意：以下三个方法依赖 native 桥 Tools.Net.deviceAgentStart / deviceAgentStop /
// deviceAgentStatus。若未注册，调用会抛错，这里捕获后返回清晰提示而非静默失败。
// native 端应在 js_sdk 注册 schema 并在 js_tools_host_impl.rs 实现，内部连接
// 控制通道为 loopback TCP 127.0.0.1:8890，向 operit_agent_daemon 写
// "goal <文本>" + "start" / "stop" / "status"。

async function run_subagent_main(params: DeviceAutomationParams = {}) {
    const goal = (params.goal ?? "").trim();
    if (!goal) {
        return "缺少参数 goal：请描述要自动完成的自然语言任务。";
    }
    try {
        // @ts-ignore Tools.Net 由 native 运行时注入
        return await Tools.Net.deviceAgentStart({ goal });
    } catch (e) {
        return (
            `设备自动化暂未就绪：${String(e)}。\n` +
            `原因：native 桥 Tools.Net.deviceAgentStart 尚未注册（需在 js_sdk + ` +
            `js_tools_host_impl.rs 实现，连 agent.sock 发 goal+start）。`
        );
    }
}

async function stop() {
    try {
        // @ts-ignore
        return await Tools.Net.deviceAgentStop({});
    } catch (e) {
        return `停止指令未送达：${String(e)}。native 桥 Tools.Net.deviceAgentStop 尚未注册。`;
    }
}

async function status() {
    try {
        // @ts-ignore
        return await Tools.Net.deviceAgentStatus({});
    } catch (e) {
        return `状态查询失败：${String(e)}。native 桥 Tools.Net.deviceAgentStatus 尚未注册。`;
    }
}

exports.run_subagent_main = run_subagent_main;
exports.stop = stop;
exports.status = status;
exports.main = run_subagent_main;

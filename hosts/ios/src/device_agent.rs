// device_agent.rs — 设备控制 agent 循环（截图 → VLM → do()/finish() → 设备动作）。
//
// #98 核心增量：把 operit-ios 0.3.x 的"截图→autoglm-phone→解析 do()/finish()→执行"
// 循环移植到 operit2 的 iOS host 侧，复用 #97 的 DeviceAutomationHost 执行设备动作。
//
// 设计要点（修正路线 A 的两个问题）：
//  1. device 动作真正生效：每个动作执行后检查 HostResult，失败把"失败原因"原样回给模型重试，
//     绝不静默"成功"（修复 0.3.x 真机 launch 假成功类问题）。
//  2. 常驻：本循环由独立 daemon 进程调用（#98b），不在 Flutter App 前台 Task 内，规避 iOS 退后台挂起。
//
// LLM 调用：轻量 reqwest 直连 OpenAI 兼容端点（autoglm-phone），自己组 image_url 多模态 body。
// 不再硬接 operit-providers（其 create_request_body 不走多模态输入，且拉 wasmi/rquickjs/tree-sitter 死重）。

#![cfg(target_os = "ios")]

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::sleep;
use std::time::Duration;

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use operit_host_api::DeviceAutomationHost;
use operit_host_api::HostError;
use operit_host_api::NormalizedPoint;

const MAX_STEPS: u32 = 30;
const STEP_PAUSE_MS: u64 = 800;
const RETRY_PAUSE_MS: u64 = 2000;

// 与 operit-ios system_prompt.txt 逐字一致（autoglm-phone 按此训练）。
const SYSTEM_PROMPT: &str = r#"你是一个智能体分析专家，可以根据操作历史和当前状态图执行一系列操作来完成任务。
你必须严格按照要求输出以下格式：
<think>{think}</think>
<answer>{action}</answer>

其中：
- {think} 是对你为什么选择这个操作的简短推理说明。
- {action} 是本次执行的具体操作指令，必须严格遵循下方定义的指令格式。

操作指令及其作用如下：
- do(action="Launch", app="xxx")
    Launch是启动目标app的操作，这比通过主屏幕导航更快。此操作完成后，您将自动收到结果状态的截图。
- do(action="Tap", element=[x,y])
    Tap是点击操作，点击屏幕上的特定点。可用此操作点击按钮、选择项目、从主屏幕打开应用程序，或与任何可点击的用户界面元素进行交互。坐标系统从左上角 (0,0) 开始到右下角（999,999)结束。此操作完成后，您将自动收到结果状态的截图。
- do(action="Tap", element=[x,y], message="重要操作")
    基本功能同Tap，点击涉及财产、支付、隐私等敏感按钮时触发。
- do(action="Type", text="xxx")
    Type是输入操作，在当前聚焦的输入框中输入文本。使用此操作前，请确保输入框已被聚焦（先点击它）。输入的文本将像使用键盘输入一样输入。自动清除文本：当你使用输入操作时，输入框中现有的任何文本（包括占位符文本和实际输入）都会在输入新文本前自动清除。你无需在输入前手动清除文本——直接使用输入操作输入所需文本即可。操作完成后，你将自动收到结果状态的截图。
- do(action="Type_Name", text="xxx")
    Type_Name是输入人名的操作，基本功能同Type。
- do(action="Interact")
    Interact是当有多个满足条件的选项时而触发的交互操作，询问用户如何选择。
- do(action="Swipe", start=[x1,y1], end=[x2,y2])
    Swipe是滑动操作，通过从起始坐标拖动到结束坐标来执行滑动手势。可用于滚动内容、在屏幕之间导航、下拉通知栏以及项目栏或进行基于手势的导航。坐标系统从左上角 (0,0) 开始到右下角（999,999)结束。滑动持续时间会自动调整以实现自然的移动。此操作完成后，您将自动收到结果状态的截图。
- do(action="Note", message="True")
    记录当前页面内容以便后续总结。
- do(action="Call_API", instruction="xxx")
    总结或评论当前页面或已记录的内容。
- do(action="Long Press", element=[x,y])
    Long Pres是长按操作，在屏幕上的特定点长按指定时间。可用于触发上下文菜单、选择文本或激活长按交互。坐标系统从左上角 (0,0) 开始到右下角（999,999)结束。此操作完成后，您将自动收到结果状态的屏幕截图。
- do(action="Double Tap", element=[x,y])
    Double Tap在屏幕上的特定点快速连续点按两次。使用此操作可以激活双击交互，如缩放、选择文本或打开项目。坐标系统从左上角 (0,0) 开始到右下角（999,999)结束。此操作完成后，您将自动收到结果状态的截图。
- do(action="Take_over", message="xxx")
    Take_over是接管操作，表示在登录和验证阶段需要用户协助。
- do(action="Back")
    导航返回到上一个屏幕或关闭当前对话框。相当于按下 Android 的返回按钮。iOS 没有系统返回键，本客户端用"从左边缘向右滑动"近似实现。使用此操作可以从更深的屏幕返回、关闭弹出窗口或退出当前上下文。此操作完成后，您将自动收到结果状态的截图。
- do(action="Home")
    Home是回到系统桌面的操作，相当于按下 Android 的主屏幕按钮。使用此操作可退出当前应用并返回启动器，或从已知状态启动新任务。此操作完成后，您将自动收到结果状态的截图。
- do(action="Wait", duration="x seconds")
    等待页面加载，x为需要等待多少秒。
- finish(message="xxx")
    finish是结束任务的操作，表示准确完整完成任务，message是终止信息。

必须遵循的规则：
1. 在执行任何操作前，先检查当前app是否是目标app（每一步系统会给出[设备上下文]提示当前前台 App），如果不是，先执行 Launch。特别注意：若上下文显示当前是 Operit（本 AI 助手 App，界面是聊天框，不是微信），必须先 Launch 目标 App。
2. 如果进入到了无关页面，先执行 Back。如果执行Back后页面没有变化，请点击页面左上角的返回键进行返回，或者右上角的X号关闭。
3. 如果页面未加载出内容，最多连续 Wait 三次，否则执行 Back重新进入。
4. 如果页面显示网络问题，需要重新加载，请点击重新加载。
5. 如果当前页面找不到目标联系人、商品、店铺等信息，可以尝试 Swipe 滑动查找。
6. 遇到价格区间、时间区间等筛选条件，如果没有完全符合的，可以放宽要求。
7. 在做小红书总结类任务时一定要筛选图文笔记。
8. 购物车全选后再点击全选可以把状态设为全不选，在做购物车任务时，如果购物车里已经有商品被选中时，你需要点击全选后再点击取消全选，再去找需要购买或者删除的商品。
9. 在做外卖任务时，如果相应店铺购物车里已经有其他商品你需要先把购物车清空再去购买用户指定的外卖。
10. 在做点外卖任务时，如果用户需要点多个外卖，请尽量在同一店铺进行购买，如果无法找到可以下单，并说明某个商品未找到。
11. 请严格遵循用户意图执行任务，用户的特殊要求可以执行多次搜索，滑动查找。
12. 在选择日期时，如果原滑动方向与预期日期越来越远，请向反方向滑动查找。
13. 执行任务过程中如果有多个可选择的项目栏，请逐个查找每个项目栏，直到完成任务，一定不要在同一项目栏多次查找，从而陷入死循环。
14. 在执行下一步操作前请一定要检查上一步的操作是否生效，如果点击没生效，可能因为app反应较慢，请先稍微等待一下，如果还是不生效请调整一下点击位置重试，如果仍然不生效请跳过这一步继续任务，并在finish message说明点击不生效。
15. 在执行任务中如果遇到滑动不生效的情况，请调整一下起始点位置，增大滑动距离重试，如果还是不生效，有可能是已经滑到底了，请继续向反方向滑动，直到顶部或底部，如果仍然没有符合要求的结果，请跳过这一步继续任务，并在finish message说明但没找到要求的项目。
16. 在做游戏任务时如果在战斗页面如果有自动战斗一定要开启自动战斗，如果多轮历史状态相似要检查自动战斗是否开启。
17. 如果没有合适的搜索结果，可能是因为搜索页面不对，请返回到搜索页面的上一级尝试重新搜索，如果尝试三次返回上一级搜索后仍然没有符合要求的结果，执行 finish(message="原因")。
18. 在结束任务前请一定要仔细检查任务是否完整准确的完成，如果出现错选、漏选、多选的情况，请返回之前的步骤进行纠正。
19. 你会在每一步收到 [设备上下文] 提示，告知当前前台 App 的包名与显示名。若提示显示当前是 Operit（本 AI 助手 App，界面是聊天框，名字叫 Operit，不是微信），那不是微信、也不是任何目标 App，你必须先用 Launch 打开目标 App 再操作。微信是绿色图标、底部有四个标签（微信/通讯录/发现/我）。
20. 如果连续两步截图完全一致（系统会给出 ⚠️ 屏幕未变化 警告），说明上一步动作未生效，必须换一种方式（换坐标点击、改用点击左上角返回键、或确认 App 是否正确），禁止重复同一动作陷入死循环。"#;

// 与 operit-ios app_aliases.json 一致（模型给中文 app 名 → bundleId）。
// daemon 可在运行时覆盖 /var/jb/usr/lib/operit/app_aliases.json。
const APP_ALIASES_JSON: &str = r#"{
  "微信": "com.tencent.xin",
  "企业微信": "com.tencent.ww",
  "微信读书": "com.tencent.weread",
  "QQ": "com.tencent.mqq",
  "QQ音乐": "com.tencent.QQMusic",
  "QQ邮箱": "com.tencent.qqmail",
  "QQ浏览器": "com.tencent.mttlite",
  "TIM": "com.tencent.tim",
  "腾讯视频": "com.tencent.live4iphone",
  "腾讯新闻": "com.tencent.info",
  "腾讯文档": "com.tencent.txdocs",
  "腾讯地图": "com.tencent.sosomap",
  "支付宝": "com.alipay.iphoneclient",
  "钉钉": "com.laiwang.DingTalk",
  "闲鱼": "com.taobao.fleamarket",
  "淘宝": "com.taobao.taobao4iphone",
  "天猫": "com.taobao.tmall",
  "口碑": "com.taobao.kbmeishi",
  "饿了么": "me.ele.ios.eleme",
  "高德地图": "com.autonavi.amap",
  "UC浏览器": "com.ucweb.iphone.lowversion",
  "飞猪": "com.taobao.travel",
  "优酷": "com.youku.YouKu",
  "菜鸟裹裹": "com.cainiao.cnwireless",
  "抖音": "com.ss.iphone.ugc.Aweme",
  "抖音极速版": "com.ss.iphone.ugc.aweme.lite",
  "Tiktok": "com.zhiliaoapp.musically",
  "飞书": "com.bytedance.ee.lark",
  "今日头条": "com.ss.iphone.article.News",
  "西瓜视频": "com.ss.iphone.article.Video",
  "皮皮虾": "com.bd.iphone.super",
  "美团": "com.meituan.imeituan",
  "美团外卖": "com.meituan.itakeaway",
  "大众点评": "com.dianping.dpscope",
  "美团优选": "com.meituan.iyouxuan",
  "美团买菜": "com.baobaoaichi.imaicai",
  "京东": "com.360buy.jdmobile",
  "京东读书": "com.jd.reader",
  "网易新闻": "com.netease.news",
  "网易云音乐": "com.netease.cloudmusic",
  "网易邮箱大师": "com.netease.macmail",
  "网易严选": "com.netease.yanxuan",
  "网易有道词典": "youdaoPro",
  "百度": "com.baidu.BaiduMobile",
  "百度网盘": "com.baidu.netdisk",
  "百度贴吧": "com.baidu.tieba",
  "百度地图": "com.baidu.map",
  "百度翻译": "com.baidu.translate",
  "快手": "com.jiangjia.gif",
  "快手极速版": "com.kuaishou.nebula",
  "哔哩哔哩": "tv.danmaku.bilibilihd",
  "哔哩哔哩hd": "tv.danmaku.bilibilihd",
  "bilibili": "tv.danmaku.bilibilihd",
  "bilibilihd": "tv.danmaku.bilibilihd",
  "b站": "tv.danmaku.bilibilihd",
  "芒果TV": "com.hunantv.imgotv",
  "微博": "com.sina.weibo",
  "豆瓣": "com.douban.frodo",
  "知乎": "com.zhihu.ios",
  "小红书": "com.xingin.discover",
  "喜马拉雅": "com.gemd.iting",
  "得到": "com.luojilab.LuoJiFM-IOS",
  "得物": "com.siwuai.duapp",
  "起点读书": "m.qidian.QDReaderAppStore",
  "番茄小说": "com.dragon.read",
  "书旗小说": "com.shuqicenter.reader",
  "拼多多": "com.xunmeng.pinduoduo",
  "爱奇艺视频": "com.qiyi.iphone",
  "搜狐视频": "com.sohu.iPhoneVideo",
  "虎牙": "com.yy.kiwi",
  "什么值得买": "com.smzdm.client.ios",
  "唯品会": "com.vipshop.iphone",
  "携程": "ctrip.com",
  "去哪儿旅行": "com.qunar.iphoneclient8",
  "云闪付": "com.unionpay.chsp",
  "58同城": "com.taofang.iphone",
  "设置": "com.apple.Preferences",
  "系统设置": "com.apple.Preferences",
  "系统设置应用": "com.apple.Preferences",
  "设置应用": "com.apple.Preferences",
  "settings": "com.apple.Preferences",
  "浏览器": "com.apple.mobilesafari",
  "safari": "com.apple.mobilesafari",
  "相机": "com.apple.camera",
  "照片": "com.apple.mobileslideshow",
  "备忘录": "com.apple.mobilenotes",
  "提醒事项": "com.apple.reminders",
  "信息": "com.apple.MobileSMS",
  "电话": "com.apple.mobilephone",
  "计算器": "com.apple.calculator",
  "地图": "com.apple.Maps",
  "天气": "com.apple.weather",
  "音乐": "com.apple.Music",
  "b站": "com.bilibili.app.in",
  "bilibili": "com.bilibili.app.in",
  "邮件": "com.apple.mobilemail",
  "日历": "com.apple.mobilecal",
  "文件": "com.apple.DocumentsApp"
}"#;

// ───────────────────────────── 动作模型 ─────────────────────────────

#[derive(Debug, Clone)]
enum AgentAction {
    Launch { app: String },
    Tap { x: f64, y: f64 },
    DoubleTap { x: f64, y: f64 },
    LongPress { x: f64, y: f64 },
    Swipe { x1: f64, y1: f64, x2: f64, y2: f64 },
    Type { text: String },
    TypeName { text: String },
    Home,
    Back,
    Wait { seconds: f64 },
    Interact,
    Note,
    CallApi,
    TakeOver { message: String },
    Unknown { name: String },
}

impl AgentAction {
    fn describe(&self) -> String {
        match self {
            AgentAction::Launch { app } => format!("Launch {}", app),
            AgentAction::Tap { x, y } => format!("Tap ({:.0},{:.0})", x * 1000.0, y * 1000.0),
            AgentAction::DoubleTap { x, y } => format!("DoubleTap ({:.0},{:.0})", x * 1000.0, y * 1000.0),
            AgentAction::LongPress { x, y } => format!("LongPress ({:.0},{:.0})", x * 1000.0, y * 1000.0),
            AgentAction::Swipe { x1, y1, x2, y2 } => {
                format!("Swipe ({:.0},{:.0})->({:.0},{:.0})", x1 * 1000.0, y1 * 1000.0, x2 * 1000.0, y2 * 1000.0)
            }
            AgentAction::Type { text } => format!("Type \"{}\"", text),
            AgentAction::TypeName { text } => format!("Type_Name \"{}\"", text),
            AgentAction::Home => "Home".into(),
            AgentAction::Back => "Back".into(),
            AgentAction::Wait { seconds } => format!("Wait {}s", seconds),
            AgentAction::Interact => "Interact".into(),
            AgentAction::Note => "Note".into(),
            AgentAction::CallApi => "Call_API".into(),
            AgentAction::TakeOver { message } => format!("Take_over \"{}\"", message),
            AgentAction::Unknown { name } => format!("Unknown({})", name),
        }
    }
}

enum AgentCommand {
    Finish(String),
    Action(AgentAction),
}

// ───────────────────────────── 解析器（移植自 operit_parse.m） ─────────────────────────────

fn extract_between(text: &str, open: &str, close: &str) -> String {
    let o = format!("<{}>", open);
    let c = format!("</{}>", close);
    if let (Some(s), Some(e)) = (text.find(&o), text.find(&c)) {
        if s + o.len() <= e {
            return text[s + o.len()..e].trim().to_string();
        }
    }
    String::new()
}

fn extract_answer(text: &str) -> String {
    let a = extract_between(text, "answer", "answer");
    if !a.is_empty() {
        a
    } else {
        text.to_string()
    }
}

/// 找到首个 '(' 并匹配到对应 ')'（尊重引号），返回内部内容。
fn inner_of_parens(s: &str) -> Option<String> {
    let start = s.find('(')?;
    let mut depth = 0i32;
    let mut in_quote = false;
    let mut end = None;
    for (i, c) in s.char_indices() {
        if c == '"' {
            in_quote = !in_quote;
            continue;
        }
        if in_quote {
            continue;
        }
        if c == '(' {
            depth += 1;
        } else if c == ')' {
            depth -= 1;
            if depth == 0 && i > start {
                end = Some(i);
                break;
            }
        }
    }
    end.map(|e| s[start + 1..e].to_string())
}

/// 按顶层逗号切分（尊重引号与方括号）。
fn split_top_level(s: &str) -> Vec<String> {
    let mut parts = Vec::new();
    let mut cur = String::new();
    let mut depth = 0i32;
    let mut in_quote = false;
    for (_, c) in s.char_indices() {
        if c == '"' {
            in_quote = !in_quote;
            cur.push(c);
            continue;
        }
        if in_quote {
            cur.push(c);
            continue;
        }
        if c == '[' {
            depth += 1;
            cur.push(c);
            continue;
        }
        if c == ']' {
            depth -= 1;
            cur.push(c);
            continue;
        }
        if c == ',' && depth == 0 {
            parts.push(cur.trim().to_string());
            cur = String::new();
            continue;
        }
        cur.push(c);
    }
    if !cur.trim().is_empty() {
        parts.push(cur.trim().to_string());
    }
    parts
}

fn extract_kwargs(s: &str) -> HashMap<String, String> {
    let mut kw = HashMap::new();
    if let Some(inner) = inner_of_parens(s) {
        for chunk in split_top_level(&inner) {
            if let Some(eq) = chunk.find('=') {
                let k = chunk[..eq].trim().to_string();
                let v = chunk[eq + 1..].trim().to_string();
                if !k.is_empty() {
                    kw.insert(k, v);
                }
            }
        }
    }
    kw
}

fn parse_text(v: &str) -> String {
    let s = v.trim();
    if s.len() >= 2 && s.starts_with('"') && s.ends_with('"') {
        return s[1..s.len() - 1].replace("\\\"", "\"");
    }
    s.to_string()
}

fn parse_list2(v: &str) -> Option<(f64, f64)> {
    let s = v.trim();
    if !s.starts_with('[') || !s.ends_with(']') {
        return None;
    }
    let inner = &s[1..s.len() - 1];
    let parts: Vec<&str> = inner.split(',').collect();
    if parts.len() != 2 {
        return None;
    }
    let a = parts[0].trim().parse::<f64>().ok()?;
    let b = parts[1].trim().parse::<f64>().ok()?;
    Some((a, b))
}

fn parse_duration(v: &str) -> f64 {
    let t = v.replace("seconds", "").replace('秒', "");
    let d = t.trim().parse::<f64>().unwrap_or(0.0);
    if d > 0.0 {
        d
    } else {
        1.0
    }
}

fn map_action(action: &str, kw: &HashMap<String, String>) -> AgentAction {
    match action {
        "Launch" => AgentAction::Launch {
            app: kw.get("app").map(|v| parse_text(v)).unwrap_or_default(),
        },
        "Tap" => {
            let (x, y) = kw.get("element").and_then(|v| parse_list2(v)).unwrap_or((0.0, 0.0));
            AgentAction::Tap { x: x / 1000.0, y: y / 1000.0 }
        }
        "Double Tap" => {
            let (x, y) = kw.get("element").and_then(|v| parse_list2(v)).unwrap_or((0.0, 0.0));
            AgentAction::DoubleTap { x: x / 1000.0, y: y / 1000.0 }
        }
        "Long Press" => {
            let (x, y) = kw.get("element").and_then(|v| parse_list2(v)).unwrap_or((0.0, 0.0));
            AgentAction::LongPress { x: x / 1000.0, y: y / 1000.0 }
        }
        "Swipe" => {
            let (x1, y1) = kw.get("start").and_then(|v| parse_list2(v)).unwrap_or((0.0, 0.0));
            let (x2, y2) = kw.get("end").and_then(|v| parse_list2(v)).unwrap_or((0.0, 0.0));
            AgentAction::Swipe {
                x1: x1 / 1000.0,
                y1: y1 / 1000.0,
                x2: x2 / 1000.0,
                y2: y2 / 1000.0,
            }
        }
        "Type" => AgentAction::Type {
            text: kw.get("text").map(|v| parse_text(v)).unwrap_or_default(),
        },
        "Type_Name" => AgentAction::TypeName {
            text: kw.get("text").map(|v| parse_text(v)).unwrap_or_default(),
        },
        "Home" => AgentAction::Home,
        "Back" => AgentAction::Back,
        "Wait" => AgentAction::Wait {
            seconds: kw.get("duration").map(|v| parse_duration(v)).unwrap_or(1.0),
        },
        "Interact" => AgentAction::Interact,
        "Note" => AgentAction::Note,
        "Call_API" => AgentAction::CallApi,
        "Take_over" => AgentAction::TakeOver {
            message: kw.get("message").map(|v| parse_text(v)).unwrap_or_default(),
        },
        other => AgentAction::Unknown {
            name: other.to_string(),
        },
    }
}

/// 在全文中定位一个动作调用（do( / finish(），前导字符不能是 ASCII 字母，
/// 避免 "redo(" 之类文字被误判为动作。返回该调用的起始字节下标。
fn find_call(hay: &str, needle: &str) -> Option<usize> {
    let starts: Vec<usize> = hay.char_indices().map(|(i, _)| i).collect();
    let nb = needle.as_bytes();
    for (k, &start) in starts.iter().enumerate() {
        if !hay[start..].as_bytes().starts_with(nb) {
            continue;
        }
        let prev_ok = k == 0
            || {
                let prev = hay[starts[k - 1]..].chars().next().unwrap();
                !prev.is_ascii_alphabetic()
            };
        if prev_ok {
            return Some(start);
        }
    }
    None
}

/// 解析一段"应以 do(...)/finish(...) 开头"的文本为指令。
fn parse_action_from(s: &str) -> Option<AgentCommand> {
    let s = s.trim();
    if s.starts_with("finish") {
        let kw = extract_kwargs(s);
        let msg = kw.get("message").map(|v| parse_text(v)).unwrap_or_default();
        return Some(AgentCommand::Finish(msg));
    }
    if !s.starts_with("do") {
        return None;
    }
    let kw = extract_kwargs(s);
    let raw = kw.get("action")?;
    let action = parse_text(raw);
    if action.is_empty() {
        return None;
    }
    Some(AgentCommand::Action(map_action(&action, &kw)))
}

fn parse_action(text: &str) -> Option<AgentCommand> {
    // 1) 优先取 <answer>...</answer> 内容（模型按训练格式输出时）。
    let ans = extract_answer(text);
    if let Some(cmd) = parse_action_from(&ans) {
        return Some(cmd);
    }
    // 2) 没标签 / 标签内容解析失败时：在全文中定位第一个 do( / finish( 调用。
    //    模型常把动作放在一大段推理之后、且不包 <answer> 标签，必须从全文扫描。
    let idx = find_call(text, "do(").or_else(|| find_call(text, "finish("));
    if let Some(i) = idx {
        if let Some(cmd) = parse_action_from(&text[i..]) {
            return Some(cmd);
        }
    }
    None
}

// ───────────────────────────── LLM 调用（轻量 reqwest） ─────────────────────────────

pub struct DeviceAgentConfig {
    pub api_key: String,
    pub api_base: String,
    pub model: String,
}

fn call_vlm(
    client: &reqwest::blocking::Client,
    cfg: &DeviceAgentConfig,
    messages: &[serde_json::Value],
) -> Result<String, String> {
    let body = serde_json::json!({
        "model": cfg.model,
        "messages": messages,
        "max_tokens": 1500,
        "stream": false,
    });
    let resp = client
        .post(&cfg.api_base)
        .bearer_auth(&cfg.api_key)
        .json(&body)
        .send()
        .map_err(|e| format!("HTTP 请求失败: {}", e))?;
    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().unwrap_or_default();
        return Err(format!("HTTP {}: {}", status, text));
    }
    let v: serde_json::Value = resp.json().map_err(|e| format!("JSON 解析失败: {}", e))?;
    let content = v["choices"][0]["message"]["content"]
        .as_str()
        .unwrap_or("")
        .to_string();
    Ok(content)
}

// ───────────────────────────── 动作执行（含真实回包校验） ─────────────────────────────

fn resolve_bundle(app: &str, aliases: &HashMap<String, String>) -> String {
    let app_t = app.trim();
    // 已是 bundle id（含 '.'），原样发出，避免被别名表误改
    if app_t.contains('.') {
        return app_t.to_string();
    }
    // 1) 精确匹配（含大小写不敏感）
    let lower = app_t.to_lowercase();
    if let Some(b) = aliases.get(app_t).or_else(|| aliases.get(&lower)) {
        return b.clone();
    }
    // 2) 子串兜底：任一别名 key 被 app 包含（或包含 app），取最长匹配的 key。
    //    要求 key 长度 >= 2，避免单字误命中。
    //    例："系统设置" 含 "设置" -> com.apple.Preferences；
    //        "网易云音乐" 已被上面的精确匹配优先命中，不会落到这里。
    let mut best: Option<(&String, &String)> = None;
    for (key, bid) in aliases.iter() {
        if key.chars().count() < 2 {
            continue;
        }
        let k = key.to_lowercase();
        if lower.contains(&k) || k.contains(&lower) {
            match best {
                Some((bk, _)) if bk.chars().count() >= key.chars().count() => {}
                _ => best = Some((key, bid)),
            }
        }
    }
    if let Some((_, bid)) = best {
        return bid.clone();
    }
    app_t.to_string()
}

fn exec_action(
    host: &dyn DeviceAutomationHost,
    act: &AgentAction,
    aliases: &HashMap<String, String>,
) -> Result<(), String> {
    match act {
        AgentAction::Launch { app } => {
            let bid = resolve_bundle(app, aliases);
            host.launchApp(&bid).map_err(|e: HostError| e.message)
        }
        AgentAction::Tap { x, y } => {
            host.tap(NormalizedPoint { x: *x, y: *y }).map_err(|e| e.message)
        }
        AgentAction::DoubleTap { x, y } => {
            host.tap(NormalizedPoint { x: *x, y: *y }).map_err(|e| e.message)?;
            // 第二次点按前稍等，避免被识别为长按/拖动
            sleep(Duration::from_millis(120));
            host.tap(NormalizedPoint { x: *x, y: *y }).map_err(|e| e.message)
        }
        AgentAction::LongPress { x, y } => host
            .longPress(NormalizedPoint { x: *x, y: *y }, 800)
            .map_err(|e| e.message),
        AgentAction::Swipe { x1, y1, x2, y2 } => host
            .swipe(
                NormalizedPoint { x: *x1, y: *y1 },
                NormalizedPoint { x: *x2, y: *y2 },
                300,
            )
            .map_err(|e| e.message),
        AgentAction::Type { text } => host.typeText(text).map_err(|e| e.message),
        AgentAction::TypeName { text } => host.typeText(text).map_err(|e| e.message),
        AgentAction::Home => host.pressHome().map_err(|e| e.message),
        AgentAction::Back => host.pressBack().map_err(|e| e.message),
        AgentAction::Wait { seconds } => {
            sleep(Duration::from_millis((seconds * 1000.0) as u64));
            Ok(())
        }
        // 以下无副作用动作：记到历史由模型自行决定，循环继续
        AgentAction::Interact => Err("需要人工交互，暂停循环".into()),
        AgentAction::Note | AgentAction::CallApi => Ok(()),
        AgentAction::TakeOver { .. } => Err("需要用户接管（登录/验证），暂停循环".into()),
        AgentAction::Unknown { name } => Err(format!("未知动作: {}", name)),
    }
}

/// 把 `frontmost_app()` 返回的 "bundleId|name" 转成给模型看的[设备上下文]。
/// 若当前就是 Operit 自身（AI 助手 App），明确警告"这不是微信"，必须先 Launch 目标 App。
fn device_context(front: &str) -> String {
    let (bid, name) = match front.split_once('|') {
        Some((b, n)) => (b.trim().to_string(), n.trim().to_string()),
        None => (front.trim().to_string(), front.trim().to_string()),
    };
    let is_self = bid.to_lowercase().contains("operit") || name == "Operit" || name == "OperitApp";
    if is_self {
        format!(
            "当前前台应用：{}（{}）。⚠️ 这是 Operit 自身（本 AI 助手 App，界面是聊天框，不是微信）。你必须先用 Launch 打开目标 App，再操作。",
            name, bid
        )
    } else {
        format!("当前前台应用：{}（{}）。", name, bid)
    }
}

// ───────────────────────────── 主循环 ─────────────────────────────

/// 运行一次设备控制 agent 循环，直到 finish / 出错 / 被 stop。
///
/// `host` 是 #97 实现的 iOS 设备自动化 host（接越狱 tweak socket）。
/// `cfg` 对应智谱 autoglm-phone（OpenAI 兼容端点）。
/// `stop` 由外部（daemon 控制 socket）置位以取消任务。
/// `log` 接收逐步日志（daemon 写入 agent.log）。
/// `on_screenshot` 每步拿到 PNG 字节（daemon 持久化 screen.png 供 App 轮询）。
pub fn run_device_agent_loop(
    goal: &str,
    host: Arc<dyn DeviceAutomationHost>,
    cfg: &DeviceAgentConfig,
    stop: Arc<AtomicBool>,
    log: &dyn Fn(&str),
    on_screenshot: &dyn Fn(&[u8]),
) -> String {
    let aliases: HashMap<String, String> = serde_json::from_str(APP_ALIASES_JSON)
        .unwrap_or_default();
    let client = reqwest::blocking::Client::new();

    // 纯文本历史（不含截图），与 operit-ios daemon 行为一致。
    let mut history: Vec<serde_json::Value> =
        vec![serde_json::json!({ "role": "system", "content": SYSTEM_PROMPT })];

    let mut steps: u32 = 0;
    let mut last_desc = String::new();
    let mut prev_shot: Option<Vec<u8>> = None;

    loop {
        if stop.load(Ordering::Relaxed) {
            let m = "已收到停止信号，循环结束";
            log(m);
            return m.to_string();
        }
        if steps >= MAX_STEPS {
            let m = format!("达到最大步数 {}，循环结束", MAX_STEPS);
            log(&m);
            return m;
        }
        steps += 1;

        // 1) 截图
        let shot = match host.captureScreenshot() {
            Ok(s) => s,
            Err(e) => {
                let m = format!("截图失败: {}", e.message);
                log(&m);
                history.push(serde_json::json!({
                    "role": "user",
                    "content": "截图失败，请基于已有信息重试或等待。"
                }));
                sleep(Duration::from_millis(STEP_PAUSE_MS));
                continue;
            }
        };
        on_screenshot(&shot.imagePng);

        // 1.5) 设备上下文：前台 App + 屏幕是否变化（A/B 路：根治"把 Operit 当微信"与死循环）
        let mut ctx = String::new();
        match host.frontmost_app() {
            Ok(front) => {
                ctx = device_context(&front);
                log(&format!("[设备上下文] {}", ctx));
            }
            Err(e) => log(&format!("frontmost_app 查询失败: {}", e.message)),
        }
        // 与上一步截图逐字节比较：完全相同说明上一步动作没让屏幕产生任何变化。
        let screen_unchanged = if let Some(prev) = &prev_shot {
            *prev == shot.imagePng
        } else {
            false
        };
        prev_shot = Some(shot.imagePng.clone());

        // 2) 组装本步请求：设备上下文 + 文本历史 + 当前截图
        let ctx_block = if ctx.is_empty() {
            String::new()
        } else {
            format!("[设备上下文] {}\n", ctx)
        };
        let unchanged_warn = if screen_unchanged {
            "\n⚠️ 上一步执行后屏幕没有任何变化（与上一帧截图完全一致）。请不要重复同一动作，改换方式：例如点击屏幕左上角的返回按钮，或确认是否仍在错误的 App 中。"
        } else {
            ""
        };
        let note = if steps == 1 {
            format!("{}任务目标：{}\n{}", ctx_block, goal, unchanged_warn)
        } else {
            format!(
                "{}上一步执行：{}\n请继续执行任务。{}",
                ctx_block, last_desc, unchanged_warn
            )
        };
        let mut req_messages = history.clone();
        req_messages.push(serde_json::json!({
            "role": "user",
            "content": [
                { "type": "text", "text": note },
                { "type": "image_url", "image_url": { "url": format!("data:image/png;base64,{}", STANDARD.encode(&shot.imagePng)) } }
            ]
        }));

        // 3) 调 VLM
        let resp = match call_vlm(&client, cfg, &req_messages) {
            Ok(r) => r,
            Err(e) => {
                log(&format!("VLM 调用失败: {}（重试）", e));
                sleep(Duration::from_millis(RETRY_PAUSE_MS));
                continue;
            }
        };
        // 诊断：打印模型实际返回原文（含 model 名，不含 api_key），便于上机定位
        // "未含有效 do()/finish()" 这类问题到底是格式不符、模型名错还是端点错。
        log(&format!("[model={}] VLM 原始返回: {}", cfg.model, resp));

        // 4) 解析指令
        match parse_action(&resp) {
            Some(AgentCommand::Finish(msg)) => {
                let m = format!("FINISH: {}", msg);
                log(&m);
                return msg;
            }
            Some(AgentCommand::Action(act)) => {
                let desc = act.describe();
                let result = exec_action(host.as_ref(), &act, &aliases);
                let result_note = match &result {
                    Ok(_) => "成功".to_string(),
                    Err(err) => format!("失败: {}", err),
                };
                last_desc = format!("{} -> {}", desc, result_note);
                log(&last_desc);

                // 把本轮模型输出与执行结果写回文本历史（截图不持久化）。
                history.push(serde_json::json!({ "role": "assistant", "content": resp }));
                history.push(serde_json::json!({
                    "role": "user",
                    "content": format!("执行结果：{}", result_note)
                }));

                // 关键修正：失败不静默——把失败原因留在 last_desc，下一步随截图回给模型重试。
                if let Err(err) = result {
                    if err.contains("接管") || err.contains("人工交互") {
                        let m = format!("暂停：{}", err);
                        log(&m);
                        return m;
                    }
                    // 其他失败继续循环，让模型看到未变化的截图自行调整。
                }
            }
            None => {
                log("模型输出未含有效 do()/finish()，提示后重试");
                history.push(serde_json::json!({
                    "role": "user",
                    "content": "你的输出格式不正确，请严格用 <answer>do(action=..., ...)</answer> 或 finish(message=...)。"
                }));
                sleep(Duration::from_millis(500));
                continue;
            }
        }

        sleep(Duration::from_millis(STEP_PAUSE_MS));
    }
}

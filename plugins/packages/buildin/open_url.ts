/* METADATA
{
    "name": "open_url",
    "display_name": {
        "zh": "打开 App / 深链",
        "en": "Open App / Deep Link"
    },
    "description": {
        "zh": "唤起任意第三方 App 的指定页面（搜索/扫码/付款码/用户主页/视频详情等），iOS 全版本可用（非越狱/越狱均可）。用苹果系统 UIApplication.openURL，无需 SDK/权限。https 链接自动走 Universal Link 唤起 App（免白名单、官方维护最稳）；第三方 scheme（weixin:// 等）需 App 已安装。常用：微信 weixin://、B站 bilibili://search?keyword=、抖音 snssdk1128://、淘宝 taobao://s.taobao.com?q=、支付宝 alipay://platformapi/startapp?appId=10000007（扫一扫）。需配套 native 桥 Tools.Net.openUrl（连 127.0.0.1:8894 驱动 App 内 Swift OpenURLServer）。",
        "en": "Open any third-party app to a specific page (search/scan/payment-code/user-profile/video-detail etc.) via Apple's UIApplication.openURL — works on all iOS (jailed or jailbroken), no SDK or permission needed. https links auto-trigger Universal Links (whitelist-free, official, most stable); third-party schemes (weixin:// etc.) require the app installed. Examples: WeChat weixin://, Bilibili bilibili://search?keyword=, Douyin snssdk1128://, Taobao taobao://s.taobao.com?q=, Alipay alipay://platformapi/startapp?appId=10000007 (scan). Requires companion native bridge Tools.Net.openUrl (talking to 127.0.0.1:8894 to drive the in-app Swift OpenURLServer)."
    },
    "enabledByDefault": true,
    "category": "System",
    "tools": [
        {
            "name": "open_url",
            "description": {
                "zh": "打开指定 URL/scheme。优先用 https 官方链接（Universal Link 自动唤起 App）；第三方 scheme 也可（需已安装）。失败会返回原因（未安装/白名单/失效），可换 https 链接或网页版兜底。",
                "en": "Open a URL/scheme. Prefer official https links (Universal Links auto-open the app); third-party schemes also work if installed. On failure you get the reason (not installed / not whitelisted / stale) — fall back to an https link or the web version."
            },
            "parameters": [
                {
                    "name": "url",
                    "description": {
                        "zh": "要打开的链接。https 官方链接优先（自动唤起 App，未装则开网页）；或第三方 scheme，如 weixin://、bilibili://search?keyword=xxx、taobao://s.taobao.com?q=xxx。",
                        "en": "The URL to open. Prefer official https links (auto-open the app, fall back to web); or a scheme like weixin://, bilibili://search?keyword=xxx, taobao://s.taobao.com?q=xxx."
                    },
                    "type": "string",
                    "required": true
                }
            ]
        }
    ]
}*/

type OpenUrlParams = {
    url?: string;
};

// 常用 scheme 手册：AI 可直接套用。https 官方链接永远优先（Universal Link）。
const SCHEME_HANDBOOK = [
    // 社交
    "weixin:// 微信（dl/chat 聊天、dl/moments 朋友圈、scanqrcode 扫一扫）",
    "mqqapi:// QQ（qrcode/scan_qrcode 扫码；card/show_pslcard?src_type=internal&version=1&uin=QQ号 加好友）",
    "sinaweibo:// 微博（searchall?q= 搜索；share?content= 发微博；qrcode 扫码）",
    "xhsdiscover:// 小红书（search/recommend 搜索页）",
    "zhihu:// 知乎（search?q= 搜索；codereader 扫码）",
    // 视频
    "bilibili:// B站（search?keyword= 搜索；video/AV号 视频；qrcode 扫码；user_center 个人中心）",
    "snssdk1128:// 抖音（feed 首页；search?keyword= 搜索；user/profile/uid 主页；aweme/detail/itemId 作品；aweme/live/roomId 直播）",
    "kwai:// 快手（home 首页；search?keyword= 搜索；qrscan 扫码；profile/uid 主页）",
    "tenvideo:// 腾讯视频、iqiyi:// 爱奇艺、youku:// 优酷",
    "youtube:// YouTube（results?search_query= 搜索）",
    // 电商
    "taobao:// 淘宝（s.taobao.com?q= 搜索；tb.cn/n/scancode 扫码；shopsearch.taobao.com/search?app=shopsearch&q= 找店）",
    "openjd:// 京东（virtual?params={\"des\":\"productList\",\"keyWord\":\"词\",\"from\":\"search\",\"category\":\"jump\"} 搜索）",
    "pinduoduo:// 拼多多（com.xunmeng.pinduoduo/search_result.html?search_key= 搜索）",
    // 支付
    "alipay:// 支付宝（platformapi/startapp?appId=10000007 扫一扫；20000056 付款码；200011235 乘车码）",
    "upwallet:// 云闪付（native/scanCode 扫码；pay 付款码；rn/rnhtmlridingcode 乘车码）",
    // 出行
    "iosamap:// 高德（navi?sourceApplication=x&poiname=目的地&lat=纬度&lon=经度 导航）",
    "baidumap:// 百度地图（map/direction?origin=起点&destination=终点&mode=driving 导航）",
    "qqmap:// 腾讯地图（map/routeplan?from=起点&type=drive&tocoord=lat,lon&to=终点 导航）",
    "diditaxi:// 滴滴、cn.12306:// 12306、CtripWireless:// 携程、hellobike:// 哈啰（hellobike.com/scan_qr 扫码）",
    // 音乐
    "qqmusic:// QQ音乐（qq.com/ui/recognize 识曲）",
    "orpheus:// 网易云（recognize 识曲；playlist/歌单ID 歌单；song/歌曲ID 歌曲）",
    // 系统
    "tel:// 拨号、sms:// 短信、mailto: 邮件、itms-apps:// App Store（search.itunes.apple.com/WebObjects/MZSearch.woa/wa/search?media=software&term=词 搜软件）",
    "App-Prefs:root=WIFI 系统设置（root=BLUETOOTH 蓝牙、MOBILE_DATA 蜂窝、SCREEN_TIME 屏幕使用时间、PRIVACY 隐私、GENERAL&path=ABOUT 关于）",
].join("\n");

async function open_url(params: OpenUrlParams = {}) {
    const url = (params.url ?? "").trim();
    if (!url) {
        return `缺少参数 url。可参考 scheme 手册：\n${SCHEME_HANDBOOK}`;
    }
    // https 官方链接优先（Universal Link 免白名单自动唤起 App）
    try {
        // @ts-ignore Tools.Net 由 native 运行时注入
        return await Tools.Net.openUrl({ url });
    } catch (e) {
        return `打开失败：${String(e)}。native 桥 Tools.Net.openUrl 尚未注册。可参考 scheme 手册：\n${SCHEME_HANDBOOK}`;
    }
}

exports.open_url = open_url;
exports.main = open_url;

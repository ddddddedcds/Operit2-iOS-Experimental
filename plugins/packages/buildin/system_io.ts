/* METADATA
{
    "name": "system_io",
    "display_name": {
        "zh": "系统数据读写（权限全家桶）",
        "en": "System Data I/O"
    },
    "description": {
        "zh": "读写 iOS 系统数据：通讯录（找联系人/电话）、日历（查/建日程）、提醒事项（查/建待办）、照片（最近照片/保存图片）、健康（步数/心率）、定位（当前坐标）。全部走系统公开 API，首次调用会弹系统授权框，用户允许后可用。读写均为真实数据，注意隐私：只在用户明确要求时读取。",
        "en": "Read/write iOS system data: contacts (find people/phones), calendar (list/create events), reminders (list/create todos), photos (recent photos/save image), health (steps/heart rate), location (current coordinates). All via public APIs; the first call shows a system permission dialog. Real data — only read when the user explicitly asks."
    },
    "enabledByDefault": true,
    "category": "System",
    "tools": [
        {
            "name": "contacts_read",
            "description": {
                "zh": "读取通讯录。不传 query 返回全部（默认前 50 条）；传 query 按名字/电话/公司搜索（最多 50 条）。返回 name/phones/emails。",
                "en": "Read contacts. Without query returns all (default first 50); with query searches by name/phone/company (max 50). Returns name/phones/emails."
            },
            "parameters": [
                { "name": "query", "description": { "zh": "搜索关键词（名字/电话/公司），可空", "en": "Search keyword (name/phone/company), optional" }, "type": "string" },
                { "name": "limit", "description": { "zh": "最多返回条数（默认 50，最大 200）", "en": "Max entries (default 50, max 200)" }, "type": "number" }
            ]
        },
        {
            "name": "calendar_list",
            "description": {
                "zh": "列出未来 N 天（默认 7）的日历事件，返回 title/calendar/start/end/location（ISO8601 时间）。",
                "en": "List calendar events for the next N days (default 7). Returns title/calendar/start/end/location (ISO8601)."
            },
            "parameters": [
                { "name": "days", "description": { "zh": "未来天数（默认 7）", "en": "Days ahead (default 7)" }, "type": "number" }
            ]
        },
        {
            "name": "calendar_create",
            "description": {
                "zh": "新建日历事件。start/end 为 ISO8601 时间（如 2026-08-11T14:00:00Z）。",
                "en": "Create a calendar event. start/end are ISO8601 (e.g. 2026-08-11T14:00:00Z)."
            },
            "parameters": [
                { "name": "title", "description": { "zh": "事件标题", "en": "Event title" }, "type": "string", "required": true },
                { "name": "start", "description": { "zh": "开始时间 ISO8601", "en": "Start ISO8601" }, "type": "string", "required": true },
                { "name": "end", "description": { "zh": "结束时间 ISO8601", "en": "End ISO8601" }, "type": "string", "required": true }
            ]
        },
        {
            "name": "reminders_list",
            "description": {
                "zh": "列出未完成的提醒事项（最多 100 条），返回 title/due/priority/completed。",
                "en": "List incomplete reminders (max 100). Returns title/due/priority/completed."
            },
            "parameters": []
        },
        {
            "name": "reminders_create",
            "description": {
                "zh": "新建提醒事项。due 可选（ISO8601），不传则不设截止时间。",
                "en": "Create a reminder. due optional (ISO8601); omit for no due date."
            },
            "parameters": [
                { "name": "title", "description": { "zh": "提醒内容", "en": "Reminder text" }, "type": "string", "required": true },
                { "name": "due", "description": { "zh": "截止时间 ISO8601（可选）", "en": "Due ISO8601 (optional)" }, "type": "string" }
            ]
        },
        {
            "name": "photos_recent",
            "description": {
                "zh": "列出最近 N 张（默认 10）照片的元数据：文件名/时间/尺寸/位置。不含图像内容。",
                "en": "List metadata of the N most recent photos (default 10): filename/date/size/location. No image content."
            },
            "parameters": [
                { "name": "n", "description": { "zh": "张数（默认 10，最大 50）", "en": "Count (default 10, max 50)" }, "type": "number" }
            ]
        },
        {
            "name": "photos_save",
            "description": {
                "zh": "保存一张图片到相册。base64 为 PNG/JPEG 的 base64 编码。",
                "en": "Save an image to the photo library. base64 is the PNG/JPEG data in base64."
            },
            "parameters": [
                { "name": "base64", "description": { "zh": "图片 base64（PNG/JPEG）", "en": "Image base64 (PNG/JPEG)" }, "type": "string", "required": true }
            ]
        },
        {
            "name": "health_read",
            "description": {
                "zh": "读取健康数据。metric=steps：最近 days（默认 7）天每日步数；metric=hrt：最近 n（默认 10）条心率。需健康 App 有数据且用户授权。",
                "en": "Read health data. metric=steps: daily steps for last days (default 7); metric=hrt: latest n (default 10) heart-rate samples. Requires Health data + user permission."
            },
            "parameters": [
                { "name": "metric", "description": { "zh": "steps 或 hrt", "en": "steps or hrt" }, "type": "string", "required": true },
                { "name": "days", "description": { "zh": "steps 用：天数（默认 7）", "en": "For steps: days (default 7)" }, "type": "number" },
                { "name": "n", "description": { "zh": "hrt 用：样本数（默认 10）", "en": "For hrt: samples (default 10)" }, "type": "number" }
            ]
        },
        {
            "name": "location_get",
            "description": {
                "zh": "获取当前定位（经纬度 + 时间）。未授权会提示去系统设置开启。",
                "en": "Get current location (lat/lon + timestamp). Prompts to enable permission if denied."
            },
            "parameters": []
        }
    ]
}*/

type TccParams = {
  url: string;
};

async function tcc(url: string): Promise<string> {
  try {
    // @ts-ignore Tools.Net 由 native 运行时注入
    return await Tools.Net.openUrl({ url });
  } catch (e) {
    return `系统数据读写失败：${String(e)}。native 桥 Tools.Net.openUrl 尚未注册。`;
  }
}

async function contacts_read(params: { query?: string; limit?: number } = {}) {
  const limit = Math.min(Math.max(params.limit ?? 50, 1), 200);
  if (params.query && params.query.trim()) {
    return tcc(`tcc contacts search ${params.query.trim().replace(/\s+/g, " ")}`);
  }
  return tcc(`tcc contacts list ${limit}`);
}

async function calendar_list(params: { days?: number } = {}) {
  const days = Math.min(Math.max(params.days ?? 7, 1), 90);
  return tcc(`tcc calendar list ${days}`);
}

async function calendar_create(params: { title: string; start: string; end: string }) {
  if (!params.title || !params.start || !params.end) return "缺少参数：title/start/end 必填。";
  // 分隔符 | 在行协议里会冲突，替换掉
  const title = params.title.replace(/\|/g, " ");
  return tcc(`tcc calendar create ${title}|${params.start}|${params.end}`);
}

async function reminders_list() {
  return tcc("tcc reminders list");
}

async function reminders_create(params: { title: string; due?: string }) {
  if (!params.title) return "缺少参数：title 必填。";
  const title = params.title.replace(/\|/g, " ");
  return tcc(params.due ? `tcc reminders create ${title}|${params.due}` : `tcc reminders create ${title}`);
}

async function photos_recent(params: { n?: number } = {}) {
  const n = Math.min(Math.max(params.n ?? 10, 1), 50);
  return tcc(`tcc photos recent ${n}`);
}

async function photos_save(params: { base64: string }) {
  if (!params.base64) return "缺少参数：base64 必填。";
  return tcc(`tcc photos save ${params.base64}`);
}

async function health_read(params: { metric?: string; days?: number; n?: number } = {}) {
  const m = (params.metric || "").toLowerCase();
  if (m === "hrt") {
    const n = Math.min(Math.max(params.n ?? 10, 1), 100);
    return tcc(`tcc health hrt ${n}`);
  }
  const days = Math.min(Math.max(params.days ?? 7, 1), 90);
  return tcc(`tcc health steps ${days}`);
}

async function location_get() {
  return tcc("tcc location get");
}

exports.contacts_read = contacts_read;
exports.calendar_list = calendar_list;
exports.calendar_create = calendar_create;
exports.reminders_list = reminders_list;
exports.reminders_create = reminders_create;
exports.photos_recent = photos_recent;
exports.photos_save = photos_save;
exports.health_read = health_read;
exports.location_get = location_get;
exports.main = contacts_read;

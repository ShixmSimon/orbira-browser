/*
 * 共享 favicon 客户端。
 *
 * 引擎回包由 AuraShell 统一落进 AppStorage 的 'auraFavicons'（url → PNG base64
 * 的数组），所有面板都从该键读取；本模块只负责「按需请求」与「解析」。
 *
 * 设计要点（对齐 HomeSurface 的 FaviconStore 做法）：
 *   · 只问 http(s)，chrome:// file:// data: 永远没有 favicon，白占请求额度。
 *   · 内存里 settled/pending 两个集合去重，同一 url 命中过就不再问。
 *   · 攒一拍合批（BATCH_MS）后**一次**发 getFavicons（引擎单次上限 100）。
 *   · 解析只返回「本次回包里命中的」url → dataURL，由面板并入各自的 @State map。
 *
 * 占位（无 favicon 时）：按主机名稳定取色 + 白字首字母 —— Chrome 的 fake
 * favicon 做法，比一片灰底字母可分辨得多。
 */
import { BrowserCommandPayload, FaviconImage } from 'engine';

const FAVICON_SIZE_VP: number = 48;
const FAVICON_BATCH_MS: number = 60;
const FAVICON_BATCH_MAX: number = 100;
const PLACEHOLDER_TINTS: string[] = [
  '#4285F4', '#0F9D58', '#DB4437', '#F4B400', '#7B1FA2', '#00897B', '#E8710A'
];

function isHttp(url: string): boolean {
  return url.startsWith('http://') || url.startsWith('https://');
}

// 主机名（小写，去端口/路径/查询）。占位色与请求都按它归一。
export function hostOf(url: string): string {
  let u = url.trim();
  const i = u.indexOf('://');
  if (i >= 0) {
    u = u.substring(i + 3);
  }
  const slash = u.indexOf('/');
  if (slash >= 0) {
    u = u.substring(0, slash);
  }
  const q = u.indexOf('?');
  if (q >= 0) {
    u = u.substring(0, q);
  }
  const at = u.indexOf('@');
  if (at >= 0) {
    u = u.substring(at + 1);
  }
  const colon = u.indexOf(':');
  if (colon >= 0) {
    u = u.substring(0, colon);
  }
  return u.toLowerCase();
}

// 占位首字母（主机名首字符，大写；无则 ?）。
export function firstLetterOfHost(url: string): string {
  const h = hostOf(url);
  return h.length > 0 ? h.charAt(0).toUpperCase() : '?';
}

// 占位底板色：主机名哈希 → 稳定落在 PLACEHOLDER_TINTS。
export function placeholderTint(url: string): string {
  const h = hostOf(url);
  let hash = 0;
  for (let i = 0; i < h.length; i += 1) {
    hash = (hash * 31 + h.charCodeAt(i)) | 0;
  }
  const idx = Math.abs(hash) % PLACEHOLDER_TINTS.length;
  return PLACEHOLDER_TINTS[idx];
}

// 已问过（含取不到的）的 url —— 命中不命中都只问一次。
const asked: Set<string> = new Set();
// 本轮等待合批的 url。
const queued: Set<string> = new Set();
let batchTimer: number = -1;
// 最近一次 requestFavicons 的派发器（合批回调里用，避免闭包拿不到）。
let dispatch: ((cmd: BrowserCommandPayload) => void) | null = null;
let seq: number = 0;

// 把一批 url 交给引擎问图标。重复调用会去重合批；onCommand 是面板的命令回调
// （与主页磁贴共用同一个 getFavicons 通道，AuraShell 会把回包并回 auraFavicons）。
export function requestFavicons(urls: string[], onCommand: (cmd: BrowserCommandPayload) => void): void {
  dispatch = onCommand;
  let added = 0;
  for (const url of urls) {
    if (!isHttp(url)) {
      continue;
    }
    if (asked.has(url) || queued.has(url)) {
      continue;
    }
    queued.add(url);
    added += 1;
  }
  if (added === 0 || batchTimer !== -1) {
    return;
  }
  batchTimer = setTimeout((): void => {
    batchTimer = -1;
    flush();
  }, FAVICON_BATCH_MS);
}

function flush(): void {
  if (dispatch === null) {
    queued.clear();
    return;
  }
  const list = Array.from(queued);
  queued.clear();
  if (list.length === 0) {
    return;
  }
  for (const url of list) {
    asked.add(url);
  }
  for (let start = 0; start < list.length; start += FAVICON_BATCH_MAX) {
    const slice = list.slice(start, start + FAVICON_BATCH_MAX);
    seq += 1;
    dispatch!({
      command: 'getFavicons',
      requestId: seq,
      urls: slice,
      sizeVp: FAVICON_SIZE_VP
    });
  }
}

// 解析 auraFavicons 回包（FaviconImage[]），返回 url → dataURL。空/异常返回空 map。
export function parseFavicons(json: string): Map<string, string> {
  const out: Map<string, string> = new Map();
  if (!json || json.length === 0) {
    return out;
  }
  try {
    const items = JSON.parse(json) as FaviconImage[];
    for (const item of items) {
      if (item.url && item.url.length > 0 && item.pngBase64 && item.pngBase64.length > 0) {
        out.set(item.url, `data:image/png;base64,${item.pngBase64}`);
      }
    }
  } catch (error) {
  }
  return out;
}

// 从面板本地 map 取某 url 的 dataURL（无则空串，交给 AuraSiteIcon 走占位）。
export function faviconData(url: string, cache: Map<string, string>): string {
  return cache.get(url) ?? '';
}

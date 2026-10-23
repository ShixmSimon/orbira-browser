/*
 * 共享 favicon 客户端。
 *
 * 引擎回包由 AuraShell 统一落进 AppStorage 的 'auraFavicons'（url → PNG base64
 * 的数组），所有面板都从该键读取；本模块负责「按需请求」「累积缓存」「解析」。
 *
 * 设计要点（对齐 HomeSurface 的 FaviconStore 做法）：
 *   · 只问 http(s)，chrome:// file:// data: 永远没有 favicon，白占请求额度。
 *   · **累积缓存**：'auraFavicons' 每次回包是**整体替换**的，只解析当前这包会
 *     丢掉上一包的图标（多分片/多次请求时表现为"图标时有时无"）。所以这里把
 *     每次回包并进模块级 cache，面板拿的是整份快照。
 *   · **未命中会重试**：引擎首次可能还没抓到图标（刚访问、DB 还没落盘），
 *     一次问不到就永久拉黑会让图标永远是占位块。这里按 url 记尝试次数，
 *     最多 MAX_ATTEMPTS 次、间隔 RETRY_MS 自动补问。
 *   · 攒一拍合批（BATCH_MS）后**一次**发 getFavicons（引擎单次上限 100）。
 *   · url 精确匹配失败时退化为按主机名匹配（跨 scheme / 尾斜杠 / 子路径差异）。
 *
 * 占位（无 favicon 时）：按主机名稳定取色 + 白字首字母 —— Chrome 的 fake
 * favicon 做法，比一片灰底字母可分辨得多。
 */
import { BrowserCommandPayload, FaviconImage } from 'engine';

const FAVICON_SIZE_VP: number = 48;
const FAVICON_BATCH_MS: number = 60;
const FAVICON_BATCH_MAX: number = 100;
// 未命中的补问间隔与次数上限：首次回包常常是空的（引擎还在抓），
// 补 2 次基本能覆盖；再问不到就当该站点确实没有 favicon，不再骚扰引擎。
const FAVICON_RETRY_MS: number = 1200;
const FAVICON_MAX_ATTEMPTS: number = 3;
const PLACEHOLDER_TINTS: string[] = [
  '#4285F4', '#0F9D58', '#DB4437', '#F4B400', '#7B1FA2', '#00897B', '#E8710A', '#546E7A'
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

// 累积缓存：url → dataURL；同一主机名另存一份 host 键，做精确匹配失败时的兜底。
const cache: Map<string, string> = new Map();
// 面板关心过的 url（补问的依据）。
const wanted: Set<string> = new Set();
// 每个 url 已发过几次。
const attempts: Map<string, number> = new Map();
// 本轮等待合批的 url。
const queued: Set<string> = new Set();
let batchTimer: number = -1;
let retryTimer: number = -1;
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
    wanted.add(url);
    if (cache.has(url) || queued.has(url)) {
      continue;
    }
    if ((attempts.get(url) ?? 0) >= FAVICON_MAX_ATTEMPTS) {
      continue;
    }
    queued.add(url);
    added += 1;
  }
  if (added === 0) {
    scheduleRetry();
    return;
  }
  if (batchTimer === -1) {
    batchTimer = setTimeout((): void => {
      batchTimer = -1;
      flush();
    }, FAVICON_BATCH_MS);
  }
}

function flush(): void {
  if (dispatch === null) {
    queued.clear();
    return;
  }
  const list: string[] = Array.from(queued);
  queued.clear();
  if (list.length === 0) {
    return;
  }
  for (const url of list) {
    attempts.set(url, (attempts.get(url) ?? 0) + 1);
  }
  for (let start = 0; start < list.length; start += FAVICON_BATCH_MAX) {
    const slice = list.slice(start, start + FAVICON_BATCH_MAX);
    seq += 1;
    dispatch({
      command: 'getFavicons',
      requestId: seq,
      urls: slice,
      sizeVp: FAVICON_SIZE_VP
    });
  }
  scheduleRetry();
}

// 还有没命中的 url 就安排一次补问（有次数上限，不会死循环）。
function scheduleRetry(): void {
  if (retryTimer !== -1) {
    return;
  }
  let pending = false;
  wanted.forEach((url: string): void => {
    if (cache.has(url) || queued.has(url)) {
      return;
    }
    if ((attempts.get(url) ?? 0) < FAVICON_MAX_ATTEMPTS) {
      pending = true;
    }
  });
  if (!pending) {
    return;
  }
  retryTimer = setTimeout((): void => {
    retryTimer = -1;
    if (dispatch === null) {
      return;
    }
    let added = 0;
    wanted.forEach((url: string): void => {
      if (cache.has(url) || queued.has(url)) {
        return;
      }
      if ((attempts.get(url) ?? 0) >= FAVICON_MAX_ATTEMPTS) {
        return;
      }
      queued.add(url);
      added += 1;
    });
    if (added > 0) {
      flush();
    }
  }, FAVICON_RETRY_MS);
}

// 把一份 auraFavicons 回包并进累积缓存。'auraFavicons' 是整体替换的，
// 面板每次收到新回包都要先 ingest、再 snapshotFavicons() 拿整份。
export function ingestFavicons(json: string): void {
  if (!json || json.length === 0) {
    return;
  }
  try {
    const items = JSON.parse(json) as FaviconImage[];
    for (const item of items) {
      const url = item.url ?? '';
      const base64 = item.pngBase64 ?? '';
      if (url.length === 0 || base64.length === 0) {
        continue;
      }
      const dataUrl = `data:image/png;base64,${base64}`;
      cache.set(url, dataUrl);
      // 主机名兜底键：同一站点不同子路径/尾斜杠时也能命中。
      const host = hostOf(url);
      if (host.length > 0 && !cache.has(host)) {
        cache.set(host, dataUrl);
      }
    }
  } catch (error) {
  }
}

// 整份快照（新 Map → 赋给面板 @State 会触发重绘）。
export function snapshotFavicons(): Map<string, string> {
  const out: Map<string, string> = new Map();
  cache.forEach((value: string, key: string): void => {
    out.set(key, value);
  });
  return out;
}

// 从面板本地 map 取某 url 的 dataURL（无则空串，交给 AuraSiteIcon 走占位）。
// 先精确匹配，再按主机名兜底。
export function faviconData(url: string, cacheMap: Map<string, string>): string {
  const exact = cacheMap.get(url);
  if (exact !== undefined && exact.length > 0) {
    return exact;
  }
  return cacheMap.get(hostOf(url)) ?? '';
}

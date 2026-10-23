// Shared shell helpers: turning what a reader typed into something to
// navigate to. Used by the address bar and the home surface, so a search
// behaves the same in both places.

// The template comes from the default search engine's resolved searchUrl
// (getSearchEngines), parked by AuraShell. Placeholders are normalized to
// `{searchTerms}` first (Chrome-style `%s` is converted, see below), then
// `{searchTerms}` is the only thing left to substitute.
const SEARCH_TEMPLATE_KEY: string = 'auraSearchUrlTemplate';

const FALLBACK_SEARCH_PREFIX: string = 'https://cn.bing.com/search?q=';

// 占位符归一：Chrome 桌面版（以及网上抄来的搜索模板）用 `%s`，OpenSearch 用
// `{searchTerms}`。用户粘贴 `https://www.baidu.com/s?wd=%s` 这类 URL 是常态，
// 统一在这里转成 `{searchTerms}`，避免「添加时被拒」或「模板存进了 AppStorage
// 却找不到占位符、静默回退到 Bing」。多处 `%s` 一并替换。
// 注：`%s` 不是合法 percent-encoding（% 后须跟两位十六进制），所以正常编码过的
// URL 不会含 `%s`，误替换风险为零。
export function normalizeSearchTemplate(template: string): string {
  if (template.indexOf('%s') < 0) {
    return template;
  }
  return template.split('%s').join('{searchTerms}');
}

// 只填域名（如 www.baidu.com / baidu.com）时，按内置表推导搜索网址，省得用户去记
// 每家的搜索路径和参数名。表里没有的走通用 /search?q= 启发式（exact=false，调用方
// 应提示这是猜的、不对可改）。用户已给带占位符的完整模板时，归一后原样返回。
export interface SiteTemplateResult {
  template: string;  // 含 {searchTerms} 的搜索模板；'' 表示输入不像域名
  exact: boolean;    // true=内置表精确命中或用户给了完整模板；false=启发式猜的
}

// 常见站点搜索模板（key 为去掉 www. 的小写 host）。
// 注：baidu / bing 用 www 域名是故意的——mobileSearchUrl() 会把它们改写成移动站
// （www.bing.com→cn.bing.com、www.baidu.com→m.baidu.com 且 wd→word），从源头消 302。
const SITE_SEARCH_TEMPLATES: Record<string, string> = {
  'baidu.com': 'https://www.baidu.com/s?wd={searchTerms}',
  'bing.com': 'https://www.bing.com/search?q={searchTerms}',
  'google.com': 'https://www.google.com/search?q={searchTerms}',
  'sogou.com': 'https://www.sogou.com/web?query={searchTerms}',
  'so.com': 'https://www.so.com/s?q={searchTerms}',
  '360.cn': 'https://www.so.com/s?q={searchTerms}',
  'duckduckgo.com': 'https://duckduckgo.com/?q={searchTerms}',
  'yandex.com': 'https://yandex.com/search/?text={searchTerms}',
  'zhihu.com': 'https://www.zhihu.com/search?type=content&q={searchTerms}',
  'bilibili.com': 'https://search.bilibili.com/all?keyword={searchTerms}',
  'github.com': 'https://github.com/search?q={searchTerms}',
  'wikipedia.org': 'https://zh.wikipedia.org/w/index.php?search={searchTerms}',
  'youtube.com': 'https://www.youtube.com/results?search_query={searchTerms}',
  'weibo.com': 'https://s.weibo.com/weibo?q={searchTerms}',
  'toutiao.com': 'https://so.toutiao.com/search?keyword={searchTerms}'
};

export function searchTemplateForSite(input: string): SiteTemplateResult {
  const raw = input.trim();
  const normalized = normalizeSearchTemplate(raw);
  if (normalized.includes('{searchTerms}')) {
    return { template: normalized, exact: true };
  }
  // 去 scheme，再截到第一段（路径/查询/锚点全丢），只留 host
  let host = raw.replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//, '');
  host = host.split('/')[0].split('?')[0].split('#')[0];
  if (host.length === 0 || !host.includes('.')) {
    return { template: '', exact: false };
  }
  const key = host.replace(/^www\./i, '').toLowerCase();
  const hit = SITE_SEARCH_TEMPLATES[key];
  if (hit !== undefined && hit.length > 0) {
    return { template: hit, exact: true };
  }
  return { template: `https://${host}/search?q={searchTerms}`, exact: false };
}

export function normalizeAddress(value: string): string {
  const input = value.trim();
  if (input.length === 0) {
    return '';
  }
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(input)) {
    return input;
  }
  if (/\s/.test(input) || !input.includes('.')) {
    return searchUrlFor(input);
  }
  return `https://${input}`;
}

// 搜索 URL 构造（默认搜索引擎模板 + 编码后的词）。地址栏联想的「搜索」行
// 也用它，保证和提交搜索走同一条规则。
export function searchUrlFor(query: string): string {
  const encoded = encodeURIComponent(query);
  const template = normalizeSearchTemplate(String(AppStorage.get(SEARCH_TEMPLATE_KEY) ?? ''));
  if (template.length > 0 && template.includes('{searchTerms}')) {
    return mobileSearchUrl(template).replace('{searchTerms}', encoded);
  }
  return `${FALLBACK_SEARCH_PREFIX}${encoded}`;
}

// 引擎带的 searchUrl 是桌面域名/参数，手机上访问会被搜索引擎自己 302 到移动
// 站：多一次网络往返，白屏更长，地址栏还会反复跳 ×/⟳。这里直接把已知的桌面
// 形式换成移动站的等价形式，从源头消掉那次重定向。
//   Bing：www → cn（1.0.71 已修）。
//   百度：www → m，同时把桌面用的 `wd` 参数换成移动站标准的 `word`（1.0.76）。
function mobileSearchUrl(template: string): string {
  if (template.includes('www.bing.com')) {
    return template.replace('www.bing.com', 'cn.bing.com');
  }
  if (template.includes('www.baidu.com')) {
    return template.replace('www.baidu.com', 'm.baidu.com').replace('?wd=', '?word=');
  }
  return template;
}

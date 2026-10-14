// Shared shell helpers: turning what a reader typed into something to
// navigate to. Used by the address bar and the home surface, so a search
// behaves the same in both places.

// The template comes from the default search engine's resolved searchUrl
// (getSearchEngines), parked by AuraShell. `{searchTerms}` is the only
// placeholder left to substitute.
const SEARCH_TEMPLATE_KEY: string = 'auraSearchUrlTemplate';

const FALLBACK_SEARCH_PREFIX: string = 'https://cn.bing.com/search?q=';

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
  const template = String(AppStorage.get(SEARCH_TEMPLATE_KEY) ?? '');
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

/*
 * 引擎原生新标签页的 URL 形态。主页层、顶栏、扩展面板共用这一份判据：
 * 只要有一边少认一种写法，引擎换 URL 时就会漏出它的原生磁贴页。
 *
 * 注意：调用方对「空 url」的含义不同 —— 当前页 url 为空代表主页态，
 * 而 backUrl/forwardUrl 为空代表「没有历史条目」。所以空串判定留在调用方，
 * 本函数只判 URL 形态。
 */
export function isNewTabUrl(url: string): boolean {
  // 第三条在字符串上被第二条覆盖，单独列出是为了明确「引擎实际提交的
  // 第三方 NTP」也在判据内；将来收窄前缀时不会把它意外排除。
  return url.startsWith('chrome://newtab') ||
    url.startsWith('chrome://new-tab-page') ||
    url.startsWith('chrome://new-tab-page-third-party') ||
    url.startsWith('chrome-native://newtab');
}

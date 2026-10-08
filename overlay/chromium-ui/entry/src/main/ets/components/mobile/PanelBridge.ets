// Shared helpers for the mobile panels (bookmarks / history / settings).
// Storage keys used by the panels are written as string literals at both ends
// (AuraShell's AppStorage.setOrCreate and the panels' @StorageLink), because
// decorator arguments must be compile-time literals:
//   'auraPanelBookmarks'  BookmarkNode[]   (getRecentBookmarks)
//   'auraPanelHistory'    HistoryItem[]    (queryHistory)
//   'auraPanelPrefs'      ShellPrefValue[] (getPrefs)
//   'auraPanelEngines'    SearchEngine[]   (getSearchEngines)
//   'auraPanelAbout'      { chromiumVersion } (getAboutInfo)
//   'auraPanelEvent'      { kind, revision }  (changed/op-result nudges)

export function displayUrl(url: string): string {
  let text = url.trim();
  const schemeIndex = text.indexOf('://');
  if (schemeIndex >= 0) {
    text = text.substring(schemeIndex + 3);
  }
  if (text.startsWith('www.')) {
    text = text.substring(4);
  }
  return text.length > 56 ? `${text.substring(0, 56)}…` : text;
}

export function formatVisitTime(visitTime: number): string {
  if (visitTime <= 0) {
    return '';
  }
  const date = new Date(visitTime);
  const now = new Date();
  const two = (value: number): string => value < 10 ? `0${value}` : `${value}`;
  const clock = `${two(date.getHours())}:${two(date.getMinutes())}`;
  if (date.getFullYear() === now.getFullYear() && date.getMonth() === now.getMonth() &&
    date.getDate() === now.getDate()) {
    return `今天 ${clock}`;
  }
  const yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1);
  if (date.getFullYear() === yesterday.getFullYear() && date.getMonth() === yesterday.getMonth() &&
    date.getDate() === yesterday.getDate()) {
    return `昨天 ${clock}`;
  }
  if (date.getFullYear() === now.getFullYear()) {
    return `${date.getMonth() + 1}月${date.getDate()}日`;
  }
  return `${date.getFullYear()}年${date.getMonth() + 1}月${date.getDate()}日`;
}

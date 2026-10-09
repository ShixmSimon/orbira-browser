// Shared helpers for the mobile panels (bookmarks / history / settings).
// Storage keys used by the panels are written as string literals at both ends
// (AuraShell's AppStorage.setOrCreate and the panels' @StorageLink), because
// decorator arguments must be compile-time literals:
//   'auraPanelBookmarks'   BookmarkNode[]   (getRecentBookmarks)
//   'auraPanelHistory'     HistoryItem[]    (queryHistory)
//   'auraPanelPrefs'       ShellPrefValue[] (getPrefs)
//   'auraPanelEngines'     SearchEngine[]   (getSearchEngines)
//   'auraPanelAbout'       { chromiumVersion } (getAboutInfo)
//   'auraPanelEvent'       { kind, revision }  (changed/op-result nudges)
//   'auraPanelPasswordIo'  { kind, requestId, ok, imported, skipped, failed,
//                            count, reason }   (passwordsImported /
//                                              passwordsExported)
//   'auraPanelBookmarkIo'  { kind, requestId, ok, bookmarkCount, folderCount,
//                            skippedCount, error }  (bookmarkImportDone /
//                                                     bookmarkExportDone)
import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';

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

// 历史分组的组名（Lumie 的 DayGrouping：今天 / 昨天 / 月日 / 年月日）。
export function dayGroupLabel(visitTime: number): string {
  if (visitTime <= 0) {
    return '';
  }
  const date = new Date(visitTime);
  const now = new Date();
  if (date.getFullYear() === now.getFullYear() && date.getMonth() === now.getMonth() &&
    date.getDate() === now.getDate()) {
    return '今天';
  }
  const yesterday = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1);
  if (date.getFullYear() === yesterday.getFullYear() && date.getMonth() === yesterday.getMonth() &&
    date.getDate() === yesterday.getDate()) {
    return '昨天';
  }
  if (date.getFullYear() === now.getFullYear()) {
    return `${date.getMonth() + 1}月${date.getDate()}日`;
  }
  return `${date.getFullYear()}年${date.getMonth() + 1}月${date.getDate()}日`;
}

// 组内时刻（HH:MM）。
export function formatClock(visitTime: number): string {
  if (visitTime <= 0) {
    return '';
  }
  const date = new Date(visitTime);
  const two = (value: number): string => value < 10 ? `0${value}` : `${value}`;
  return `${two(date.getHours())}:${two(date.getMinutes())}`;
}

// ---------------------------------------------------------------------------
// 导入 / 导出的文件暂存（对齐 Lumie v2 的密码、书签导入导出流程）。
//
// 契约：引擎的 importXxx / exportXxx 命令只读 / 只写「应用沙箱里的绝对路径」，
// 系统文件选择器与沙箱内外的复制都归外壳管；导入读完后引擎不留副本，缓存
// 文件由外壳删（见 SHELL_CONTRACT 密码 / 书签章）。
// ---------------------------------------------------------------------------

// 打开系统文件选择器，把用户选中的文件复制进应用沙箱，返回沙箱内绝对路径。
// 用户取消或失败返回 ''。
export async function pickAndStageImportFile(context: common.UIAbilityContext,
  suffixFilters: string[]): Promise<string> {
  try {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = suffixFilters;
    const uris: string[] = await new picker.DocumentViewPicker(context).select(options);
    if (uris.length === 0) {
      return '';
    }
    const source = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
    const destPath = `${context.filesDir}/aura-import-${Date.now()}.staged`;
    fs.copyFileSync(source.fd, destPath);
    fs.closeSync(source);
    return destPath;
  } catch (error) {
    console.error('aura pickAndStageImportFile failed:', error);
    return '';
  }
}

// 删除导入用的沙箱缓存（引擎读完即无主，外壳负责清理）。
export function deleteStagedFile(path: string): void {
  if (path.length === 0) {
    return;
  }
  try {
    fs.unlinkSync(path);
  } catch (error) {
  }
}

// 把引擎写好的沙箱文件交给系统保存框，用户选好位置后复制过去，随后删除沙箱
// 缓存。返回 true 表示已保存到用户位置（取消或失败返回 false，调用方自行提示，
// 缓存同样已清理）。
export async function saveExportedFile(context: common.UIAbilityContext,
  stagedPath: string, suggestedName: string): Promise<boolean> {
  let saved = false;
  try {
    const options = new picker.DocumentSaveOptions();
    options.newFileNames = [suggestedName];
    const uris: string[] = await new picker.DocumentViewPicker(context).save(options);
    if (uris.length > 0) {
      const source = fs.openSync(stagedPath, fs.OpenMode.READ_ONLY);
      const dest = fs.openSync(uris[0],
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.copyFileSync(source.fd, dest.fd);
      fs.closeSync(source);
      fs.closeSync(dest);
      saved = true;
    }
  } catch (error) {
    console.error('aura saveExportedFile failed:', error);
  }
  // 引擎只把文件写进沙箱，无论用户是否保存，缓存都由外壳删。
  deleteStagedFile(stagedPath);
  return saved;
}

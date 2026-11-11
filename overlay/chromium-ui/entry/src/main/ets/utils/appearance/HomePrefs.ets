/*
 * 主页自定义（preferences 持久化，shell_ui_prefs）。
 * 1.0.79 主页改造配套：
 * - custom：背景图（沙箱路径）/ Logo·搜索框·书签区 的上下位移与显隐；
 * - homeFolderId：书签里「首页」文件夹 id —— 主页磁贴的数据源；
 * - homeFolderMigrated：旧手动快捷方式是否已一次性迁入「首页」文件夹。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const STORE_NAME = 'shell_ui_prefs';
const KEY_CUSTOM = 'homeCustom';
const KEY_FOLDER_ID = 'homeFolderId';
const KEY_MIGRATED = 'homeFolderMigrated';
const KEY_SEEDED = 'homeBookmarksSeeded';
const KEY_TONE = 'homeWallpaperTone';

// 壁纸三带判色结果缓存，path 用于换图后自动失效。
// 落盘是为了冷启动挂载期就能吃到上次结论，避免解码完成前图标色反一次。
export interface HomeToneCache {
  path: string;
  top: boolean;
  mid: boolean;
  bottom: boolean;
}

export function emptyToneCache(): HomeToneCache {
  return { path: '', top: true, mid: true, bottom: true } as HomeToneCache;
}

export interface HomeCustom {
  // 背景图沙箱绝对路径（'' = 无背景，用主题底色）。
  bgPath: string;
  // 三个分区的位移（vp，相对默认布局；负值上移、正值下移）。
  logoOffset: number;
  searchOffset: number;
  tilesOffset: number;
  // 三个分区的显隐。
  showLogo: boolean;
  showSearch: boolean;
  showTiles: boolean;
}

export function defaultHomeCustom(): HomeCustom {
  return {
    bgPath: '',
    logoOffset: 0,
    searchOffset: 0,
    tilesOffset: 0,
    showLogo: true,
    showSearch: true,
    showTiles: true
  } as HomeCustom;
}

function finiteNumber(value: Object, fallback: number): number {
  if (typeof value === 'number' && Number.isFinite(value)) {
    return value;
  }
  return fallback;
}

function boolOr(value: Object, fallback: boolean): boolean {
  if (typeof value === 'boolean') {
    return value;
  }
  return fallback;
}

export class HomePrefs {
  static async loadCustom(context: common.Context | undefined): Promise<HomeCustom> {
    const out = defaultHomeCustom();
    if (!context) {
      return out;
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const raw = await store.get(KEY_CUSTOM, '') as string;
      if (raw.length === 0) {
        return out;
      }
      const parsed = JSON.parse(raw) as HomeCustom;
      out.bgPath = typeof parsed.bgPath === 'string' ? parsed.bgPath : '';
      out.logoOffset = finiteNumber(parsed.logoOffset, 0);
      out.searchOffset = finiteNumber(parsed.searchOffset, 0);
      out.tilesOffset = finiteNumber(parsed.tilesOffset, 0);
      out.showLogo = boolOr(parsed.showLogo, true);
      out.showSearch = boolOr(parsed.showSearch, true);
      out.showTiles = boolOr(parsed.showTiles, true);
      return out;
    } catch (error) {
      return out;
    }
  }

  static async saveCustom(context: common.Context | undefined, value: HomeCustom): Promise<void> {
    if (!context) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_CUSTOM, JSON.stringify(value));
      await store.flush();
    } catch (error) {
    }
  }

  static async loadFolderId(context: common.Context | undefined): Promise<string> {
    if (!context) {
      return '';
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      return String(await store.get(KEY_FOLDER_ID, ''));
    } catch (error) {
      return '';
    }
  }

  static async saveFolderId(context: common.Context | undefined, id: string): Promise<void> {
    if (!context) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_FOLDER_ID, id);
      await store.flush();
    } catch (error) {
    }
  }

  static async loadMigrated(context: common.Context | undefined): Promise<boolean> {
    if (!context) {
      return true;
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      return Boolean(await store.get(KEY_MIGRATED, false));
    } catch (error) {
      return true;
    }
  }

  static async saveMigrated(context: common.Context | undefined, value: boolean): Promise<void> {
    if (!context) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_MIGRATED, value);
      await store.flush();
    } catch (error) {
    }
  }

  // 主页默认书签是否已一次性种入（谷歌/必应/百度/GitHub）。只种一次，用户删了不重种。
  static async loadSeeded(context: common.Context | undefined): Promise<boolean> {
    if (!context) {
      return true;
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      return Boolean(await store.get(KEY_SEEDED, false));
    } catch (error) {
      return true;
    }
  }

  static async saveSeeded(context: common.Context | undefined, value: boolean): Promise<void> {
    if (!context) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_SEEDED, value);
      await store.flush();
    } catch (error) {
    }
  }

  // 壁纸上一次的三带判色结果（含壁纸路径，换了图自动不认）。
  static async loadTone(context: common.Context | undefined): Promise<HomeToneCache> {
    const out = emptyToneCache();
    if (!context) {
      return out;
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const raw = String(await store.get(KEY_TONE, ''));
      if (raw.length === 0) {
        return out;
      }
      const parsed = JSON.parse(raw) as HomeToneCache;
      out.path = typeof parsed.path === 'string' ? parsed.path : '';
      out.top = boolOr(parsed.top, true);
      out.mid = boolOr(parsed.mid, true);
      out.bottom = boolOr(parsed.bottom, true);
      return out;
    } catch (error) {
      return out;
    }
  }

  static async saveTone(context: common.Context | undefined, value: HomeToneCache): Promise<void> {
    if (!context) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_TONE, JSON.stringify(value));
      await store.flush();
    } catch (error) {
    }
  }
}

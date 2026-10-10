/*
 * 首页手动快捷方式（preferences 持久化，shell_ui_prefs）。
 *
 * 引擎的 getTopSites 只回「常用网站」（按访问历史生成），没有"手动固定"
 * 的入口。外壳侧补一层：用户在首页「+」磁贴里添加的 名称+网址 存在这里，
 * 渲染时排在常用网站前面；长按移除只动这份列表，不碰引擎。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const STORE_NAME = 'shell_ui_prefs';
const KEY_SHORTCUTS = 'homeShortcuts';
// 磁贴排序表：normUrl 后的 url 有序列表（覆盖手动 + 引擎磁贴）。
const KEY_ORDER = 'homeTileOrder';

export interface HomeShortcut {
  title: string;
  url: string;
}

export class HomeShortcuts {
  static async load(context: common.Context | undefined): Promise<HomeShortcut[]> {
    if (!context) {
      return [];
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const raw = await store.get(KEY_SHORTCUTS, '[]') as string;
      const items: HomeShortcut[] = JSON.parse(raw.length > 0 ? raw : '[]') as HomeShortcut[];
      const out: HomeShortcut[] = [];
      for (const item of items) {
        if (item && item.url && item.url.length > 0) {
          out.push({ title: item.title, url: item.url } as HomeShortcut);
        }
      }
      return out;
    } catch (error) {
      return [];
    }
  }

  static async save(context: common.Context | undefined, items: HomeShortcut[]): Promise<void> {
    if (!context) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_SHORTCUTS, JSON.stringify(items));
      await store.flush();
    } catch (error) {
    }
  }

  /** 添加到最前（去重：同 url 先删旧的）。返回更新后的列表。 */
  static async add(context: common.Context | undefined, title: string, url: string): Promise<HomeShortcut[]> {
    const items = await HomeShortcuts.load(context);
    const kept: HomeShortcut[] = [];
    for (const item of items) {
      if (item.url !== url) {
        kept.push(item);
      }
    }
    kept.unshift({ title: title, url: url } as HomeShortcut);
    await HomeShortcuts.save(context, kept);
    return kept;
  }

  /**
   * 更新一条（按 originalUrl 定位；找不到 = 引擎项「编辑落成手动项」，
   * 等效添加）。url 改名后与其它条目撞车时去重。返回更新后的列表。
   */
  static async update(context: common.Context | undefined, originalUrl: string,
    title: string, url: string): Promise<HomeShortcut[]> {
    const items = await HomeShortcuts.load(context);
    const out: HomeShortcut[] = [];
    for (const item of items) {
      if (item.url === originalUrl) {
        continue;
      }
      if (item.url !== url) {
        out.push(item);
      }
    }
    out.unshift({ title: title, url: url } as HomeShortcut);
    await HomeShortcuts.save(context, out);
    return out;
  }

  /** 读取磁贴顺序表（无记录返回空数组 = 按默认顺序渲染）。 */
  static async loadOrder(context: common.Context | undefined): Promise<string[]> {
    if (!context) {
      return [];
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const raw = await store.get(KEY_ORDER, '[]') as string;
      const out: string[] = [];
      for (const v of JSON.parse(raw.length > 0 ? raw : '[]') as string[]) {
        if (v && v.length > 0) {
          out.push(v);
        }
      }
      return out;
    } catch (error) {
      return [];
    }
  }

  static async saveOrder(context: common.Context | undefined, urls: string[]): Promise<void> {
    if (!context) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_ORDER, JSON.stringify(urls));
      await store.flush();
    } catch (error) {
    }
  }

  /** 按 url 移除。返回更新后的列表。 */
  static async remove(context: common.Context | undefined, url: string): Promise<HomeShortcut[]> {
    const items = await HomeShortcuts.load(context);
    const kept: HomeShortcut[] = [];
    for (const item of items) {
      if (item.url !== url) {
        kept.push(item);
      }
    }
    await HomeShortcuts.save(context, kept);
    return kept;
  }
}

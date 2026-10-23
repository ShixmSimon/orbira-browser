/*
 * 主页快捷方式的本地移除黑名单（preferences 持久化，shell_ui_prefs）。
 * 引擎的 removeTopSite 只对固定快捷方式生效；由访问历史衍生的"常用网站"
 * 磁贴会被 getTopSites 重新生成（实测删了又回来）。外壳侧再过滤一层：
 * 移除时把 url 记进黑名单，解析 topSites 时跳过，保证长按移除后不再出现。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const STORE_NAME = 'shell_ui_prefs';
const KEY_BLOCKLIST = 'topSitesBlocklist';

export class TopSitesBlocklist {
  static async load(context: common.Context | undefined): Promise<Set<string>> {
    const urls = new Set<string>();
    if (!context) {
      return urls;
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const raw = await store.get(KEY_BLOCKLIST, '[]') as string;
      const items: string[] = JSON.parse(raw.length > 0 ? raw : '[]') as string[];
      for (const item of items) {
        if (item && item.length > 0) {
          urls.add(item);
        }
      }
    } catch (error) {
    }
    return urls;
  }

  static async add(context: common.Context | undefined, url: string): Promise<void> {
    if (!context || url.length === 0) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const raw = await store.get(KEY_BLOCKLIST, '[]') as string;
      const items: string[] = JSON.parse(raw.length > 0 ? raw : '[]') as string[];
      let exists = false;
      for (const item of items) {
        if (item === url) {
          exists = true;
          break;
        }
      }
      if (!exists) {
        items.push(url);
      }
      await store.put(KEY_BLOCKLIST, JSON.stringify(items));
      await store.flush();
    } catch (error) {
    }
  }
}

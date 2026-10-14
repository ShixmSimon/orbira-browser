/*
 * 自定义搜索引擎（preferences 持久化，shell_ui_prefs）。
 *
 * 引擎只提供 getSearchEngines / setDefaultSearchEngine，没有「新增/删除搜索引擎」
 * 的命令（已核实 overlay 中不存在 add/removeSearchEngine）。所以自定义引擎完全由
 * 外壳侧管理：存在 preferences 里，列表显示时与引擎返回的合并；选自定义引擎为默认
 * 时直接覆盖 AppStorage 的 'auraSearchUrlTemplate'（地址栏与主页搜索都读它）。
 * Bing / Google 受保护不可删（见 SettingsPanel.isEngineProtected）。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { SearchEngine } from 'engine';

const STORE_NAME = 'shell_ui_prefs';
const KEY_CUSTOM = 'customSearchEngines';
const KEY_DEFAULT_ID = 'searchDefaultId';

export interface CustomSearchEngine extends SearchEngine {
}

export class SearchEnginesPrefs {
  static async loadCustom(context: common.Context | undefined): Promise<SearchEngine[]> {
    if (!context) {
      return [];
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const raw = await store.get(KEY_CUSTOM, '') as string;
      if (raw.length === 0) {
        return [];
      }
      const parsed = JSON.parse(raw) as SearchEngine[];
      if (!Array.isArray(parsed)) {
        return [];
      }
      return parsed.filter((e: SearchEngine): boolean => e && typeof e.id === 'string');
    } catch (error) {
      return [];
    }
  }

  static async saveCustom(context: common.Context | undefined, list: SearchEngine[]): Promise<void> {
    if (!context) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_CUSTOM, JSON.stringify(list));
      await store.flush();
    } catch (error) {
    }
  }

  static async loadDefaultId(context: common.Context | undefined): Promise<string> {
    if (!context) {
      return '';
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      return String(await store.get(KEY_DEFAULT_ID, ''));
    } catch (error) {
      return '';
    }
  }

  static async saveDefaultId(context: common.Context | undefined, id: string): Promise<void> {
    if (!context) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_DEFAULT_ID, id);
      await store.flush();
    } catch (error) {
    }
  }
}

/*
 * 外壳自己的界面偏好（preferences 持久化），与引擎 prefs 无关。
 * 目前只有一项：上滑隐藏状态栏（地址栏收起时一起隐藏，网页铺满全屏）。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const STORE_NAME = 'shell_ui_prefs';
const KEY_HIDE_STATUS_BAR = 'hideStatusBarOnScroll';
const KEY_HIDE_TOP_BAR = 'hideTopBarOnScroll';
const KEY_HIDE_DOCK = 'hideDockOnScroll';
const KEY_EXTERNAL_APP_LINKS = 'externalAppLinks';

export class ShellUiPrefs {
  static async loadHideStatusBar(context: common.Context): Promise<boolean> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      return Boolean(await store.get(KEY_HIDE_STATUS_BAR, false));
    } catch (error) {
      return false;
    }
  }

  static async saveHideStatusBar(context: common.Context, value: boolean): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_HIDE_STATUS_BAR, value);
      await store.flush();
    } catch (error) {
    }
  }

  static async loadHideTopBar(context: common.Context): Promise<boolean> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      return Boolean(await store.get(KEY_HIDE_TOP_BAR, true));
    } catch (error) {
      return true;
    }
  }

  static async saveHideTopBar(context: common.Context, value: boolean): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_HIDE_TOP_BAR, value);
      await store.flush();
    } catch (error) {
    }
  }

  static async loadHideDock(context: common.Context): Promise<boolean> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      return Boolean(await store.get(KEY_HIDE_DOCK, true));
    } catch (error) {
      return true;
    }
  }

  static async saveHideDock(context: common.Context, value: boolean): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_HIDE_DOCK, value);
      await store.flush();
    } catch (error) {
    }
  }

  // 网页里的外链（知乎/B站等已转成对应 scheme 的 intent）是否交给本机应用打开。
  // 默认开：浏览器常见的就是这个行为。关掉后一律留在浏览器里打开 fallbackUrl。
  static async loadExternalAppLinks(context: common.Context): Promise<boolean> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      return Boolean(await store.get(KEY_EXTERNAL_APP_LINKS, true));
    } catch (error) {
      return true;
    }
  }

  static async saveExternalAppLinks(context: common.Context, value: boolean): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_EXTERNAL_APP_LINKS, value);
      await store.flush();
    } catch (error) {
    }
  }
}

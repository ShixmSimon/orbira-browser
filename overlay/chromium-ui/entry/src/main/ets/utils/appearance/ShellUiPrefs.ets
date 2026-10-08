/*
 * 外壳自己的界面偏好（preferences 持久化），与引擎 prefs 无关。
 * 目前只有一项：上滑隐藏状态栏（地址栏收起时一起隐藏，网页铺满全屏）。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const STORE_NAME = 'shell_ui_prefs';
const KEY_HIDE_STATUS_BAR = 'hideStatusBarOnScroll';

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
}

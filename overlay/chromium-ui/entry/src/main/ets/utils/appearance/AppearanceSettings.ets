/*
 * 应用外观（深色模式）设置。
 * 'system' 跟随系统 / 'light' 浅色 / 'dark' 深色，持久化在 preferences 里。
 * setColorMode 触发应用级配置更新：所有 $r('app.color.*') 一起重解析，
 * 外壳界面与引擎（网页）同步变色。
 */
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const STORE_NAME = 'appearance_settings';
const KEY_COLOR_MODE = 'colorMode';

export type ColorModeSetting = 'system' | 'light' | 'dark';

export class AppearanceSettings {
  static async load(context: common.Context): Promise<ColorModeSetting> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const value = await store.get(KEY_COLOR_MODE, 'system');
      const mode = String(value);
      return mode === 'light' || mode === 'dark' ? mode : 'system';
    } catch (error) {
      return 'system';
    }
  }

  // Synchronous twin of load(), for the startup path: the saved choice has to
  // be applied before the window -- and with it the engine -- is created, or
  // the first page loads with the wrong colour scheme and stays that way until
  // it is reloaded. An async read cannot promise that ordering: onWindowStageCreate
  // runs before its promise settles.
  static loadSync(context: common.Context): ColorModeSetting {
    try {
      const store = preferences.getPreferencesSync(context, { name: STORE_NAME });
      const mode = String(store.getSync(KEY_COLOR_MODE, 'system'));
      return mode === 'light' || mode === 'dark' ? mode : 'system';
    } catch (error) {
      return 'system';
    }
  }

  static async save(context: common.Context, mode: ColorModeSetting): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_COLOR_MODE, mode);
      await store.flush();
    } catch (error) {
    }
  }

  static apply(context: common.Context, mode: ColorModeSetting): void {
    let colorMode: ConfigurationConstant.ColorMode =
      ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (mode === 'dark') {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } else if (mode === 'light') {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    try {
      context.getApplicationContext().setColorMode(colorMode);
    } catch (error) {
    }
  }
}

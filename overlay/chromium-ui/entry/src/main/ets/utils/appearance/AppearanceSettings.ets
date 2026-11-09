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
// v2：早期版本把「开关显示值」当成绝对 pref 存过（语义错误），残留值会让
// 升级后首次打开仍然是「已偏离」的样子。换 key 等价于一次性重置为 follow，
// 后续拨动照常持久化。
const KEY_FORCE_DARK_OVERRIDE = 'forceDarkOverride2';
// 覆盖态写入时的配色。系统定时自动切主题常发生在后台，配置回调可能丢失，
// 于是「主题变化就重置覆盖态」这条不会执行；下次冷启动若把上次深色主题内
// 手动拨过的 'on' 原样读回，浅色下的网页会被强制拉深。带上主题即可让跨主题
// 的残留自动失效，不依赖那条不可靠的回调。
const KEY_FORCE_DARK_OVERRIDE_SCHEME = 'forceDarkOverrideScheme2';

export type ColorModeSetting = 'system' | 'light' | 'dark';

// 网页强制深色的手动覆盖态。'follow' 表示跟随主题（深色开 / 浅色关）；
// 'on' / 'off' 是显式覆盖值，只在当前主题内有效，
// 主题一旦变化就回到 'follow'，避免手动关一次之后永远不再跟随。
export type ForceDarkOverride = 'follow' | 'on' | 'off';

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

  // currentScheme 是当前实际生效的配色。落盘配色与它不一致就丢弃覆盖态，
  // 让「系统自动切主题 + 冷启动」也能回到跟随，而不必等配置回调。
  static loadForceDarkOverrideSync(context: common.Context,
                                   currentScheme?: 'light' | 'dark'): ForceDarkOverride {
    try {
      const store = preferences.getPreferencesSync(context, { name: STORE_NAME });
      const value = String(store.getSync(KEY_FORCE_DARK_OVERRIDE, 'follow'));
      if (value !== 'on' && value !== 'off') {
        return 'follow';
      }
      if (currentScheme) {
        const savedScheme = String(store.getSync(KEY_FORCE_DARK_OVERRIDE_SCHEME, ''));
        if (savedScheme !== currentScheme) {
          return 'follow';
        }
      }
      return value as ForceDarkOverride;
    } catch (error) {
      return 'follow';
    }
  }

  static async saveForceDarkOverride(context: common.Context,
                                     value: ForceDarkOverride,
                                     scheme?: 'light' | 'dark'): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      await store.put(KEY_FORCE_DARK_OVERRIDE, value);
      // 没带配色就写空标记，读回时与任何配色都不等，等价于一次性作废旧值。
      await store.put(KEY_FORCE_DARK_OVERRIDE_SCHEME, scheme ?? '');
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

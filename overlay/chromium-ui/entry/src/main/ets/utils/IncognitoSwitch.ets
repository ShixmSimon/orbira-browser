/*
 * 无痕模式（手机路线）。
 *
 * 引擎里一个 Browser 绑一个 Profile，手机只跑单进程、装不下第二个 Profile，
 * 所以 newIncognitoWindow 在手机上会被引擎直接拒绝。参考实现里绕开的
 * 办法是：把当前标签记下来，然后用另一个 profileId 重启应用 —— 引擎据此把
 * profile 放在 filesDir/chromium-profiles/incognito，等于换了一套干净的
 * 用户数据目录，单进程也成立。退出无痕时再重启回普通 profile，并把那个目录
 * 整个删掉，什么都不留下。
 *
 * 这里只做外壳该做的部分：读写启动 want、保存/取回标签、重启、清目录。
 */
import { common, Want } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export const INCOGNITO_NORMAL_PROFILE_ID: string = 'local';
export const INCOGNITO_PROFILE_ID: string = 'incognito';
// Restart parameters: what EntryAbility reads off the launch want.
export const INCOGNITO_WANT_KEY: string = 'auraIncognito';
export const INCOGNITO_START_URL_KEY: string = 'auraIncognitoStartUrl';

const SESSION_STORE: string = 'aura_session';
const SAVED_TABS_KEY: string = 'savedTabs';
const DOMAIN: number = 0x0000;
const TAG: string = 'AuraShell';

export interface SavedTab {
  url: string;
  title: string;
}

export class IncognitoSwitch {
  static profileId(incognito: boolean): string {
    return incognito ? INCOGNITO_PROFILE_ID : INCOGNITO_NORMAL_PROFILE_ID;
  }

  // True when this launch is the restart we asked for on the way in.
  static incognitoFromWant(want: Want | undefined): boolean {
    if (!want || !want.parameters) {
      return false;
    }
    return Boolean(want.parameters[INCOGNITO_WANT_KEY] ?? false);
  }

  static startUrlFromWant(want: Want | undefined): string {
    if (!want || !want.parameters) {
      return '';
    }
    const value = want.parameters[INCOGNITO_START_URL_KEY];
    return typeof value === 'string' ? value : '';
  }

  // Restart the app on the other profile. Everything the reader had open is
  // saved first (see saveTabs) and put back when they leave incognito.
  static restart(context: common.UIAbilityContext, incognito: boolean, startUrl: string): void {
    const parameters: Record<string, Object> = {};
    parameters[INCOGNITO_WANT_KEY] = incognito;
    parameters[INCOGNITO_START_URL_KEY] = startUrl;
    const want: Want = {
      bundleName: context.abilityInfo.bundleName,
      abilityName: context.abilityInfo.name,
      parameters: parameters
    };
    try {
      context.getApplicationContext().restartApp(want);
    } catch (error) {
      const failure = error as BusinessError;
      hilog.error(DOMAIN, TAG, 'Failed to restart into incognito: %{public}s', failure.code?.toString() ?? '');
    }
  }

  static async saveTabs(context: common.Context, tabs: SavedTab[]): Promise<boolean> {
    if (tabs.length === 0) {
      return true;
    }
    try {
      const store = await preferences.getPreferences(context, SESSION_STORE);
      await store.put(SAVED_TABS_KEY, JSON.stringify(tabs));
      await store.flush();
      return true;
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'Failed to save the tabs before incognito');
      return false;
    }
  }

  // Reads the saved tabs and clears them in one step: they belong to one
  // round trip through incognito.
  static async takeSavedTabs(context: common.Context): Promise<SavedTab[]> {
    try {
      const store = await preferences.getPreferences(context, SESSION_STORE);
      const raw = String(await store.get(SAVED_TABS_KEY, ''));
      if (raw.length === 0) {
        return [];
      }
      await store.put(SAVED_TABS_KEY, '');
      await store.flush();
      const parsed = JSON.parse(raw) as SavedTab[];
      const tabs: SavedTab[] = [];
      for (const item of parsed) {
        if (item && item.url && item.url.length > 0) {
          tabs.push({ url: item.url, title: item.title ?? '' });
        }
      }
      return tabs;
    } catch (error) {
      return [];
    }
  }

  // Called on an ordinary launch: the incognito profile directory held this
  // session's cookies, history and form data, and none of it should outlive
  // the session.
  static sweepIncognitoProfile(context: common.Context): void {
    const dir: string = `${context.filesDir}/chromium-profiles/${INCOGNITO_PROFILE_ID}`;
    try {
      if (fileIo.accessSync(dir)) {
        fileIo.rmdirSync(dir);
        hilog.info(DOMAIN, TAG, 'Swept the incognito profile directory');
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'Could not sweep the incognito profile directory');
    }
  }
}

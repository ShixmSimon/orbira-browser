/*
 * 华为账号（账号登录）。
 *
 * 登录本身走 Account Kit 的 LoginWithHuaweiIDButton（见 AccountPanel）；
 * 这里只管本地状态：把 openID / unionID 落在 preferences 里，AppStorage
 * 存一份给界面用（'auraHuaweiAccount'）。
 * "退出登录"只是清掉本地状态——系统的华为账号和云空间数据不受影响，
 * 文案一致（"只在这里退出"）。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export interface HuaweiAccountInfo {
  signedIn: boolean;
  openID: string;
  unionID: string;
}

export const EMPTY_HUAWEI_ACCOUNT: HuaweiAccountInfo = {
  signedIn: false,
  openID: '',
  unionID: ''
};

const STORE_NAME = 'aura_account';
const KEY_ACCOUNT = 'huaweiAccount';

function parseAccount(raw: string): HuaweiAccountInfo {
  try {
    const value = JSON.parse(raw) as HuaweiAccountInfo;
    return {
      signedIn: value.signedIn === true,
      openID: String(value.openID ?? ''),
      unionID: String(value.unionID ?? '')
    };
  } catch (error) {
    return { signedIn: false, openID: '', unionID: '' };
  }
}

export function currentAccount(): HuaweiAccountInfo {
  const raw = AppStorage.get<string>('auraHuaweiAccount');
  return raw !== undefined ? parseAccount(raw) : EMPTY_HUAWEI_ACCOUNT;
}

export async function loadAccount(context: common.Context): Promise<HuaweiAccountInfo> {
  const fallback = EMPTY_HUAWEI_ACCOUNT;
  try {
    const store = await preferences.getPreferences(context, STORE_NAME);
    const raw = await store.get(KEY_ACCOUNT, '') as string;
    const info = parseAccount(raw);
    AppStorage.setOrCreate('auraHuaweiAccount', JSON.stringify(info));
    return info;
  } catch (error) {
    return fallback;
  }
}

export async function saveAccount(context: common.Context, info: HuaweiAccountInfo): Promise<void> {
  AppStorage.setOrCreate('auraHuaweiAccount', JSON.stringify(info));
  try {
    const store = await preferences.getPreferences(context, STORE_NAME);
    await store.put(KEY_ACCOUNT, JSON.stringify(info));
    await store.flush();
  } catch (error) {
    console.error('aura saveAccount failed:', error);
  }
}

export async function clearAccount(context: common.Context): Promise<void> {
  AppStorage.setOrCreate('auraHuaweiAccount', JSON.stringify(EMPTY_HUAWEI_ACCOUNT));
  try {
    const store = await preferences.getPreferences(context, STORE_NAME);
    await store.delete(KEY_ACCOUNT);
    await store.flush();
  } catch (error) {
    console.error('aura clearAccount failed:', error);
  }
}

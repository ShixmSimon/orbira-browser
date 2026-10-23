/*
 * 扩展图标持久缓存。
 *
 * 为什么需要：引擎在启用/停用扩展后会异步重新生成 action 图标，
 * getExtensionActions 的回包里 iconPngBase64 常有一段空窗（装机实测：
 * 开关扩展时图标时有时无，要退出重进才恢复）。面板侧的补拉重试只能缩短
 * 空窗，救不了「引擎侧图标真没生成出来」的时刻。
 *
 * 做法：引擎给过一次的图标就存下来（内存 Map + shell_ui_prefs 落盘，跨重启
 * 也在）；面板收到回包时，空图标直接用缓存补上，观感上图标就是持久的。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

const STORE_NAME = 'shell_ui_prefs';
const KEY_ICONS = 'extIconCache';
// 图标是 base64 PNG（每个几 KB）；32 个远超真实用量，防 prefs 无限膨胀。
const MAX_ENTRIES: number = 32;
// 落盘防抖：开关扩展会连着回好几包，别一包写一次盘。
const SAVE_DEBOUNCE_MS: number = 600;

const cache: Map<string, string> = new Map();
let loaded: boolean = false;
let saveTimer: number = -1;

function persist(context: common.Context | undefined): void {
  if (!context) {
    return;
  }
  if (saveTimer !== -1) {
    clearTimeout(saveTimer);
  }
  saveTimer = setTimeout((): void => {
    saveTimer = -1;
    const json = JSON.stringify(Array.from(cache.entries()));
    preferences.getPreferences(context, STORE_NAME).then((store: preferences.Preferences): Promise<void> => {
      return store.put(KEY_ICONS, json).then((): Promise<void> => {
        return store.flush();
      });
    }).catch((): void => {
    });
  }, SAVE_DEBOUNCE_MS);
}

export class ExtIconCache {
  /** 启动时把上次的缓存捞进内存（进面板调一次；重复调用忽略）。 */
  static async hydrate(context: common.Context | undefined): Promise<void> {
    if (loaded || !context) {
      return;
    }
    try {
      const store = await preferences.getPreferences(context, STORE_NAME);
      const raw = String(await store.get(KEY_ICONS, ''));
      if (raw.length > 0) {
        const entries = JSON.parse(raw) as Array<[string, string]>;
        for (const entry of entries) {
          const id = String(entry[0] ?? '');
          const icon = String(entry[1] ?? '');
          if (id.length > 0 && icon.length > 0) {
            cache.set(id, icon);
          }
        }
      }
    } catch (error) {
    }
    loaded = true;
  }

  /** 取缓存图标（'' = 没存过）。 */
  static get(id: string): string {
    const icon = cache.get(id);
    return icon !== undefined ? icon : '';
  }

  /** 引擎回包里见到非空图标就记一笔（幂等；超上限淘汰最早存的）。 */
  static put(id: string, icon: string, context: common.Context | undefined): void {
    if (id.length === 0 || icon.length === 0) {
      return;
    }
    const prev = cache.get(id);
    if (prev !== undefined && prev === icon) {
      return;
    }
    cache.delete(id); // 重新插入到尾部 = 最近使用
    cache.set(id, icon);
    while (cache.size > MAX_ENTRIES) {
      const oldest = cache.keys().next();
      if (oldest.done === true) {
        break;
      }
      cache.delete(oldest.value);
    }
    persist(context);
  }
}

/*
 * 标签页缩略图的磁盘缓存。
 *
 * 为什么要它：引擎的缩略图只存在内存里，进程一死就空；会话恢复出来的标签
 * 是 discarded（页面不在内存），壳层没有图可画，只能盖一层「已休眠」——
 * 打开标签页网格时满屏占位，看不出每个标签是什么。
 *
 * 键用**页面 URL** 而不是标签 id：恢复后标签会拿到新的 id，URL 才是稳定键。
 * 同一 URL 的多个标签共用一张图，显示的可能是上一次的样子——比一片占位好。
 *
 * 存储格式：直接把 pngBase64 写成文本（.b64）。缩略图只有几十 KB，文本省掉
 * 一层 ArrayBuffer 转换，失败面更小。目录里超过 MAX_FILES 张时按修改时间
 * 删最旧的。任何读写失败都当作「没有缓存」，绝不影响正常路径。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

const DIR_NAME: string = 'tab-thumbnails';
const MAX_FILES: number = 80;

function cacheDir(context: common.Context | undefined): string {
  if (!context || context.filesDir.length === 0) {
    return '';
  }
  return `${context.filesDir}/${DIR_NAME}`;
}

// FNV-1a 32 位：URL 里可能有任意字符，不能直接当文件名。
function keyOf(url: string): string {
  let hash: number = 0x811c9dc5;
  for (let i = 0; i < url.length; i++) {
    hash = (hash ^ url.charCodeAt(i)) >>> 0;
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(16).padStart(8, '0');
}

function cachePath(context: common.Context | undefined, url: string): string {
  const dir = cacheDir(context);
  if (dir.length === 0 || url.length === 0) {
    return '';
  }
  return `${dir}/${keyOf(url)}.b64`;
}

interface ThumbFile {
  name: string;
  mtime: number;
}

export class TabThumbnailStore {
  // 返回可直接给 Image 的 data URL；没有缓存时返回空串。
  static load(context: common.Context | undefined, url: string): string {
    const path = cachePath(context, url);
    if (path.length === 0) {
      return '';
    }
    try {
      if (!fs.accessSync(path)) {
        return '';
      }
      const base64 = fs.readTextSync(path);
      return base64.length > 0 ? `data:image/png;base64,${base64}` : '';
    } catch (error) {
      return '';
    }
  }

  static save(context: common.Context | undefined, url: string, pngBase64: string): void {
    const path = cachePath(context, url);
    if (path.length === 0 || pngBase64.length === 0) {
      return;
    }
    try {
      const dir = cacheDir(context);
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
      // 同一张图不重复写：面板每打开一次都会重新请求缩略图。
      if (fs.accessSync(path)) {
        const old = fs.readTextSync(path);
        if (old === pngBase64) {
          return;
        }
      }
      const file = fs.openSync(path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, pngBase64);
      fs.closeSync(file);
    } catch (error) {
    }
  }

  // 目录里文件太多时按修改时间删最旧的，避免无限增长。
  static prune(context: common.Context | undefined): void {
    const dir = cacheDir(context);
    if (dir.length === 0) {
      return;
    }
    try {
      if (!fs.accessSync(dir)) {
        return;
      }
      const names: string[] = fs.listFileSync(dir);
      if (names.length <= MAX_FILES) {
        return;
      }
      const entries: ThumbFile[] = [];
      for (const name of names) {
        try {
          const info = fs.statSync(`${dir}/${name}`);
          entries.push({ name: name, mtime: info.mtime });
        } catch (error) {
        }
      }
      entries.sort((a: ThumbFile, b: ThumbFile): number => a.mtime - b.mtime);
      const extra: number = entries.length - MAX_FILES;
      for (let i = 0; i < extra; i++) {
        try {
          fs.unlinkSync(`${dir}/${entries[i].name}`);
        } catch (error) {
        }
      }
    } catch (error) {
    }
  }
}

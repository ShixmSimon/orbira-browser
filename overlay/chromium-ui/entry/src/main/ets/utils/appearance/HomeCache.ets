/*
 * 主页磁贴冷启动缓存。
 *
 * 为什么不用 preferences：favicon 的 base64 很容易把单条 value 顶过 8192 字节
 * 上限（ArkTS preferences 的 string value 有长度限制），所以走沙箱文件。
 *
 * 用途（用户报「浏览器冷启动书签加载慢」）：冷启动第一帧就把上次的书签与图标
 * 画出来，不必干等引擎回包；回包到达后覆盖写入。纯加速——任何读取失败都当作
 * "没有缓存"，绝不影响正常路径。
 *
 * 数据格式：tilesJson 直接存 BookmarkNode[]（含子文件夹的全量子节点，与
 * HomeSurface.fullNodes 一致，排序换算也能用）；faviconsJson 存引擎
 * getFavicons 回包的原始 items（[{url, pngBase64}]）。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';

const FILE_NAME: string = 'home_cache.json';

export interface HomeCacheData {
  tilesJson: string;
  faviconsJson: string;
  // 写入这份 favicon 时的请求尺寸（vp）。与当前显示尺寸不一致就丢弃图标缓存
  // —— 尺寸变了旧图会被放大显示，宁可不显示（等引擎重新生成）。
  faviconSizeVp: number;
}

function emptyCache(): HomeCacheData {
  return { tilesJson: '', faviconsJson: '', faviconSizeVp: 0 };
}

export class HomeCache {
  private static filePath(context: common.Context | undefined): string {
    if (!context || context.filesDir.length === 0) {
      return '';
    }
    return `${context.filesDir}/${FILE_NAME}`;
  }

  static load(context: common.Context | undefined): HomeCacheData {
    const out = emptyCache();
    const path = HomeCache.filePath(context);
    if (path.length === 0) {
      return out;
    }
    try {
      if (!fs.accessSync(path)) {
        return out;
      }
      const raw = fs.readTextSync(path);
      if (raw.length === 0) {
        return out;
      }
      const parsed = JSON.parse(raw) as HomeCacheData;
      out.tilesJson = typeof parsed.tilesJson === 'string' ? parsed.tilesJson : '';
      out.faviconsJson = typeof parsed.faviconsJson === 'string' ? parsed.faviconsJson : '';
      out.faviconSizeVp = typeof parsed.faviconSizeVp === 'number' ? parsed.faviconSizeVp : 0;
      return out;
    } catch (error) {
      return out;
    }
  }

  static save(context: common.Context | undefined, data: HomeCacheData): void {
    const path = HomeCache.filePath(context);
    if (path.length === 0) {
      return;
    }
    try {
      const file = fs.openSync(path,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(data));
      fs.closeSync(file);
    } catch (error) {
    }
  }
}

/*
 * 手机下载页（对齐 Lumie v2：卡片式列表）。
 * 数据流：listDownloads -> downloadList 事件（AuraShell 转存到
 * 'auraPanelDownloads'）；进度由 downloadUpdated 事件驱动（AuraShell 转存到
 * 'auraPanelDownloadsTick'），本页做节流重拉，避免每秒多次刷新。
 * 动作：行内动作芯片（暂停/继续/取消/重试/危险确认/复制链接/安装 crx），
 * 点已完成的行交给系统打开文件。
 */
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BrowserCommandPayload, DownloadAction, DownloadItem, openDownloadedFile } from 'engine';
import { formatVisitTime } from './PanelBridge';
import { AuraSectionLabel } from './LumieKit';
import { GlassPage, glassHeaderInsetVp } from './GlassPage';

interface PanelEventPayload {
  kind?: string;
  message?: string;
}

function formatBytes(bytes: number): string {
  if (bytes <= 0) {
    return '';
  }
  const units: string[] = ['B', 'KB', 'MB', 'GB'];
  let value: number = bytes;
  let unit: number = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value = value / 1024;
    unit += 1;
  }
  if (unit === 0) {
    return `${Math.round(value)} ${units[unit]}`;
  }
  return `${value.toFixed(1)} ${units[unit]}`;
}

function isCrxFile(item: DownloadItem): boolean {
  return item.fileName.toLowerCase().endsWith('.crx');
}

@Component
export struct DownloadsPanel {
  @StorageLink('auraPanelDownloads') @Watch('onDownloadsPayload') downloadsJson: string = '';
  @StorageLink('auraPanelDownloadsTick') @Watch('onDownloadsTick') downloadsTick: number = 0;
  @StorageLink('auraPanelEvent') @Watch('onPanelEvent') panelEventJson: string = '';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onBack: () => void = (): void => {};
  onClose: () => void = (): void => {};

  @State private items: DownloadItem[] = [];
  @State private loading: boolean = true;
  // 渐变模糊滚动效果按官方要求 bindToScrollable。
  private listScroller: Scroller = new Scroller();
  private requestSeq: number = 0;
  private retryTimer: number = -1;
  private lastReloadAt: number = 0;

  aboutToAppear(): void {
    // Seed from storage first: a @StorageLink does not fire @Watch for its
    // initial value, and a byte-identical engine reply raises no change
    // either, so a re-opened panel would otherwise stay on "loading".
    this.onDownloadsPayload();
    this.reload();
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      if (this.loading) {
        this.reload();
      }
    }, 1500);
  }

  aboutToDisappear(): void {
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  private reload(): void {
    this.loading = true;
    this.requestSeq += 1;
    this.lastReloadAt = Date.now();
    this.onCommand({ command: 'listDownloads', requestId: this.requestSeq });
  }

  private onDownloadsPayload(): void {
    if (this.downloadsJson.length === 0) {
      return;
    }
    try {
      this.items = JSON.parse(this.downloadsJson) as DownloadItem[];
      this.loading = false;
    } catch (error) {
      this.loading = false;
    }
  }

  private onDownloadsTick(): void {
    // Progress arrives several times a second per item; one reload is enough.
    if (Date.now() - this.lastReloadAt < 1200) {
      return;
    }
    this.reload();
  }

  private onPanelEvent(): void {
    if (this.panelEventJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.panelEventJson) as PanelEventPayload;
      if (String(payload.kind ?? '') === 'extensionInstallFailed') {
        const message = String(payload.message ?? '');
        AlertDialog.show({
          title: '安装失败',
          message: message.length > 0 ? message : '没能安装这个扩展程序。',
          confirm: {
            value: '好的',
            action: (): void => {
            }
          }
        });
      }
    } catch (error) {
    }
  }

  private act(item: DownloadItem, action: DownloadAction): void {
    this.onCommand({ command: 'downloadAction', id: item.id, action: action });
    setTimeout((): void => {
      this.reload();
    }, 400);
  }

  private confirmRemove(item: DownloadItem): void {
    const name = item.fileName.length > 0 ? item.fileName : item.url;
    AlertDialog.show({
      title: '删除下载',
      message: `「${name}」的记录和文件都会被删除。`,
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '删除',
        fontColor: '#E24B4A',
        action: (): void => {
          this.onCommand({ command: 'downloadAction', id: item.id, action: 'removeAndDeleteFile' });
          setTimeout((): void => {
            this.reload();
          }, 400);
        }
      }
    });
  }

  private copyLink(item: DownloadItem): void {
    if (item.url.length === 0) {
      return;
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, item.url);
      pasteboard.getSystemPasteboard().setData(data);
      this.getUIContext().getPromptAction().showToast({
        message: '已复制链接',
        duration: 1500
      });
    } catch (error) {
    }
  }

  private openItem(item: DownloadItem): void {
    if (item.state !== 'completed' || item.fileMissing === true || item.filePath.length === 0) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    openDownloadedFile(context, item.filePath, item.mimeType);
  }

  private installCrx(item: DownloadItem): void {
    if (item.filePath.length === 0) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    try {
      const source = fs.openSync(item.filePath, fs.OpenMode.READ_ONLY);
      const destPath = `${context.filesDir}/imported-extension.crx`;
      fs.copyFileSync(source.fd, destPath);
      fs.closeSync(source);
      this.onCommand({ command: 'installExtensionFromFile', path: destPath });
    } catch (error) {
      AlertDialog.show({
        title: '无法读取',
        message: '无法读取这个扩展程序安装包。',
        confirm: {
          value: '好的',
          action: (): void => {
          }
        }
      });
    }
  }

  private subtitle(item: DownloadItem): string {
    let state = '下载中';
    if (item.dangerous) {
      state = '可能有害，等待确认';
    } else if (item.state === 'paused') {
      state = '已暂停';
    } else if (item.state === 'completed') {
      // The engine reports a finished download whose file has gone from the
      // disk (field added in build-443425d6; older engines never set it).
      state = item.fileMissing === true ? '文件已不在原位置，可重新下载' : '已完成';
    } else if (item.state === 'cancelled') {
      state = '已取消';
    } else if (item.state === 'failed') {
      state = '下载失败，可重试';
    }
    let line = state;
    const size = formatBytes(item.state === 'inProgress' ? item.receivedBytes : item.totalBytes);
    if (size.length > 0) {
      line = `${line} · ${size}`;
    }
    const stamp = item.endTime > 0 ? item.endTime : item.startTime;
    const time = formatVisitTime(stamp);
    if (time.length > 0) {
      line = `${line} · ${time}`;
    }
    return line;
  }

  private showProgress(item: DownloadItem): boolean {
    return (item.state === 'inProgress' || item.state === 'paused') && item.totalBytes > 0;
  }

  private progressValue(item: DownloadItem): number {
    if (item.totalBytes <= 0) {
      return 0;
    }
    return Math.max(0, Math.min(100, Math.round(item.receivedBytes * 100 / item.totalBytes)));
  }

  @Builder
  private ActionChip(label: string, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor($r('app.color.accent_primary'))
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(8)
      .backgroundColor($r('app.color.surface_secondary'))
      .onClick(action)
  }

  @Builder
  private DangerChip(label: string, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor($r('app.color.danger'))
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(8)
      .backgroundColor($r('app.color.surface_secondary'))
      .onClick(action)
  }

  @Builder
  private DownloadRow(item: DownloadItem, index: number) {
    Column() {
      Column({ space: 4 }) {
        Row({ space: 12 }) {
          Image($r('app.media.aura_download'))
            .width(22)
            .height(22)
            .fillColor($r('app.color.icon_primary'))

          Column({ space: 2 }) {
            Text(item.fileName.length > 0 ? item.fileName : item.url)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(this.subtitle(item))
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .onClick(() => {
          this.openItem(item);
        })

        if (this.showProgress(item)) {
          Progress({ value: this.progressValue(item), total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(6)
        }

        Row({ space: 6 }) {
          Blank()
          if (item.dangerous) {
            this.ActionChip('保留', (): void => this.act(item, 'keepDangerous'))
            this.DangerChip('丢弃', (): void => this.act(item, 'discardDangerous'))
          } else if (item.state === 'inProgress') {
            this.ActionChip('暂停', (): void => this.act(item, 'pause'))
            this.DangerChip('取消', (): void => this.act(item, 'cancel'))
          } else if (item.state === 'paused') {
            this.ActionChip('继续', (): void => this.act(item, 'resume'))
            this.DangerChip('取消', (): void => this.act(item, 'cancel'))
          } else if (item.state === 'completed') {
            // A complete row whose file is gone: retry fetches the URL again and
            // the old record goes away on its own (SHELL_CONTRACT.md, 下载).
            if (item.fileMissing === true) {
              this.ActionChip('重新下载', (): void => this.act(item, 'retry'))
            } else if (isCrxFile(item)) {
              this.ActionChip('安装', (): void => this.installCrx(item))
            }
            this.ActionChip('复制链接', (): void => this.copyLink(item))
            this.DangerChip('删除', (): void => this.confirmRemove(item))
          } else {
            this.ActionChip('重试', (): void => this.act(item, 'retry'))
            this.ActionChip('复制链接', (): void => this.copyLink(item))
            this.DangerChip('删除', (): void => this.confirmRemove(item))
          }
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: 16, right: 12, top: 12, bottom: 12 })

      if (index < this.items.length - 1) {
        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 50 })
      }
    }
    .width('100%')
  }

  build() {
    // 标题栏交给 GlassPage（落在 Navigation 标题栏里 —— HarmonyOS 7 之后
    // 只有这块区域 + 弹窗类还在沉浸光感的生效范围内）。
    GlassPage({ title: '下载', scrollers: [this.listScroller], onBack: (): void => { this.onBack(); } }) {
    Column() {
      if (this.items.length === 0) {
        Column() {
          Text(this.loading ? '加载中…' : '暂无下载')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll(this.listScroller) {
          Column() {
            AuraSectionLabel({ text: '下载记录', tightTop: true })

            Column() {
              ForEach(this.items, (item: DownloadItem, index: number) => {
                this.DownloadRow(item, index)
              }, (item: DownloadItem): string => item.id)
            }
            .width('100%')
            .borderRadius(16)
            .backgroundColor($r('app.color.card_background'))
            .clip(true)

            Text('已完成的行点一下可以交给其它应用打开。')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 4, right: 4, top: 10 })
          }
          .width('100%')
          // 大标题带：滚动内容穿过「下载」大标题时逐渐虚化（见 GlassPage 文件头）。
          .padding({ top: glassHeaderInsetVp() })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        // Scroll centers content shorter than the viewport by default (the
        // universal `align` attribute defaults to Alignment.Center), which
        // showed up as a big gap under the header. Pin it to the top.
        .align(Alignment.TopStart)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.page_background'))
    }
  }
}

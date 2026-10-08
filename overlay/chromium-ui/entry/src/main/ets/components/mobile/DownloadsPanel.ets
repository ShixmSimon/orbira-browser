/*
 * 手机下载页（参考外壳扩展）。
 * 数据流：listDownloads -> downloadList 事件（AuraShell 转存到
 * 'auraPanelDownloads'）；进度由 downloadUpdated 事件驱动（AuraShell 转存到
 * 'auraPanelDownloadsTick'），本页做节流重拉，避免每秒多次刷新。
 */
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { BrowserCommandPayload, DownloadAction, DownloadItem } from 'engine';
import { formatVisitTime } from './PanelBridge';

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
      state = '已完成';
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
      .backgroundColor($r('app.color.surface_primary'))
      .onClick(action)
  }

  @Builder
  private DangerChip(label: string, action: () => void) {
    Text(label)
      .fontSize(13)
      .fontColor('#E24B4A')
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(8)
      .backgroundColor($r('app.color.surface_primary'))
      .onClick(action)
  }

  @Builder
  private DownloadRow(item: DownloadItem) {
    Row({ space: 10 }) {
      Column({ space: 4 }) {
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
        if (this.showProgress(item)) {
          Progress({ value: this.progressValue(item), total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(6)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Row({ space: 6 }) {
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
          if (isCrxFile(item)) {
            this.ActionChip('安装', (): void => this.installCrx(item))
          }
          this.DangerChip('删除', (): void => this.confirmRemove(item))
        } else {
          this.ActionChip('重试', (): void => this.act(item, 'retry'))
          this.DangerChip('删除', (): void => this.confirmRemove(item))
        }
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  build() {
    Column() {
      Row() {
        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.chromium_back'))
            .width(22)
            .height(22)
            .fillColor($r('app.color.icon_primary'))
        }
        .width(44)
        .height(44)
        .backgroundColor($r('app.color.surface_secondary'))
        .accessibilityText('返回')
        .onClick(() => {
          this.onBack();
        })

        Text('下载')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 12 })

        Blank()
      }
      .width('100%')
      .height(52)

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
        Scroll() {
          Column() {
            ForEach(this.items, (item: DownloadItem, index: number) => {
              Column() {
                this.DownloadRow(item)
                if (index < this.items.length - 1) {
                  Divider()
                    .color($r('app.color.divider'))
                }
              }
              .width('100%')
            }, (item: DownloadItem): string => item.id)
          }
          .width('100%')
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
    .padding({ left: 20, right: 20, bottom: 16 })
    .backgroundColor($r('app.color.surface_primary'))
  }
}

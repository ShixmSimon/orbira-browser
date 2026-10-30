/*
 * 手机下载页（卡片式列表）。
 * 数据流：listDownloads -> downloadList 事件（AuraShell 转存到
 * 'auraPanelDownloads'）；进度由 downloadUpdated 事件驱动（AuraShell 转存到
 * 'auraPanelDownloadsTick'），本页做节流重拉，避免每秒多次刷新。
 * 动作：行内动作芯片（暂停/继续/取消/重试/危险确认/复制链接/安装 crx），
 * 点已完成的行交给系统打开文件。
 */
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BrowserCommandPayload, DownloadAction, DownloadItem, DownloadState, openDownloadedFile } from 'engine';
import { formatVisitTime } from './PanelBridge';
import { AuraSectionLabel, AuraSearchBar } from './AuraKit';
import { GlassPage, glassHeaderInsetVp } from './GlassPage';
import { curves } from '@kit.ArkUI';

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
  // 乐观状态重放表：引擎回包滞后时用它压住陈旧状态（onDownloadsPayload 重放，
  // 引擎确认到该状态即解除），避免「点了没反应、要返回重进才变」。
  private pendingStates: Map<string, DownloadState> = new Map<string, DownloadState>();
  @State private loading: boolean = true;
  // 渐变模糊滚动效果按官方要求 bindToScrollable。
  private listScroller: Scroller = new Scroller();
  @State private searchText: string = '';
  // 搜索框随列表滚走后，标题栏右侧浮现搜索按钮（点它回顶 + 聚焦）。
  @State private searchFabVisible: boolean = false;

  // 搜索框滚走后，点标题栏搜索按钮平滑回顶并聚焦搜索框。
  // 聚焦必须延迟到回顶动画结束之后：requestFocus 唤起输入法会触发重布局，
  // 打断进行中的回顶弹簧动画 —— 实测列表停在半路，搜索框压在视口上方露不出来。
  private scrollToSearch(): void {
    this.listScroller.scrollTo({
      xOffset: 0,
      yOffset: 0,
      animation: { duration: 320, curve: curves.springMotion(0.34, 0.84) }
    });
    setTimeout((): void => {
      this.getUIContext().getFocusController().requestFocus('downloads_search_input');
    }, 480);
  }
  // 过滤结果落 @State（同 HistoryPanel：方法间接读 @State 不建立更新依赖）。
  @State private filteredDownloads: DownloadItem[] = [];
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
      const raw = JSON.parse(this.downloadsJson) as DownloadItem[];
      // 重放乐观更新压住滞后回包；引擎确认到该状态即解除。
      for (const it of raw) {
        const pid: string = String(it.id);
        const p: DownloadState | undefined = this.pendingStates.get(pid);
        if (p !== undefined) {
          if (it.state === p) {
            this.pendingStates.delete(pid);
          } else {
            it.state = p;
          }
        }
      }
      this.items = raw;
      this.recomputeFiltered();
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
    // 诊断日志：无此行=点击没到芯片；有此行但引擎无反应=引擎侧处理失败。
    hilog.info(0x0000, 'Downloads', 'action=%{public}s id=%{public}s',
      action, String(item.id));
    this.onCommand({ command: 'downloadAction', id: String(item.id), action: action });
    // 记录乐观状态，防 400ms 后的 reload 打回陈旧回包。
    const expected: DownloadState | undefined = this.expectedStateFor(action);
    if (expected !== undefined) {
      this.pendingStates.set(String(item.id), expected);
    }
    // 乐观更新：立即反馈，不等引擎回包。
    this.applyOptimisticState(item, action);
    setTimeout((): void => {
      this.reload();
    }, 400);
  }

  // 动作对应的预期状态；undefined=无确定终态（remove），无需重放。
  private expectedStateFor(action: DownloadAction): DownloadState | undefined {
    if (action === 'pause') {
      return 'paused';
    }
    if (action === 'resume' || action === 'retry') {
      return 'inProgress';
    }
    if (action === 'cancel') {
      return 'cancelled';
    }
    return undefined;
  }

  // 逐字段拷贝返回新对象（ArkTS 禁 ... 展开 / Object.assign）。ForEach 行内
  // @Builder 挂载后定死，必须换对象引用才会触发该行重渲染。
  private withState(it: DownloadItem, state: DownloadState): DownloadItem {
    return {
      id: it.id,
      url: it.url,
      fileName: it.fileName,
      filePath: it.filePath,
      mimeType: it.mimeType,
      receivedBytes: it.receivedBytes,
      totalBytes: it.totalBytes,
      state: state,
      failReason: it.failReason,
      canResume: it.canResume,
      fileMissing: it.fileMissing,
      dangerous: it.dangerous,
      dangerType: it.dangerType,
      startTime: it.startTime,
      endTime: it.endTime,
      removed: it.removed
    };
  }

  // 点击后立刻把该项状态翻到预期值（map 产出新引用，见 withState）。
  private applyOptimisticState(item: DownloadItem, action: DownloadAction): void {
    const targetId: string = String(item.id);
    let next: DownloadState | undefined = undefined;
    if (action === 'pause') {
      next = 'paused';
    } else if (action === 'resume' || action === 'retry') {
      next = 'inProgress';
    } else if (action === 'cancel') {
      next = 'cancelled';
    } else {
      return;
    }
    const updated: DownloadItem[] = this.items.map((it: DownloadItem): DownloadItem => {
      if (String(it.id) === targetId) {
        return this.withState(it, next as DownloadState);
      }
      return it;
    });
    this.items = updated;
    this.recomputeFiltered();
  }

  private confirmRemove(item: DownloadItem): void {
    const name = item.fileName.length > 0 ? item.fileName : item.url;
    // 删除拆成两个语义：仅删记录（保留本机文件）与删记录并文件。
    // 引擎侧两个 action 均已实现（RemoveDownload / RemoveDownloadAndFile）。
    AlertDialog.show({
      title: '删除下载',
      message: `「${name}」\n· 仅删除记录：保留本机文件\n· 删除记录并文件：同时删除本机文件`,
      autoCancel: true,
      primaryButton: {
        value: '仅删除记录',
        action: (): void => {
          this.onCommand({ command: 'downloadAction', id: String(item.id), action: 'remove' });
          setTimeout((): void => {
            this.reload();
          }, 400);
        }
      },
      secondaryButton: {
        value: '删除记录并文件',
        fontColor: '#E24B4A',
        action: (): void => {
          this.onCommand({ command: 'downloadAction', id: String(item.id), action: 'removeAndDeleteFile' });
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
    // 1.0.243：点按反馈——打不开时说明原因。此前守卫全部静默 return，
    // 用户点到「还在下载 / 已暂停 / 文件丢失」的条目像点了没反应
    // （装机反馈「点击下载没有弹窗提醒」）。下载中/完成态的系统通知
    // 由 DownloadNotifier 负责，这里补的是面板内点按的即时反馈。
    if (item.state === 'inProgress' || item.state === 'paused') {
      this.getUIContext().getPromptAction().showToast({
        message: item.state === 'paused' ? '下载已暂停，继续后才能打开' : '还在下载中，下载完成后才能打开',
        duration: 2000
      });
      return;
    }
    if (item.state !== 'completed') {
      this.getUIContext().getPromptAction().showToast({
        message: '这个下载没有成功，可以重试',
        duration: 2000
      });
      return;
    }
    if (item.fileMissing === true || item.filePath.length === 0) {
      this.getUIContext().getPromptAction().showToast({
        message: '文件已不在原位置，可以重新下载',
        duration: 2000
      });
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
      // 安装确认框由引擎画在活动标签页 web 层、位于外壳浮层之下，须关面板
      // 露出网页（见 ExtensionPanel.installFromFile）。.zip 解压安装无确认框。
      const isZip: boolean = !isCrxFile(item);
      this.getUIContext().getPromptAction().showToast({
        message: isZip ? '正在安装扩展…' : '请在弹出的窗口中确认安装',
        duration: 3000
      });
      this.onClose();
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

  // 1.0.2：文件名拆主名/扩展名（见 DownloadRow 用法）——主名参与省略，
  // 扩展名常驻，截断后仍可分辨 zip / crx / apk。
  private downloadNameBase(name: string): string {
    const dot: number = name.lastIndexOf('.');
    if (dot <= 0 || dot === name.length - 1) {
      return name;
    }
    return name.substring(0, dot);
  }

  private downloadNameExt(name: string): string {
    const dot: number = name.lastIndexOf('.');
    if (dot <= 0 || dot === name.length - 1) {
      return '';
    }
    return name.substring(dot);
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
            // 1.0.2：文件名拆「主名 + 扩展名」两个 Text——主名才参与省略，
            // 扩展名常驻。此前整条省略会把 'scriptcat-v1.5.0-chrome.zip'
            // 截成 'scriptcat-v1.5.0-…'，看不出是 zip 还是 crx（装机反馈）。
            Row({ space: 0 }) {
              Text(this.downloadNameBase(item.fileName.length > 0 ? item.fileName : item.url))
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.downloadNameExt(item.fileName.length > 0 ? item.fileName : item.url))
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
                .maxLines(1)
            }
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

      // 分隔线按「过滤后列表」判断：搜索过滤时最后一条不应再画 Divider。
      if (index < this.filteredDownloads.length - 1) {
        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 50 })
      }
    }
    .width('100%')
  }

  // 重算过滤结果（写入 @State）：搜索词变化与数据源变化处都要调用。
  private recomputeFiltered(): void {
    const q = this.searchText.trim().toLowerCase();
    if (q.length === 0) {
      this.filteredDownloads = this.items;
      return;
    }
    const out: DownloadItem[] = [];
    for (const item of this.items) {
      if (item.fileName.toLowerCase().includes(q) || item.url.toLowerCase().includes(q)) {
        out.push(item);
      }
    }
    this.filteredDownloads = out;
  }

    build() {
    // 标题栏交给 GlassPage（落在 Navigation 标题栏里 —— HarmonyOS 7 之后
    // 只有这块区域 + 弹窗类还在沉浸光感的生效范围内）。
    GlassPage({ title: '下载', scrollers: [this.listScroller], menus: this.searchFabVisible ? { value: [{ content: { icon: $r('app.media.chromium_search'), label: '回到搜索', action: (): void => { this.scrollToSearch(); } } }] } : undefined, onBack: (): void => { this.onBack(); } }) {
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
            AuraSearchBar({
              placeholder: '搜索下载记录',
              text: this.searchText,
              showClear: true,
              inputId: 'downloads_search_input',
              onInput: (value: string): void => {
                this.searchText = value;
                this.recomputeFiltered();
              },
              onClear: (): void => {
                this.searchText = '';
                this.recomputeFiltered();
              }
            })
              .margin({ bottom: 10 })

            if (this.filteredDownloads.length === 0) {
              Text('没有匹配的下载记录')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .margin({ top: 40 })
            }
            Column() {
              ForEach(this.filteredDownloads, (item: DownloadItem, index: number) => {
                this.DownloadRow(item, index)
              }, (item: DownloadItem): string => {
                // key 须含影响行 UI 的全部字段：key 不变则 ForEach 复用已挂载
                // 节点不重建（@Builder 按值参数挂载时定死），状态变化到不了 UI。
                return `${item.id}|${item.state}|${item.receivedBytes}|${item.dangerous ? 1 : 0}|${item.fileMissing ? 1 : 0}`;
              })
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
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        // Scroll centers content shorter than the viewport by default (the
        // universal `align` attribute defaults to Alignment.Center), which
        // showed up as a big gap under the header. Pin it to the top.
        .align(Alignment.TopStart)
        .onDidScroll(() => {
          // 搜索框随列表滚走后，标题栏右侧浮现搜索按钮（点它回顶 + 聚焦）。
          const off = this.listScroller.currentOffset().yOffset;
          const show = off > glassHeaderInsetVp() + 20;
          if (show !== this.searchFabVisible) {
            this.searchFabVisible = show;
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.page_background'))
    }
  }
}

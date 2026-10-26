/**
 * 设置 → 广告拦截。
 *
 * 数据通道：AuraShell.handleRuntimeEvent() 把引擎的 adBlockState /
 * adBlockConfigResult / adBlockStateChanged 事件原样写进
 * AppStorage['auraPanelAdBlock']，本组件解析后渲染。
 *
 * 写命令必须带 contextId + expectedRevision —— 引擎 Service::CheckRevision()
 * 会校验这两项，不带或过期一律回 reason='stale'。这里收到 stale 时先重拉状态，
 * 拿到新 revision 后把刚才那次写操作自动重放一次（否则用户会看到"点了没反应"）。
 */
import { BrowserCommandPayload } from 'engine';
import { glassBottomInsetVp, glassHeaderInsetVp } from './GlassPage';
import { AdBlockSource, AdBlockStateEvent } from 'engine';

@Component
export struct AdBlockPanel {
  @StorageLink('auraPanelAdBlock') @Watch('onPayload') payloadJson: string = '';
  // 不能叫 enabled：CustomComponent 自带 .enabled() 通用属性，同名会被判成
  // 覆盖基类签名（ArkTS 10505001）。
  @State private adBlockOn: boolean = false;
  @State private autoUpdate: boolean = true;
  @State private ready: boolean = false;
  @State private updating: boolean = false;
  @State private sources: AdBlockSource[] = [];
  @State private statusLine: string = '正在读取规则…';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};

  private contextId: string = '';
  private revision: number = 0;
  private requestSeq: number = 0;
  // 上一次写命令：只在 stale 重试时用，成功回包后清空。
  private pendingWrite: BrowserCommandPayload | null = null;
  private retryPending: boolean = false;
  // 更新请求的兜底定时器：引擎若因为初始化失败/网络卡住不回包，不能让按钮
  // 永远停在「正在更新…」（1.0.3 用户实测）。
  private updateTimer: number = -1;

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    this.requestSeq += 1;
    this.onCommand({ command: 'getAdBlockState', requestId: this.requestSeq });
  }

  private onPayload(): void {
    if (this.payloadJson.length === 0) {
      return;
    }
    let payload: AdBlockStateEvent | null = null;
    try {
      payload = JSON.parse(this.payloadJson) as AdBlockStateEvent;
    } catch (error) {
      return;
    }
    if (payload === null) {
      return;
    }
    this.apply(payload);
  }

  private reasonText(reason: string): string {
    if (reason === 'readOnly') {
      return '无痕模式下不能修改';
    }
    if (reason === 'initializing') {
      return '引擎还没准备好，稍后再试';
    }
    if (reason === 'busy') {
      return '规则正在更新，稍后再试';
    }
    if (reason === 'invalidSource') {
      return '规则源无效';
    }
    if (reason === 'limit') {
      return '规则源数量已达上限';
    }
    if (reason.length > 0) {
      return '操作失败（' + reason + '）';
    }
    return '';
  }

  private apply(payload: AdBlockStateEvent): void {
    const reason: string = payload.reason !== undefined ? payload.reason : '';
    if (reason === 'stale') {
      // 修订号过期：重拉状态，拿到新 revision 后重放刚才那次写。
      this.retryPending = this.pendingWrite !== null;
      this.refresh();
      return;
    }

    if (payload.contextId !== undefined) {
      this.contextId = payload.contextId;
    }
    if (payload.revision !== undefined) {
      this.revision = payload.revision;
    }
    if (payload.enabled !== undefined) {
      this.adBlockOn = payload.enabled;
    }
    if (payload.autoUpdate !== undefined) {
      this.autoUpdate = payload.autoUpdate;
    }
    if (payload.ready !== undefined) {
      this.ready = payload.ready;
    }
    if (payload.updating !== undefined) {
      this.updating = payload.updating;
    } else if (reason.length > 0 || payload.ok === true) {
      // 回包不带 updating（多数写命令的回包都不带）→ 本次操作已结束。
      this.updating = false;
    }
    if (payload.sources !== undefined) {
      this.sources = payload.sources;
    }

    let rules: number = 0;
    let missing: number = 0;
    for (let i = 0; i < this.sources.length; i++) {
      const count: number | undefined = this.sources[i].ruleCount;
      if (count !== undefined && count > 0) {
        rules += count;
      }
      const rawStatus: string | undefined = this.sources[i].status;
      const status: string = rawStatus !== undefined ? rawStatus : '';
      if (status !== 'ready' && this.sources[i].enabled) {
        missing += 1;
      }
    }
    let line: string = this.ready ? '引擎就绪' : '引擎准备中';
    line = line + ' · 已载入 ' + rules.toString() + ' 条规则';
    if (this.updating) {
      line = line + ' · 正在更新';
    } else if (missing > 0) {
      line = line + ' · ' + missing.toString() + ' 个源待更新';
    }
    const failure: string = this.reasonText(reason);
    this.statusLine = failure.length > 0 ? failure : line;

    // stale 之后的重放：用刚拿到的新 revision 把同一个写命令再发一次。
    if (this.retryPending && this.pendingWrite !== null) {
      this.retryPending = false;
      const again: BrowserCommandPayload = this.pendingWrite;
      again.contextId = this.contextId;
      again.expectedRevision = this.revision;
      this.onCommand(again);
      return;
    }
    this.pendingWrite = null;
  }

  private write(command: string): BrowserCommandPayload {
    const payload: BrowserCommandPayload = {
      command: command,
      contextId: this.contextId,
      expectedRevision: this.revision
    };
    return payload;
  }

  private send(payload: BrowserCommandPayload): void {
    this.pendingWrite = payload;
    this.onCommand(payload);
  }

  private setEnabled(next: boolean): void {
    this.adBlockOn = next;
    const payload: BrowserCommandPayload = this.write('setAdBlockEnabled');
    payload.enabled = next;
    this.send(payload);
  }

  private setAutoUpdate(next: boolean): void {
    this.autoUpdate = next;
    const payload: BrowserCommandPayload = this.write('setAdBlockAutoUpdate');
    payload.enabled = next;
    this.send(payload);
  }

  private setSource(id: string, next: boolean): void {
    const payload: BrowserCommandPayload = this.write('setAdBlockSourceEnabled');
    payload.sourceId = id;
    payload.enabled = next;
    this.send(payload);
  }

  private updateSources(): void {
    this.updating = true;
    this.statusLine = '正在下载并编译规则…';
    const payload: BrowserCommandPayload = this.write('updateAdBlockSources');
    this.send(payload);
    if (this.updateTimer !== -1) {
      clearTimeout(this.updateTimer);
    }
    this.updateTimer = setTimeout((): void => {
      this.updateTimer = -1;
      if (this.updating) {
        this.updating = false;
        this.statusLine = '引擎没有回包：可能是初始化未完成，稍后重试';
      }
    }, 15000);
  }

  private sourceSubtitle(item: AdBlockSource): string {
    const kind: string = item.kind;
    let head: string = '内置规则';
    if (kind === 'subscription') {
      head = '订阅';
    } else if (kind === 'file') {
      head = '本地文件';
    }
    const count: number = item.ruleCount !== undefined ? item.ruleCount : 0;
    const rawStatus: string | undefined = item.status;
    const status: string = rawStatus !== undefined ? rawStatus : '';
    let tail: string = count > 0 ? count.toString() + ' 条' : '未下载';
    if (status === 'compiling') {
      tail = '编译中';
    } else if (status === 'downloading') {
      tail = '下载中';
    } else if (status === 'failed') {
      tail = '下载失败';
    } else if (status === 'missing') {
      tail = '待更新';
    }
    return head + ' · ' + tail;
  }

  build() {
    List({ space: 10 }) {
      ListItem() {
        Column() {
          Row() {
            Column() {
              Text('拦截网页广告')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Text('按下方规则源过滤广告与追踪脚本')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.adBlockOn })
              .selectedColor($r('app.color.accent_primary'))
              .onChange((isOn: boolean): void => {
                this.setEnabled(isOn);
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 14 })
          .alignItems(VerticalAlign.Center)

          Divider()
            .color($r('app.color.divider'))
            .margin({ left: 16, right: 16 })

          Row() {
            Column() {
              Text('自动更新规则')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Text('空闲时拉取规则更新')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: this.autoUpdate })
              .selectedColor($r('app.color.accent_primary'))
              .onChange((isOn: boolean): void => {
                this.setAutoUpdate(isOn);
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 14, bottom: 14 })
          .alignItems(VerticalAlign.Center)

          Divider()
            .color($r('app.color.divider'))
            .margin({ left: 16, right: 16 })

          Text(this.statusLine)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 10, bottom: 12 })
        }
        .width('100%')
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))
        .clip(true)
      }

      ListItem() {
        Button(this.updating ? '正在更新…' : '立即更新规则')
          .width('100%')
          .height(44)
          .fontSize(15)
          .fontColor($r('app.color.accent_primary'))
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(16)
          .enabled(!this.updating)
          .onClick((): void => {
            this.updateSources();
          })
      }

      ListItem() {
        Text('规则源')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ left: 4, top: 6 })
      }

      ForEach(this.sources, (item: AdBlockSource): void => {
        ListItem() {
          Row() {
            Column() {
              Text(item.name)
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
              Text(this.sourceSubtitle(item))
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Toggle({ type: ToggleType.Switch, isOn: item.enabled })
              .selectedColor($r('app.color.accent_primary'))
              .onChange((isOn: boolean): void => {
                this.setSource(item.id, isOn);
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
          .alignItems(VerticalAlign.Center)
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
        }
      }, (item: AdBlockSource): string => item.id)

      ListItem() {
        Text('规则来自 EasyList 等公开列表，下载后在本机编译；首次使用需要联网。')
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ left: 4, top: 4, bottom: 8 })
      }
    }
    .width('100%')
    .height('100%')
    // 二级页标题栏浮在内容上（HDS 渐变模糊），内容必须自己让开，否则第一张
    // 卡片钻到「广告拦截」标题下面（1.0.3 用户截图）。
    .padding({
      left: 16,
      right: 16,
      top: glassHeaderInsetVp() + 8,
      bottom: glassBottomInsetVp()
    })
  }
}

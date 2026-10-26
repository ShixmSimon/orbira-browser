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
 *
 * 引擎若 dlopen 不到 adblock DSO（libadblock.so），所有写命令会回
 * 'engineUnavailable' —— 那是安装包里缺这个 so，不是本页的问题。
 */
import { BrowserCommandPayload } from 'engine';
import { AdBlockSource, AdBlockStateEvent } from 'engine';
import { glassBottomInsetVp, glassHeaderInsetVp } from './GlassPage';
import { promptAction } from '@kit.ArkUI';

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
  @State private exceptions: string[] = [];
  @State private userRuleCount: number = 0;
  @State private statusLine: string = '正在读取规则…';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};

  // 「添加订阅」与「我的规则」用内联展开区，不用对话框：二级页里 sheet 会盖住
  // 标题栏，CustomDialogController 又要额外生命周期，就地展开最省事。
  @State private showAddSource: boolean = false;
  @State private newSourceName: string = '';
  @State private newSourceUrl: string = '';
  @State private showRules: boolean = false;
  @State private rulesText: string = '';

  private contextId: string = '';
  private revision: number = 0;
  private requestSeq: number = 0;
  private pendingWrite: BrowserCommandPayload | null = null;
  private retryPending: boolean = false;
  // 轮询：updateAdBlockSources 在引擎侧可能被同步下载/编译阻塞，回包迟迟不来。
  // getAdBlockState 是能回包的，所以点更新后按 2 秒一档追问。
  private pollTimer: number = -1;
  private pollLeft: number = 0;

  aboutToAppear(): void {
    this.refresh();
  }

  aboutToDisappear(): void {
    this.stopPolling();
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
      return '订阅地址无效（需要 http/https 的规则列表地址）';
    }
    if (reason === 'limit') {
      return '规则源数量已达上限';
    }
    if (reason === 'engineUnavailable') {
      return '广告过滤引擎未加载（安装包缺 libadblock.so）';
    }
    if (reason === 'invalidSite') {
      return '网站域名无效';
    }
    if (reason.length > 0) {
      return '操作失败（' + reason + '）';
    }
    return '';
  }

  private apply(payload: AdBlockStateEvent): void {
    const reason: string = payload.reason !== undefined ? payload.reason : '';
    if (reason === 'stale') {
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
      if (!payload.updating) {
        this.stopPolling();
      }
    } else if (reason.length > 0 || payload.ok === true) {
      this.updating = false;
      this.stopPolling();
    }
    if (payload.sources !== undefined) {
      this.sources = payload.sources;
    }
    if (payload.exceptions !== undefined) {
      this.exceptions = payload.exceptions;
    }
    if (payload.userRuleCount !== undefined) {
      this.userRuleCount = payload.userRuleCount;
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
    this.startPolling();
  }

  private startPolling(): void {
    this.stopPolling();
    this.pollLeft = 22;
    this.pollTimer = setInterval((): void => {
      this.pollLeft -= 1;
      if (this.pollLeft <= 0) {
        this.stopPolling();
        if (this.updating) {
          this.updating = false;
          this.statusLine = '规则更新超时：引擎一直没有回报进度';
        }
        return;
      }
      this.refresh();
    }, 2000);
  }

  private stopPolling(): void {
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  // ---- 自定义规则 ----
  private submitSubscription(): void {
    const name: string = this.newSourceName.trim();
    const url: string = this.newSourceUrl.trim();
    if (url.length === 0) {
      promptAction.showToast({ message: '订阅地址不能为空', duration: 2000 });
      return;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      promptAction.showToast({ message: '订阅地址要以 http:// 或 https:// 开头', duration: 2000 });
      return;
    }
    const payload: BrowserCommandPayload = this.write('saveAdBlockSource');
    payload.name = name.length > 0 ? name : url;
    payload.url = url;
    this.send(payload);
    this.showAddSource = false;
    this.newSourceName = '';
    this.newSourceUrl = '';
    promptAction.showToast({ message: '已添加订阅，点「检查规则更新」拉取', duration: 2000 });
  }

  private submitUserRules(): void {
    const payload: BrowserCommandPayload = this.write('setAdBlockUserRules');
    payload.text = this.rulesText;
    this.send(payload);
    this.showRules = false;
    promptAction.showToast({ message: '自定义规则已保存', duration: 2000 });
  }

  private importFileHint(): void {
    // 文件选择器还要接 DocumentViewPicker（选择 → 读 → importAdBlockFile{path,name}），
    // 这一版先给出可用的替代路径，避免点上去没反应。
    promptAction.showToast({
      message: '暂不支持从文件导入，可把规则文本粘贴到「我的规则」',
      duration: 2600
    });
  }

  private removeException(host: string): void {
    const payload: BrowserCommandPayload = this.write('removeAdBlockException');
    payload.text = host;
    this.send(payload);
    promptAction.showToast({ message: '已恢复对 ' + host + ' 的拦截', duration: 1800 });
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

  @Builder
  private RuleButton(label: string, action: () => void) {
    Button(label)
      .fontSize(13)
      .fontColor($r('app.color.accent_primary'))
      .height(34)
      .padding({ left: 14, right: 14 })
      .backgroundColor($r('app.color.surface_secondary'))
      .borderRadius(17)
      .onClick((): void => {
        action();
      })
  }

  @Builder
  private SectionTitle(title: string, note: string) {
    Column() {
      Text(title)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
      if (note.length > 0) {
        Text(note)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ top: 3 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 4, top: 6, bottom: 6 })
  }

  // 开源致谢：引擎用的是 Brave 系组件，许可证按 MPL-2.0 展示。
  @Builder
  private CreditRow(name: string, license: string, desc: string) {
    Row() {
      Column() {
        Text(name)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
        Text(desc)
          .fontSize(11)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ top: 2 })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(license)
        .fontSize(11)
        .fontColor($r('app.color.accent_primary'))
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    List({ space: 10 }) {
      // ---------- 自定义规则 ----------
      ListItem() {
        Column() {
          this.SectionTitle('自定义规则', '')
          Row({ space: 8 }) {
            this.RuleButton('添加订阅', (): void => {
              this.showAddSource = !this.showAddSource;
              this.showRules = false;
            })
            this.RuleButton('导入文件', (): void => {
              this.importFileHint();
            })
            this.RuleButton('我的规则', (): void => {
              this.showRules = !this.showRules;
              this.showAddSource = false;
            })
          }
          .width('100%')

          if (this.showAddSource) {
            Column({ space: 8 }) {
              TextInput({ text: this.newSourceName, placeholder: '名称（可留空）' })
                .fontSize(14)
                .height(40)
                .backgroundColor($r('app.color.surface_secondary'))
                .borderRadius(10)
                .onChange((value: string): void => {
                  this.newSourceName = value;
                })
              TextInput({ text: this.newSourceUrl, placeholder: '规则列表地址 https://…' })
                .fontSize(14)
                .height(40)
                .backgroundColor($r('app.color.surface_secondary'))
                .borderRadius(10)
                .onChange((value: string): void => {
                  this.newSourceUrl = value;
                })
              Row({ space: 8 }) {
                Button('取消')
                  .fontSize(13)
                  .height(34)
                  .layoutWeight(1)
                  .backgroundColor($r('app.color.surface_secondary'))
                  .fontColor($r('app.color.text_secondary'))
                  .onClick((): void => {
                    this.showAddSource = false;
                  })
                Button('保存')
                  .fontSize(13)
                  .height(34)
                  .layoutWeight(1)
                  .onClick((): void => {
                    this.submitSubscription();
                  })
              }
              .width('100%')
            }
            .width('100%')
            .margin({ top: 10 })
          }

          if (this.showRules) {
            Column({ space: 8 }) {
              Text('每行一条过滤规则，语法同 EasyList（例如 ||ads.example.com^ ）')
                .fontSize(11)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
              TextArea({ text: this.rulesText, placeholder: '在此粘贴自定义规则' })
                .fontSize(13)
                .height(120)
                .backgroundColor($r('app.color.surface_secondary'))
                .borderRadius(10)
                .onChange((value: string): void => {
                  this.rulesText = value;
                })
              Row({ space: 8 }) {
                Button('取消')
                  .fontSize(13)
                  .height(34)
                  .layoutWeight(1)
                  .backgroundColor($r('app.color.surface_secondary'))
                  .fontColor($r('app.color.text_secondary'))
                  .onClick((): void => {
                    this.showRules = false;
                  })
                Button('保存规则')
                  .fontSize(13)
                  .height(34)
                  .layoutWeight(1)
                  .onClick((): void => {
                    this.submitUserRules();
                  })
              }
              .width('100%')
            }
            .width('100%')
            .margin({ top: 10 })
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 14 })
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))
      }

      // ---------- 总开关 + 自动更新 ----------
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
              Text('应用运行且联网时检查，失败保留有效旧规则')
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

      // ---------- 检查更新 / 刷新状态 ----------
      ListItem() {
        Row({ space: 8 }) {
          Button(this.updating ? '正在更新…' : '检查规则更新')
            .fontSize(14)
            .height(40)
            .layoutWeight(1)
            .enabled(!this.updating)
            .onClick((): void => {
              this.updateSources();
            })
          Button('刷新状态')
            .fontSize(14)
            .height(40)
            .layoutWeight(1)
            .backgroundColor($r('app.color.card_background'))
            .fontColor($r('app.color.accent_primary'))
            .onClick((): void => {
              this.refresh();
            })
        }
        .width('100%')
      }

      // ---------- 不拦截的网站 ----------
      ListItem() {
        Column() {
          this.SectionTitle('不拦截的网站', '仅作用于该主机名，不包含其他子域名。')
          if (this.exceptions.length === 0) {
            Text('还没有网站例外')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 4, top: 4, bottom: 4 })
          } else {
            ForEach(this.exceptions, (host: string): void => {
              Row() {
                Text(host)
                  .fontSize(14)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                Button('恢复')
                  .fontSize(12)
                  .height(30)
                  .padding({ left: 12, right: 12 })
                  .backgroundColor($r('app.color.surface_secondary'))
                  .fontColor($r('app.color.accent_primary'))
                  .onClick((): void => {
                    this.removeException(host);
                  })
              }
              .width('100%')
              .padding({ left: 4, right: 4, top: 6, bottom: 6 })
              .alignItems(VerticalAlign.Center)
            }, (host: string): string => host)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 14 })
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))
      }

      // ---------- 规则源 ----------
      ListItem() {
        Column() {
          this.SectionTitle('规则源',
            this.userRuleCount > 0 ? ('自定义规则 ' + this.userRuleCount.toString() + ' 条已生效') : '')
          ForEach(this.sources, (item: AdBlockSource): void => {
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
            .padding({ top: 10, bottom: 10 })
            .alignItems(VerticalAlign.Center)
          }, (item: AdBlockSource): string => item.id)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 14 })
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))
      }

      // ---------- 开源致谢 ----------
      ListItem() {
        Column() {
          this.SectionTitle('开源致谢',
            '感谢 Brave、uBlock Origin、EasyList 及社区贡献者，为广告过滤提供引擎、脚本资源和规则。')
          this.CreditRow('adblock-rust', 'MPL-2.0',
            'brave/adblock-rust · 广告过滤引擎（adblock 0.13.3）')
          Divider().color($r('app.color.divider'))
          this.CreditRow('brave-core', 'MPL-2.0',
            'brave/brave-core · 浏览器侧广告过滤集成代码')
          Divider().color($r('app.color.divider'))
          this.CreditRow('adblock-resources', 'MPL-2.0',
            'brave/adblock-resources · 脚本与替代资源包')
          Divider().color($r('app.color.divider'))
          this.CreditRow('adblock-lists', 'MPL-2.0',
            'brave/adblock-lists · 补充规则与网站兼容修正')
          Divider().color($r('app.color.divider'))
          this.CreditRow('uBlock Origin', 'GPL-3.0-or-later',
            'gorhill/uBlock · scriptlets 与替代资源（Raymond Hill 及贡献者）')
          Divider().color($r('app.color.divider'))
          this.CreditRow('EasyList', 'CC-BY-SA 3.0', 'easylist/easylist · 基础广告过滤规则')
          Divider().color($r('app.color.divider'))
          this.CreditRow('EasyList China', 'CC-BY-SA 3.0', 'easylist/easylistchina · 中文网站补充规则')
          Divider().color($r('app.color.divider'))
          this.CreditRow('EasyPrivacy', 'CC-BY-SA 3.0', 'easylist/easylist · 跟踪器过滤规则')
          Text('各项目及第三方资源保留原作者版权，分别遵循其许可证（许可证原文随源码提供：' +
            'BRAVE-MPL-2.0.txt / UBLOCK-GPL-3.0.txt / CC-BY-SA-3.0.txt）。' +
            '规则是否启用，以「规则源」中的勾选为准。')
            .fontSize(11)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ top: 10 })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 12 })
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))
        .clip(true)
      }

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
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .scrollBar(BarState.Off)
    .padding({
      left: 16,
      right: 16,
      top: glassHeaderInsetVp(),
      bottom: glassBottomInsetVp()
    })
  }
}

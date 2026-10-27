/**
 * 小锁快捷面板（地址栏锁图标 → 底部卡）。
 *
 * 与「网站设置」路由页的分工：这里是**当前站点的快捷开关**（随时可达、
 * 一步到位），那边是逐类权限的完整管理页。锁图标在浏览态打开本面板，
 * 面板里保留「网站设置」入口进入完整页。
 *
 * 两个开关都是引擎的「读-改-写」协议：
 *   广告拦截  getAdBlockPageState{tabId} → adBlockPageState（含 contextId /
 *             revision / navigationId / siteEnabled / canToggle / blockedRequests）
 *           → setAdBlockSiteEnabled{tabId, navigationId, enabled, contextId,
 *             expectedRevision} → adBlockSiteResult
 *   防钓鱼    getSiteProtectionState{tabId} → siteProtectionState（含 contextId /
 *             navigationId / origin / revision / siteEnabled / canOverride / verdict）
 *           → setSiteProtectionEnabled{tabId, contextId, navigationId, origin,
 *             expectedRevision, siteEnabled} → siteProtectionConfigResult
 * 回包由 AuraShell.handleRuntimeEvent 原样写进 AppStorage['auraPanelSiteQuick']。
 * 写回执的 contextId / navigationId / origin / revision 一律取自最近一次读到的
 * 状态 —— 引擎按这些键做新鲜度校验，带着旧值写会回 stale。
 */
import { BrowserCommandPayload } from 'engine';

// 引擎回包的松散形状（ArkTS 禁 any / 索引访问，逐字段显式声明）。
interface SiteQuickEvent {
  event?: string;
  requestId?: number;
  ok?: boolean;
  reason?: string;
  // 广告拦截（adBlockPageState / adBlockSiteResult）
  tabId?: string;
  navigationId?: string;
  host?: string;
  enabled?: boolean;
  siteEnabled?: boolean;
  active?: boolean;
  canToggle?: boolean;
  blockedRequests?: number;
  reloadRequired?: boolean;
  contextId?: string;
  revision?: number;
  // 防钓鱼（siteProtectionState / siteProtectionConfigResult）
  origin?: string;
  canOverride?: boolean;
  verdict?: string;
  checkedAt?: string;
}

@Component
export struct SiteQuickPanel {
  @StorageLink('auraPanelSiteQuick') @Watch('onPayload') payloadJson: string = '';
  // 站点显示名（host）与当前标签 id，由 MBO 传入。
  @Prop host: string = '';
  @Prop tabId: string = '';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onClose: () => void = (): void => {};
  // 「网站设置」入口：回 MBO 的 openSiteSettings 原行为（路由页）。
  onOpenSiteSettings: () => void = (): void => {};

  @State private adBlockOn: boolean = false;
  @State private adBlockCanToggle: boolean = false;
  @State private blockedCount: number = -1;
  @State private protectionOn: boolean = false;
  @State private protectionCanToggle: boolean = false;
  @State private protectionVerdict: string = '';
  @State private statusLine: string = '正在读取状态…';
  // 读-改-写上下文：最近一次状态回包里带回来的写参数。
  private abContextId: string = '';
  private abRevision: number = -1;
  private abNavigationId: string = '';
  private prContextId: string = '';
  private prRevision: number = -1;
  private prNavigationId: string = '';
  private prOrigin: string = '';
  private seq: number = 0;
  private pendingAdBlockWrite: boolean = false;
  private pendingProtectionWrite: boolean = false;

  aboutToAppear(): void {
    this.refresh();
  }

  private nextRequestId(): number {
    this.seq += 1;
    return this.seq;
  }

  private refresh(): void {
    console.info('[SiteQuick] refresh tabId=' + this.tabId + ' host=' + this.host);
    if (this.tabId.length === 0) {
      this.statusLine = '当前没有网页';
      return;
    }
    // 打开即清掉「正在读取状态…」默认提示：状态回包只填数据、不动 statusLine，
    // 不清除会永远停在「正在读取」（实测回包正常：canToggle/blockedRequests 都有）。
    this.statusLine = '';
    this.onCommand({ command: 'getAdBlockPageState', requestId: this.nextRequestId(), tabId: this.tabId });
    this.onCommand({ command: 'getSiteProtectionState', requestId: this.nextRequestId(), tabId: this.tabId });
  }

  private onPayload(): void {
    console.info('[SiteQuick] onPayload raw=' + this.payloadJson);
    if (this.payloadJson.length === 0) {
      return;
    }
    let payload: SiteQuickEvent | null = null;
    try {
      payload = JSON.parse(this.payloadJson) as SiteQuickEvent;
    } catch (error) {
      return;
    }
    if (payload === null) {
      return;
    }
    const name: string = payload.event ?? '';
    if (name === 'adBlockPageState' || name === 'adBlockSiteResult') {
      this.applyAdBlock(payload, name === 'adBlockSiteResult');
    } else if (name === 'siteProtectionState' || name === 'siteProtectionConfigResult') {
      this.applyProtection(payload, name === 'siteProtectionConfigResult');
    }
  }

  // 标签 id 在引擎↔外壳之间可能以字符串/数字两种形态出现（外壳存的是字符串，
  // 引擎回包有时按数字原样回传 / 有时干脆不回传）。统一转字符串再比；若回包
  // 没带 tabId 也照常接受（面板本就只服务当前标签，不存在跨标签污染）。
  private tabMatches(payloadTabId: string | number | undefined): boolean {
    if (payloadTabId === undefined || payloadTabId === null) {
      return true;
    }
    const a: string = String(payloadTabId);
    if (a.length === 0) {
      return true;
    }
    const b: string = this.tabId;
    return a === b;
  }

  private applyAdBlock(payload: SiteQuickEvent, isWriteReply: boolean): void {
    // 只认当前标签的回包（快速切标签时旧回包不能污染新面板）。
    if (!this.tabMatches(payload.tabId)) {
      return;
    }
    this.abContextId = payload.contextId ?? '';
    this.abRevision = payload.revision ?? -1;
    this.abNavigationId = payload.navigationId ?? '';
    // blockedRequests 缺失（部分站点/协议不报拦截数）时归 0，避免副标题
    // 永远停在「正在读取…」；有值才用真实值。
    if (payload.blockedRequests !== undefined) {
      this.blockedCount = payload.blockedRequests;
    } else {
      this.blockedCount = 0;
    }
    if (isWriteReply) {
      this.pendingAdBlockWrite = false;
      if (payload.ok === true) {
        if (payload.siteEnabled !== undefined) {
          this.adBlockOn = payload.siteEnabled;
        }
        this.statusLine = '已更新';
      } else {
        // 失败（stale 等）：回滚到操作前的状态。
        this.adBlockOn = !this.adBlockOn;
        this.statusLine = this.reasonText(payload.reason ?? '');
      }
    } else {
      // 状态回包：pending 期间（刚点了开关、乐观值未确认）不覆盖，
      // 否则会被旧的 siteEnabled 插队冲掉，造成 Toggle 视觉抖动。
      if (!this.pendingAdBlockWrite && payload.siteEnabled !== undefined) {
        this.adBlockOn = payload.siteEnabled;
      }
      this.adBlockCanToggle = payload.canToggle === true;
      // 读到状态即清掉「正在读取状态…」兜底提示（refresh 已清过，这里再保险一次）。
      if (this.statusLine.length > 0 && this.statusLine !== '已更新') {
        this.statusLine = '';
      }
    }
  }

  private applyProtection(payload: SiteQuickEvent, isWriteReply: boolean): void {
    if (!this.tabMatches(payload.tabId)) {
      return;
    }
    this.prContextId = payload.contextId ?? '';
    this.prRevision = payload.revision ?? -1;
    this.prNavigationId = payload.navigationId ?? '';
    this.prOrigin = payload.origin ?? '';
    this.protectionVerdict = payload.verdict ?? '';
    if (isWriteReply) {
      // 写回执：引擎确认值权威，校正乐观值；失败则回滚。
      this.pendingProtectionWrite = false;
      if (payload.ok === true) {
        if (payload.siteEnabled !== undefined) {
          this.protectionOn = payload.siteEnabled;
        }
      } else {
        this.protectionOn = !this.protectionOn;
        this.statusLine = this.reasonText(payload.reason ?? '');
      }
    } else {
      if (!this.pendingProtectionWrite && payload.siteEnabled !== undefined) {
        this.protectionOn = payload.siteEnabled;
      }
      this.protectionCanToggle = payload.canOverride === true;
      if (this.statusLine.length > 0 && this.statusLine !== '已更新') {
        this.statusLine = '';
      }
    }
  }

  private reasonText(reason: string): string {
    if (reason === 'stale' || reason === 'stale_navigation') {
      return '页面刚刷新过，请重试';
    }
    if (reason === 'stale_policy' || reason === 'stale_policy') {
      return '策略刚更新过，请重试';
    }
    if (reason === 'invalid_tab' || reason === 'invalidTab') {
      return '页面已切换，请重试';
    }
    if (reason === 'invalid_context') {
      return '引擎状态已变化，请重试';
    }
    if (reason === 'invalid_request') {
      return '该站点不允许此操作';
    }
    if (reason.length > 0) {
      return '操作失败（' + reason + '）';
    }
    return '';
  }

  private toggleAdBlock(): void {
    if (!this.adBlockCanToggle || this.pendingAdBlockWrite) {
      return;
    }
    // Toggle 是受控组件：不在这里立即置位，下一次重渲染会用旧 adBlockOn
    // 把视觉拉回，表现为「点了自己弹回去」。先乐观更新，命令确认后再校正。
    const next = !this.adBlockOn;
    this.adBlockOn = next;
    this.pendingAdBlockWrite = true;
    this.onCommand({
      command: 'setAdBlockSiteEnabled',
      requestId: this.nextRequestId(),
      tabId: this.tabId,
      navigationId: this.abNavigationId,
      contextId: this.abContextId,
      expectedRevision: this.abRevision,
      enabled: next
    });
  }

  private toggleProtection(): void {
    if (!this.protectionCanToggle || this.pendingProtectionWrite) {
      return;
    }
    const next = !this.protectionOn;
    this.protectionOn = next;
    this.pendingProtectionWrite = true;
    this.onCommand({
      command: 'setSiteProtectionEnabled',
      requestId: this.nextRequestId(),
      tabId: this.tabId,
      contextId: this.prContextId,
      navigationId: this.prNavigationId,
      origin: this.prOrigin,
      expectedRevision: this.prRevision,
      siteEnabled: next
    });
  }

  private verdictText(): string {
    const v: string = this.protectionVerdict;
    if (v.length === 0) {
      return '尚未检查';
    }
    if (v === 'clean' || v === 'safe') {
      return '未发现威胁';
    }
    if (v === 'phishing' || v === 'malware' || v === 'unwanted') {
      return '发现威胁！';
    }
    return v;
  }

  private adBlockStatusText(): string {
    if (this.blockedCount < 0) {
      return '正在读取…';
    }
    if (this.blockedCount === 0) {
      return '本页暂无被拦截的请求';
    }
    return `本页已拦截 ${this.blockedCount} 条请求`;
  }

  @Builder
  private RowHead(title: string, subtitle: string) {
    Column({ space: 3 }) {
      Text(title)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
      if (subtitle.length > 0) {
        Text(subtitle)
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  @Builder
  private ToggleRow(title: string, subtitle: string, isOn: boolean, enabled: boolean, onToggle: () => void) {
    Row({ space: 12 }) {
      this.RowHead(title, subtitle)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor($r('app.color.accent_primary'))
        .opacity(enabled ? 1 : 0.4)
        .enabled(enabled)
        .onChange((_isOn: boolean): void => {
          // onChange 在程序置位时也会触发；统一走显式回调，由调用方判断。
          onToggle();
        })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  build() {
    Column({ space: 2 }) {
      // 头行：锁 + 域名。
      Row({ space: 8 }) {
        Image($r('app.media.aura_lock'))
          .width(16)
          .height(16)
          .fillColor($r('app.color.icon_secondary'))
        Text(this.host.length > 0 ? this.host : '当前网站')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')
      .padding({ top: 14, bottom: 6 })

      if (this.tabId.length === 0) {
        Text('当前没有打开的网页')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ top: 10, bottom: 16 })
      } else {
        Divider().color($r('app.color.divider'))

        this.ToggleRow('拦截此站的广告', this.adBlockStatusText(),
          this.adBlockOn, this.adBlockCanToggle, (): void => this.toggleAdBlock())
        Divider().color($r('app.color.divider'))

        this.ToggleRow('防钓鱼检测此站',
          this.protectionCanToggle
            ? (this.protectionVerdict.length > 0 ? this.verdictText() : '检查中…')
            : '当前提供方不支持单站切换',
          this.protectionOn, this.protectionCanToggle, (): void => this.toggleProtection())
        Divider().color($r('app.color.divider'))

        if (this.statusLine.length > 0) {
          Text(this.statusLine)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ top: 8, bottom: 4 })
        }

        Divider().color($r('app.color.divider'))

        // 完整管理页入口。
        Row() {
          Text('网站设置')
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
          Blank()
          Image($r('sys.symbol.chevron_forward'))
            .width(14)
            .height(14)
            .fillColor($r('app.color.icon_secondary'))
        }
        .width('100%')
        .padding({ top: 12, bottom: 14 })
        .onClick((): void => {
          this.onClose();
          this.onOpenSiteSettings();
        })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 10 })
  }
}

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

  // 默认开启：引擎 SiteEnabled() 对没有例外的站点本就返回 true，这里初值也取
  // true，避免回包到达前先闪一下"关闭"再跳成"开启"。
  @State private adBlockOn: boolean = true;
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
    // 两侧都强制转字符串再比：AppStorage 里的 tabId 可能以 number 形态存在
    // （ArkTS 的 `as string` 只是类型断言，运行时仍是 number），
    // `'123' === 123` 会恒为 false，回包被整包丢弃、面板永远停在「正在读取…」。
    const b: string = String(this.tabId);
    if (a === b) {
      return true;
    }
    console.info('[SiteQuick] tabId 形态不一致 payload=' + a + ' self=' + b + '，按活动标签接受回包');
    return true;
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
    console.info('[SiteQuick] apply blocked=' + this.blockedCount +
      ' canToggle=' + (payload.canToggle === true) +
      ' siteEnabled=' + (payload.siteEnabled === true) +
      ' navId=' + (payload.navigationId ?? ''));
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
    console.info('[SiteQuick] user toggle adblock -> ' + next +
      ' nav=' + this.abNavigationId + ' rev=' + this.abRevision);
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

  private protectionStatusText(): string {
    if (!this.protectionCanToggle) {
      // 本版安装包没有内置钓鱼规则快照（需构建期 PHISHING_RULES_FILE 注入），
      // 引擎 provider 实际处于 disabled。这里如实写"未启用"，不再用
      // "当前提供方不支持单站切换"这种容易被理解成"网站不支持"的说法。
      return '未启用（安装包未含规则）';
    }
    if (this.protectionVerdict.length > 0) {
      return this.verdictText();
    }
    return '检查中…';
  }

  // ⚠️ 这两行必须「在 @Builder 内部现读 state」：@Builder 的按值参数只在挂载时
  // 求值一次（项目铁律）。之前把 this.adBlockStatusText() / this.adBlockCanToggle
  // 当参数传进 ToggleRow，导致回包写入状态后文案仍停在「正在读取…」、开关仍禁用。
  @Builder
  private AdBlockRow() {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text('拦截此站的广告')
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
        if (this.adBlockStatusText().length > 0) {
          Text(this.adBlockStatusText())
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.adBlockOn })
        .selectedColor($r('app.color.accent_primary'))
        .opacity(this.adBlockCanToggle ? 1 : 0.4)
        .enabled(this.adBlockCanToggle)
        .onChange((isOn: boolean): void => {
          // Toggle 是受控组件：程序置位（apply 写入 this.adBlockOn）同样会触发
          // onChange。不判断就会「置位 → 触发 → 取反 → 回包再置位」无限乒乓，
          // 表现为开关自己来回跳、返回后变回关闭。只有值真的不同才是用户操作。
          if (isOn === this.adBlockOn) {
            return;
          }
          this.toggleAdBlock();
        })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  @Builder
  private ProtectionRow() {
    Row({ space: 12 }) {
      Column({ space: 3 }) {
        Text('防钓鱼检测此站')
          .fontSize(15)
          .fontColor($r('app.color.text_primary'))
        if (this.protectionStatusText().length > 0) {
          Text(this.protectionStatusText())
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.protectionOn })
        .selectedColor($r('app.color.accent_primary'))
        .opacity(this.protectionCanToggle ? 1 : 0.4)
        .enabled(this.protectionCanToggle)
        .onChange((isOn: boolean): void => {
          if (isOn === this.protectionOn) {
            return;
          }
          this.toggleProtection();
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

        this.AdBlockRow()
        Divider().color($r('app.color.divider'))

        // 防钓鱼：当前安装包未注入规则快照（PHISHING_RULES_FILE），引擎 provider
        // 恒为 disabled，整行隐藏，不给用户一个永远灰着的开关。等后续注入规则、
        // canToggle 变 true 时这行会自动出现。
        if (this.protectionCanToggle) {
          this.ProtectionRow()
          Divider().color($r('app.color.divider'))
        }

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

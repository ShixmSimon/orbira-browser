/**
 * 设置 → 代理。
 *
 * 数据通道：AuraShell.handleRuntimeEvent() 把引擎的 proxySettings /
 * proxyApplyResult / proxyTestResult / proxyCredentials /
 * proxySettingsChanged / proxyTestInvalidated 事件原样写进
 * AppStorage['auraPanelProxy']，本组件按 event.event 分流解析。
 *
 * 协议要点（shell_proxy_ohos.cc）：
 * - proxySettings / proxySettingsChanged 的载荷是全量 Snapshot：
 *   desired/effective（PublicConfig：mode/scheme/host/port/bypassRules/
 *   bypassPrivateAddresses/version/revision/hasCredentials，credentialRef
 *   永不下发）+ revision/effectiveRevision/restartRequired/controlled/status。
 * - 写命令带 expectedRevision 做乐观并发；不匹配回 status='conflict'，
 *   此时重拉 getProxySettings 刷新表单即可，无需重放。
 * - applyProxySettings / testProxySettings 的回包 Reply() 只在出错时带
 *   status 字段；**没有 status 字段 = 成功**。
 * - 凭证存系统 Asset Store（credentialRef 引用），明文只在
 *   getProxyCredentials 的显式回包里出现；保存走 credentialAction
 *   keep/replace/remove，凭证随 proxyUsername/proxyPassword 两个字段。
 * - proxyTestResult 的 status 值域：passed / authenticationFailed /
 *   certificateFailed / tunnelFailed / targetHttpError / timeout /
 *   handshakeFailed / unreachable（+ 同步校验失败的四种）。
 * - proxyApiVersion < 1（老引擎无此命令）时 getProxySettings 不会有回包，
 *   入口超时提示，面板保持只读。
 */
import { BrowserCommandPayload, ShellProxyConfig } from 'engine';
import { glassBottomInsetVp, glassHeaderInsetVp } from './GlassPage';

type ProxyMode = 'system' | 'direct' | 'custom';
type ProxyScheme = 'http' | 'https' | 'socks5';

interface ProxyDesired {
  mode: ProxyMode;
  scheme: ProxyScheme;
  host: string;
  port: number;
  bypassRules: string;
  bypassPrivateAddresses: boolean;
  revision: number;
  hasCredentials: boolean;
}

interface ProxySnapshot {
  desired?: ProxyDesired;
  effective?: ProxyDesired;
  revision?: number;
  effectiveRevision?: number;
  restartRequired?: boolean;
  controlled?: boolean;
  status?: string;
  proxyApiVersion?: number;
}

interface ProxyTestInfo {
  status: string;
  httpStatus: number;
  elapsedMs: number;
  netErrorName: string;
}

function asSnapshot(v: object | undefined): ProxySnapshot {
  const s: ProxySnapshot = (v as ProxySnapshot) ?? {};
  return s;
}

function testStatusText(status: string): string {
  if (status === 'passed') return '连接成功';
  if (status === 'authenticationFailed') return '认证失败：用户名或密码不正确';
  if (status === 'certificateFailed') return '证书校验失败';
  if (status === 'tunnelFailed') return '代理拒绝建立隧道（CONNECT 被拒）';
  if (status === 'targetHttpError') return '代理可达，但目标站点返回错误';
  if (status === 'timeout') return '连接超时';
  if (status === 'handshakeFailed') return '握手失败（SOCKS5 认证方式不受支持）';
  if (status === 'unreachable') return '无法连接代理服务器';
  if (status === 'controlled') return '当前由企业管理策略控制，无法修改';
  if (status === 'invalidConfig') return '配置无效：请检查主机、端口与协议';
  if (status === 'credentialsRequired') return '端点已变更，请重新输入代理的用户名和密码';
  if (status === 'secureStorageFailed') return '系统凭证存储不可用，无法保存或读取凭据';
  if (status === 'invalidCredentials') return '用户名和密码不能为空且不超过 255 字符';
  if (status === 'busy') return '上一次保存仍在进行，请稍后重试';
  if (status === 'conflict') return '配置已在其它窗口被修改，已为你刷新最新值';
  if (status === 'revisionExhausted') return '内部修订号已达上限，请清除数据后重试';
  return `失败（${status}）`;
}

@Component
export struct ProxyPanel {
  @StorageLink('auraPanelProxy') @Watch('onPayload') payloadJson: string = '';
  // 必须由外部传入同一个 Scroller：NavDestination 的 bindToScrollable 靠它拿
  // 滚动容器，标题栏渐隐模糊才生效（见 AdBlockPanel 同注）。
  scroller: Scroller = new Scroller();
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};

  // 引擎快照（proxySettings / proxySettingsChanged 原样缓存，供渲染引用）。
  private snapshot: ProxySnapshot = {};
  @State private ready: boolean = false;
  @State private controlled: boolean = false;
  @State private restartRequired: boolean = false;
  @State private statusLine: string = '正在读取代理配置…';
  @State private proxySupported: boolean = true;

  // 表单态（desired 的可编辑副本）。
  @State private mode: ProxyMode = 'system';
  @State private scheme: ProxyScheme = 'http';
  @State private host: string = '';
  @State private portText: string = '';
  @State private bypassRules: string = '';
  @State private bypassPrivateAddresses: boolean = false;

  // 凭证态。savedUsername 来自 getProxyCredentials（明文回包，只显示用户名）。
  @State private hasCredentials: boolean = false;
  @State private savedUsername: string = '';
  @State private credentialAction: 'keep' | 'replace' | 'remove' = 'keep';
  @State private showCredentialInputs: boolean = false;
  @State private username: string = '';
  @State private password: string = '';

  // 测试与保存的进行态/结果行。
  @State private testing: boolean = false;
  @State private testLine: string = '';
  @State private saving: boolean = false;
  @State private applyLine: string = '';

  private snapshotRevision: number = 0;
  private requestSeq: number = 0;
  private lastTestRequestId: number = -1;
  private pendingCredRequestId: number = -1;
  // 表单脏标记：用户改过端点后，"保留现有凭证"不再适用（引擎会回
  // credentialsRequired），保存前据此强制要求重新输入。
  private endpointDirty: boolean = false;

  aboutToAppear(): void {
    // @StorageLink 初值不触发 @Watch：重进面板时 AppStorage 里还留着上次
    // 面板的事件串，先吃一次（仅快照类事件，回包类事件过滤 requestId 即自弃），
    // 面板立即渲染，不再停在「正在读取代理配置…」。
    if (this.payloadJson.length > 0 && this.snapshotEventKind(this.payloadJson).length > 0) {
      this.onPayload();
    }
    this.requestSeq += 1;
    this.onCommand({ command: 'getProxySettings', requestId: this.requestSeq });
  }

  aboutToDisappear(): void {
    // 离开页面取消进行中的连接测试，避免后台继续占用网络栈。
    this.onCommand({ command: 'cancelProxyTest' });
  }

  private nextRequestId(): number {
    this.requestSeq += 1;
    return this.requestSeq;
  }

  // 解析缓存串的事件类型；仅快照类返回其 kind，其余（回包/损坏 JSON）返回空串。
  private snapshotEventKind(json: string): string {
    try {
      const kind: string = (JSON.parse(json) as Record<string, string>)['event'] ?? '';
      return (kind === 'proxySettings' || kind === 'proxySettingsChanged') ? kind : '';
    } catch (error) {
      return '';
    }
  }

  private send(payload: BrowserCommandPayload): void {
    this.onCommand(payload);
  }

  private applyFormFromDesired(desired: ProxyDesired): void {
    this.mode = desired.mode ?? 'system';
    this.scheme = desired.scheme ?? 'http';
    this.host = desired.host ?? '';
    this.portText = desired.port && desired.port > 0 ? `${desired.port}` : '';
    this.bypassRules = desired.bypassRules ?? '';
    this.bypassPrivateAddresses = desired.bypassPrivateAddresses ?? false;
    this.hasCredentials = desired.hasCredentials ?? false;
    this.credentialAction = 'keep';
    this.showCredentialInputs = false;
    this.username = '';
    this.password = '';
    this.endpointDirty = false;
  }

  private onPayload(): void {
    if (this.payloadJson.length === 0) {
      return;
    }
    const event: object = JSON.parse(this.payloadJson) as object;
    const kind: string = (event as Record<string, string>)['event'] ?? '';
    if (kind === 'proxySettings' || kind === 'proxySettingsChanged') {
      const snap = asSnapshot(event);
      this.snapshot = snap;
      this.proxySupported = (snap.proxyApiVersion ?? 0) >= 1;
      this.controlled = snap.controlled ?? false;
      this.restartRequired = snap.restartRequired ?? false;
      this.snapshotRevision = snap.revision ?? 0;
      const desired = snap.desired;
      if (desired) {
        // proxySettingsChanged 是引擎主动广播（保存成功/其它窗口改动），
        // 不能整表单覆盖——只刷新用户看不到的字段；proxySettings 是本页
        // 主动请求的回包，才允许覆盖表单。
        if (kind === 'proxySettings') {
          this.applyFormFromDesired(desired);
          this.ready = true;
          this.statusLine = this.controlled ? '当前由企业管理策略控制，以下设置只读' : '';
        } else {
          this.hasCredentials = desired.hasCredentials ?? this.hasCredentials;
          this.snapshotRevision = snap.revision ?? this.snapshotRevision;
          this.restartRequired = snap.restartRequired ?? false;
        }
      }
      return;
    }
    if (kind === 'proxyApplyResult') {
      this.saving = false;
      const status: string = (event as Record<string, string>)['status'] ?? '';
      if (status.length === 0) {
        this.applyLine = this.restartRequired ? '已保存，重启应用后对全部连接生效' : '已保存并生效';
        // 保存成功后 snapshot 会被 proxySettingsChanged 刷新；这里主动补拉一次，
        // 顺带拿新 revision（proxySettingsChanged 无 requestId，顺序不保证）。
        this.requestSeq += 1;
        this.onCommand({ command: 'getProxySettings', requestId: this.requestSeq });
      } else {
        this.applyLine = testStatusText(status);
        if (status === 'conflict' || status === 'busy') {
          this.requestSeq += 1;
          this.onCommand({ command: 'getProxySettings', requestId: this.requestSeq });
        }
      }
      return;
    }
    if (kind === 'proxyTestResult') {
      const rec = event as Record<string, string | number>;
      const reqId: number = Number(rec['requestId'] ?? -1);
      if (reqId !== this.lastTestRequestId) {
        return;
      }
      this.testing = false;
      const status: string = rec['status'] as string ?? '';
      const http: number = rec['httpStatus'] as number ?? 0;
      const ms: number = rec['elapsedMs'] as number ?? 0;
      const errName: string = rec['netErrorName'] as string ?? '';
      let line: string = testStatusText(status);
      if (status === 'passed') {
        line = `连接成功（HTTP ${http}，${Math.round(ms)}ms）`;
      } else if (errName.length > 0) {
        line += ` · ${errName}`;
      }
      this.testLine = line;
      return;
    }
    if (kind === 'proxyCredentials') {
      const cred = event as Record<string, string | number>;
      const reqId: number = Number(cred['requestId'] ?? -1);
      if (reqId !== this.pendingCredRequestId) {
        return;
      }
      this.pendingCredRequestId = -1;
      const status: string = cred['status'] as string ?? '';
      if (status === 'ready') {
        this.savedUsername = cred['proxyUsername'] as string ?? '';
      } else if (status === 'conflict') {
        // 别的窗口刚改过凭证，重拉快照对齐 revision 即可。
        this.requestSeq += 1;
        this.onCommand({ command: 'getProxySettings', requestId: this.requestSeq });
      }
      return;
    }
    if (kind === 'proxyTestInvalidated') {
      this.testLine = '配置已变更，之前的测试结果已失效';
      this.testing = false;
      return;
    }
  }

  private buildProxyConfig(): ShellProxyConfig {
    const port: number = Number.parseInt(this.portText, 10);
    const config: ShellProxyConfig = {
      version: 1,
      mode: this.mode,
      scheme: this.scheme,
      host: this.host.trim(),
      port: Number.isFinite(port) ? port : 0,
      bypassRules: this.bypassRules,
      bypassPrivateAddresses: this.bypassPrivateAddresses
    };
    return config;
  }

  private credentialActionForApply(): 'keep' | 'replace' | 'remove' {
    if (this.mode !== 'custom') {
      return 'keep';
    }
    if (this.credentialAction === 'remove') {
      return 'remove';
    }
    if (this.showCredentialInputs && this.username.length > 0 && this.password.length > 0) {
      return 'replace';
    }
    if (this.hasCredentials && this.savedUsername.length > 0) {
      return 'keep';
    }
    // 没有已存凭证也没有输入新凭证：交给引擎按 invalidCredentials 提示。
    return 'replace';
  }

  private save(): void {
    if (this.saving || this.controlled) {
      return;
    }
    this.applyLine = '';
    const action: 'keep' | 'replace' | 'remove' = this.credentialActionForApply();
    const payload: BrowserCommandPayload = {
      command: 'applyProxySettings',
      proxyConfig: this.buildProxyConfig(),
      credentialAction: action,
      expectedRevision: this.snapshotRevision
    };
    if (action === 'replace') {
      payload.proxyUsername = this.username;
      payload.proxyPassword = this.password;
    }
    this.saving = true;
    this.send(payload);
  }

  private startTest(): void {
    if (this.testing || this.mode !== 'custom' || this.controlled) {
      return;
    }
    this.testLine = '';
    const reqId: number = this.nextRequestId();
    this.lastTestRequestId = reqId;
    const payload: BrowserCommandPayload = {
      command: 'testProxySettings',
      proxyConfig: this.buildProxyConfig(),
      credentialAction: this.credentialActionForApply(),
      requestId: reqId,
      expectedRevision: this.snapshotRevision
    };
    if (this.credentialActionForApply() === 'replace') {
      payload.proxyUsername = this.username;
      payload.proxyPassword = this.password;
    }
    this.testing = true;
    this.send(payload);
  }

  private loadCredentials(): void {
    if (this.pendingCredRequestId >= 0) {
      return;
    }
    const reqId: number = this.nextRequestId();
    this.pendingCredRequestId = reqId;
    this.onCommand({
      command: 'getProxyCredentials',
      requestId: reqId,
      expectedRevision: this.snapshotRevision
    });
  }

  private modeLabel(m: ProxyMode): string {
    if (m === 'system') return '跟随系统';
    if (m === 'direct') return '不使用代理';
    return '手动配置';
  }

  private schemeLabel(s: ProxyScheme): string {
    if (s === 'http') return 'HTTP';
    if (s === 'https') return 'HTTPS';
    return 'SOCKS5';
  }

  // 单选行：选中态必须在 builder 体内现读 this.mode / this.scheme。
  // 不能把 selected 算成布尔按值传入——@Builder 按值参数挂载时定死，
  // state 变化后圆点不会刷新（点击不跟随即此因）。
  @Builder
  private ModeOption(label: string, value: ProxyMode) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      // 选中态用实心圆点：与桌面站点名单页的选择行一致（项目无 Radio 封装）。
      Circle({ width: 16, height: 16 })
        .fill(this.mode === value ? $r('app.color.accent_primary') : Color.Transparent)
        .stroke(this.mode === value ? Color.Transparent : $r('app.color.divider'))
        .strokeWidth(this.mode === value ? 0 : 1.5)
    }
    .width('100%')
    .height(44)
    .padding({ left: 14, right: 14 })
    .borderRadius(12)
    .backgroundColor(this.mode === value ? $r('app.color.card_background') : Color.Transparent)
    .onClick((): void => {
      this.mode = value;
    })
  }

  @Builder
  private SchemeOption(label: string, value: ProxyScheme) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      Circle({ width: 16, height: 16 })
        .fill(this.scheme === value ? $r('app.color.accent_primary') : Color.Transparent)
        .stroke(this.scheme === value ? Color.Transparent : $r('app.color.divider'))
        .strokeWidth(this.scheme === value ? 0 : 1.5)
    }
    .width('100%')
    .height(44)
    .padding({ left: 14, right: 14 })
    .borderRadius(12)
    .backgroundColor(this.scheme === value ? $r('app.color.card_background') : Color.Transparent)
    .onClick((): void => {
      this.scheme = value;
    })
  }

  @Builder
  private FieldRow(label: string, placeholder: string, text: string, onChange: (v: string) => void) {
    Row({ space: 10 }) {
      Text(label)
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .width(72)
      TextInput({ text: text, placeholder: placeholder })
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .placeholderColor($r('app.color.text_secondary'))
        .backgroundColor($r('app.color.card_background'))
        .borderRadius(10)
        .height(40)
        .layoutWeight(1)
        .onChange((v: string): void => {
          onChange(v);
        })
    }
    .width('100%')
  }

  @Builder
  private ResultLine(text: string, good: boolean) {
    if (text.length > 0) {
      Text(text)
        .fontSize(13)
        .fontColor(good ? $r('app.color.text_secondary') : $r('app.color.danger'))
        .width('100%')
        .padding({ left: 14, right: 14, top: 4, bottom: 4 })
    }
  }

  @Builder
  private ProxyView() {
    Column({ space: 12 }) {
      if (!this.ready) {
        Text(this.statusLine)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ top: 40 })
          .textAlign(TextAlign.Center)
      } else {
        if (this.controlled) {
          Text('当前代理由企业管理策略控制，无法修改。')
            .fontSize(13)
            .fontColor($r('app.color.danger'))
            .width('100%')
            .padding(12)
            .borderRadius(12)
            .backgroundColor($r('app.color.card_background'))
        }
        // ── 模式 ──
        Column({ space: 2 }) {
          Text('代理方式')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .margin({ bottom: 4 })
          this.ModeOption('跟随系统', 'system')
          this.ModeOption('不使用代理', 'direct')
          this.ModeOption('手动配置', 'custom')
        }
        .width('100%')
        .padding(12)
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))

        if (this.mode === 'custom') {
          // ── 服务器 ──
          Column({ space: 10 }) {
            Text('代理服务器')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            Row({ space: 8 }) {
              this.SchemeOption('HTTP', 'http')
              this.SchemeOption('HTTPS', 'https')
              this.SchemeOption('SOCKS5', 'socks5')
            }
            .width('100%')
            this.FieldRow('主机', '例如 proxy.example.com', this.host, (v: string): void => {
              this.host = v;
              this.endpointDirty = true;
            })
            this.FieldRow('端口', '1 - 65535', this.portText, (v: string): void => {
              this.portText = v.replace(/[^0-9]/g, '');
              this.endpointDirty = true;
            })
          }
          .width('100%')
          .padding(12)
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))

          // ── 凭证 ──
          Column({ space: 10 }) {
            Text('代理认证')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            if (this.hasCredentials && !this.showCredentialInputs) {
              Text(this.savedUsername.length > 0
                ? `已保存凭证（用户名 ${this.savedUsername}）`
                : '已保存代理凭证')
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
              Row({ space: 10 }) {
                Button('更换凭证')
                  .fontSize(14)
                  .height(36)
                  .layoutWeight(1)
                  .backgroundColor($r('app.color.card_background'))
                  .fontColor($r('app.color.text_primary'))
                  .onClick((): void => {
                    this.showCredentialInputs = true;
                    this.loadCredentials();
                  })
                Button('清除凭证')
                  .fontSize(14)
                  .height(36)
                  .layoutWeight(1)
                  .backgroundColor($r('app.color.card_background'))
                  .fontColor($r('app.color.danger'))
                  .onClick((): void => {
                    this.credentialAction = 'remove';
                    this.showCredentialInputs = false;
                    this.username = '';
                    this.password = '';
                  })
              }
              .width('100%')
            } else {
              this.FieldRow('用户名', '可选', this.username, (v: string): void => {
                this.username = v;
              })
              this.FieldRow('密码', '可选', this.password, (v: string): void => {
                this.password = v;
              })
              if (this.hasCredentials) {
                Text('留空并保存 = 保留现有凭证；清除下方两个输入框内容后保存 = 删除凭证')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'))
                  .width('100%')
              }
            }
          }
          .width('100%')
          .padding(12)
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))

          // ── 绕过规则（可选高级项，默认折叠）──
          Column({ space: 8 }) {
            Text('绕过规则（每行一条主机名，可选）')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            TextArea({ text: this.bypassRules, placeholder: '例如：\n*.internal.example\n192.168.*' })
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.card_background'))
              .borderRadius(10)
              .height(72)
              .onChange((v: string): void => {
                this.bypassRules = v;
              })
            Row({ space: 10 }) {
              Text('不走代理的私有地址')
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.bypassPrivateAddresses })
                .selectedColor($r('app.color.accent_primary'))
                .onChange((on: boolean): void => {
                  if (on !== this.bypassPrivateAddresses) {
                    this.bypassPrivateAddresses = on;
                  }
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding(12)
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))

          // ── 测试 ──
          Column({ space: 8 }) {
            Button(this.testing ? '正在测试…' : '测试连接（example.com）')
              .fontSize(15)
              .height(42)
              .width('100%')
              .backgroundColor($r('app.color.card_background'))
              .fontColor($r('app.color.text_primary'))
              .enabled(!this.testing)
              .onClick((): void => {
                this.startTest();
              })
            if (this.testLine.length > 0) {
              Text(this.testLine)
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
            }
          }
          .width('100%')
          .padding(12)
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
        }

        this.ResultLine(this.applyLine, false)

        Button(this.saving ? '正在保存…' : '保存')
          .fontSize(16)
          .height(44)
          .width('100%')
          .enabled(!this.saving && !this.controlled)
          .onClick((): void => {
            this.save();
          })

        if (this.restartRequired) {
          Text('配置已保存，重启应用后对全部连接生效。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
      }
    }
    .width('100%')
    .padding({ bottom: glassBottomInsetVp() + 24 })
  }

  build() {
    // 与 AdBlockPanel 同款：List + 首/末占位 ListItem（padding 固化内容区会
    // 让内容滚不进标题栏下方，渐变模糊就没有可虚化的东西）。
    List({ space: 10, scroller: this.scroller }) {
      ListItem() {
        Row()
          .width('100%')
          .height(Math.max(0, glassHeaderInsetVp() - 10))
      }

      ListItem() {
        this.ProxyView()
      }

      ListItem() {
        Row()
          .width('100%')
          .height(Math.max(0, glassBottomInsetVp() - 10))
      }
    }
    .width('100%')
    .height('100%')
    // 项目面板惯例：不显示滚动条（与 AdBlockPanel 等全部面板一致）。
    .scrollBar(BarState.Off)
  }
}

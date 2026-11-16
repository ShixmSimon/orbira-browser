/*
 * 手机密码页。
 * 流程：进入先做本机身份验证（系统锁屏密码/指纹/人脸），通过后向引擎发
 * passwordAuthGranted {validMs:60000}，再拉 getSavedPasswords 列表；
 * 列表 -> 详情（编辑用户名/密码/备注，updatePassword；显示走 revealPassword；
 * 删除走 deletePassword）；顶部 ⋯ 菜单：导入密码（CSV）/ 导出密码（CSV）。
 * 导入导出：系统文件选择器 <-> 沙箱暂存 -> 引擎读写 -> 外壳清理。
 * 引擎回 authRequired 时回到验证门。应用退后台时由 AuraShell 发
 * passwordAuthReset 作废窗口。
 */
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { userAuth } from '@kit.UserAuthenticationKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { glassBottomInsetVp, glassHeaderInsetVp, glassTopSafeVp } from './GlassPage';
import {
  HdsNavigation,
  HdsNavigationTitleMode,
  HdsNavDestination,
  HdsNavDestinationTitleMode,
  hdsMaterial,
  ScrollEffectType
} from '@kit.UIDesignKit';
import { promptAction, curves } from '@kit.ArkUI';
import { MoreMenuDialog, MoreMenuItemSpec } from './MoreMenuDialog';
import {
  BrowserCommandPayload,
  PasswordCommandResultEvent,
  PasswordRevealedEvent,
  SavedPasswordItem,
  SavedPasswordsEvent
} from 'engine';
import { displayUrl, pickAndStageImportFile, saveExportedFile, deleteStagedFile } from './PanelBridge';
import { AuraChevron, AuraSectionLabel, AuraSiteIcon, AuraSearchBar } from './AuraKit';
import { requestFavicons, ingestFavicons, snapshotFavicons, faviconData } from './FaviconKit';

interface PanelEventPayload {
  kind?: string;
}

interface SecretPayload {
  id?: string;
  password?: string;
  note?: string;
}

interface ResultPayload {
  command?: string;
  ok?: boolean;
  reason?: string;
}

interface IoPayload {
  kind?: string;
  requestId?: number;
  ok?: boolean;
  imported?: number;
  skipped?: number;
  failed?: number;
  count?: number;
  reason?: string;
}

// LazyForEach 数据源（密码列表）。IDataSource / DataChangeListener 是 ArkTS
// 全局类型（编译器内置声明）——**不可**从 '@kit.ArkUI' import（1.0.177 教训：
// 报 10505001 has no exported member，级联满屏编译错）。
class PasswordDataSource implements IDataSource {
  private rows: SavedPasswordItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.rows.length;
  }

  getData(index: number): SavedPasswordItem {
    return this.rows[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    this.listeners.push(listener);
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  // 过滤结果/全量刷新后整体重排：onDataReloaded 让 List 重新取数。
  rebuild(rows: SavedPasswordItem[]): void {
    this.rows = rows;
    for (const listener of this.listeners) {
      listener.onDataReloaded();
    }
  }
}

// 密码行（@Reusable）：供 List + LazyForEach 复用。行数据走 @Prop —— 复用
// 时自动同步新值，无需 aboutToReuse 重复赋值。点击回传 itemId 由父组件查找
// （避免复用后闭包仍指向旧 item 的点错行）。
// 卡片观感：旧版是外层卡片 Column（borderRadius 16 + clip）包住 ForEach；
// 虚拟化后圆角拆到首/末行各自拼，视觉与旧版一致（分割线判据同时修正：
// 旧版按全量 items.length 判末行，搜索过滤后末行也会带一条）。
@Reusable
struct PasswordListRow {
  @Prop itemId: string = '';
  @Prop origin: string = '';
  @Prop username: string = '';
  @Prop selectMode: boolean = false;
  @Prop selected: boolean = false;
  @Prop isFirst: boolean = false;
  @Prop isLast: boolean = false;
  // 站点图标（dataURL）由面板按需请求后注入；为空时 AuraSiteIcon 走占位（主机名色 + 首字母）。
  @Prop iconData: string = '';
  onOpen: (id: string) => void = (_id: string): void => {};
  onToggle: (id: string) => void = (_id: string): void => {};

  build() {
    Column() {
      Row({ space: 12 }) {
        if (this.selectMode) {
          Column() {
            if (this.selected) {
              Image($r('app.media.aura_check'))
                .width(16)
                .height(16)
                .fillColor($r('app.color.on_accent'))
            }
          }
          .width(26)
          .height(26)
          .borderRadius(13)
          .border({
            width: 2,
            color: this.selected ? $r('app.color.accent_primary') : $r('app.color.divider')
          })
          .backgroundColor(this.selected ? $r('app.color.accent_primary') : Color.Transparent)
          .justifyContent(FlexAlign.Center)
        } else {
          AuraSiteIcon({ url: this.origin, iconData: this.iconData })
        }

        Column({ space: 2 }) {
          Text(displayUrl(this.origin))
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.username.length > 0 ? this.username : '（没有用户名）')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (!this.selectMode) {
          AuraChevron()
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 60 })
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .onClick(() => {
        if (this.selectMode) {
          this.onToggle(this.itemId);
        } else {
          this.onOpen(this.itemId);
        }
      })

      if (!this.isLast) {
        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 50 })
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.card_background'))
    .borderRadius({
      topLeft: this.isFirst ? 16 : 0,
      topRight: this.isFirst ? 16 : 0,
      bottomLeft: this.isLast ? 16 : 0,
      bottomRight: this.isLast ? 16 : 0
    })
  }
}

@Component
export struct PasswordsPanel {
  @StorageLink('auraPanelPasswords') @Watch('onPasswordsPayload') passwordsJson: string = '';
  @StorageLink('auraPanelPasswordSecret') @Watch('onSecretPayload') secretJson: string = '';
  @StorageLink('auraPanelPasswordResult') @Watch('onResultPayload') resultJson: string = '';
  @StorageLink('auraPanelPasswordIo') @Watch('onIoPayload') ioJson: string = '';
  @StorageLink('auraPanelEvent') @Watch('onPanelEvent') panelEventJson: string = '';
  // 站点图标：引擎回包统一落 'auraFavicons'（AuraShell 转存），本页只从该键读取。
  @StorageLink('auraFavicons') @Watch('onFaviconsChanged') faviconsJson: string = '';
  @State private faviconMap: Map<string, string> = new Map();
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onBack: () => void = (): void => {};
  onClose: () => void = (): void => {};

  @State private items: SavedPasswordItem[] = [];
  // 列表虚拟化数据源（LazyForEach）：filteredPasswords 变化时整体重建。
  private pwdDataSource: PasswordDataSource = new PasswordDataSource();
  // 验证门优先：进入先做本机验证，通过后 passwordAuthGranted + reload，
  // 引擎必有数据（requestId 回环已对齐书签，不会卡"加载中"）。
  @State private verified: boolean = false;
  private retryTimer: number = -1;
  private retryCount: number = 0;
  private pendingSeq: number = 0;
  @State private verifying: boolean = false;
  @State private verifyError: string = '';
  @State private loading: boolean = true;
  @State private view: string = 'list';
  // 1.0.160：详情页走真路由栈（NavPathStack + HdsNavDestination），列表是
  // Navigation 内容常驻挂载 —— 详情返回时列表滚动位置天然保留，转场走系统
  // 原生 push-pop（同 SettingsPanel 1.0.159 / ExtensionPanel 1.0.157）。
  private pathStack: NavPathStack = new NavPathStack();
  @State private editId: string = '';
  // 详情页两态：查看（行式 + 复制）默认；编辑单独进入。
  @State private detailMode: string = 'view';
  @State private editOrigin: string = '';
  @State private editUsername: string = '';
  @State private editPassword: string = '';
  @State private editNote: string = '';
  @State private revealed: boolean = false;
  @State private busy: boolean = false;
  private requestSeq: number = 0;
  private usernameTouched: boolean = false;
  private passwordTouched: boolean = false;
  private noteTouched: boolean = false;
  private pendingAuthInstance: userAuth.UserAuthInstance | null = null;
  private pendingImportPath: string = '';
  private pendingExportPath: string = '';
  private pendingExportRequestId: number = 0;
  // ⋯ 菜单项（原地 mutate，让「批量管理」按需出现）。
  private moreItems: MoreMenuItemSpec[] = [];

  aboutToDisappear(): void {
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    if (this.pendingAuthInstance !== null) {
      try {
        this.pendingAuthInstance.cancel();
      } catch (error) {
      }
      this.pendingAuthInstance = null;
    }
    this.cleanupPendingImport();
  }

  aboutToAppear(): void {
    // 缓存种子：上次的数据先显示（不闪"加载中"），再 reload 刷新。
    // 种子直接解析缓存（AppStorage 里的 requestId 是旧请求的，不走校验）。
    // 站点图标同理：@StorageLink 的初值不触发 @Watch，先吃一次已有回包，
    // 否则首帧全是占位色块。
    this.onFaviconsChanged();
    if (this.passwordsJson.length > 0) {
      try {
        const cached = JSON.parse(this.passwordsJson) as SavedPasswordsEvent;
        this.items = (cached.items ?? []) as SavedPasswordItem[];
        this.requestPasswordFavicons();
        this.recomputeFiltered();
        this.loading = false;
      } catch (error) {
      }
    }
    this.reload();
  }

  private cleanupPendingImport(): void {
    if (this.pendingImportPath.length > 0) {
      deleteStagedFile(this.pendingImportPath);
      this.pendingImportPath = '';
    }
  }

  private reload(): void {
    this.loading = true;
    this.retryCount = 0;
    this.requestSeq += 1;
    this.pendingSeq = this.requestSeq;
    this.onCommand({ command: 'getSavedPasswords', requestId: this.requestSeq });
    this.scheduleRetry();
  }

  private scheduleRetry(): void {
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    if (this.retryCount >= 3) {
      return;
    }
    this.retryCount += 1;
    const seq = this.pendingSeq;
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      if (this.loading && this.pendingSeq === seq) {
        this.requestSeq += 1;
        this.pendingSeq = this.requestSeq;
        this.onCommand({ command: 'getSavedPasswords', requestId: this.requestSeq });
        this.scheduleRetry();
      }
    }, 1500);
  }

  private onPasswordsPayload(): void {
    if (this.passwordsJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.passwordsJson) as SavedPasswordsEvent;
      // 只认最新请求的回包（旧回包/验证门的空回包不覆盖状态）。
      if ((payload.requestId ?? -1) !== this.pendingSeq) {
        return;
      }
      this.items = (payload.items ?? []) as SavedPasswordItem[];
      this.requestPasswordFavicons();
      this.recomputeFiltered();
      this.loading = false;
      if (this.retryTimer !== -1) {
        clearTimeout(this.retryTimer);
        this.retryTimer = -1;
      }
    } catch (error) {
      this.loading = false;
    }
  }

  private onSecretPayload(): void {
    if (this.secretJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.secretJson) as SecretPayload;
      const secret = String(payload.password ?? '');
      if (secret.length === 0) {
        return;
      }
      if (this.view === 'detail' && String(payload.id ?? '') === this.editId) {
        // Fill the editor; the reader asked to see or change this credential.
        this.editPassword = secret;
        this.editNote = String(payload.note ?? '');
        this.revealed = true;
      } else {
        this.showSecret(secret);
      }
    } catch (error) {
    }
  }

  private onResultPayload(): void {
    if (this.resultJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.resultJson) as ResultPayload;
      const command = String(payload.command ?? '');
      if (payload.ok === true) {
        if (command === 'deletePassword') {
          this.backToList();
          this.reload();
        } else if (command === 'updatePassword') {
          this.backToList();
          this.reload();
        }
        return;
      }
      if (String(payload.reason ?? '') === 'authRequired') {
        // The 60-second window expired; ask again.
        this.verified = false;
        this.verifyError = '';
        return;
      }
      if (command === 'updatePassword' && String(payload.reason ?? '') === 'duplicate') {
        AlertDialog.show({
          title: '保存不了',
          message: '这个网站下已经有一条同样的用户名了。改个用户名再试。',
          confirm: {
            value: '好的',
            action: (): void => {
            }
          }
        });
        return;
      }
      AlertDialog.show({
        title: '操作没有完成',
        message: command === 'deletePassword' ? '没能删除这条密码。' : '这个操作没有完成。',
        confirm: {
          value: '好的',
          action: (): void => {
          }
        }
      });
    } catch (error) {
    }
  }

  private onIoPayload(): void {
    if (this.ioJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.ioJson) as IoPayload;
      const kind = String(payload.kind ?? '');
      if (kind === 'import') {
        this.busy = false;
        // 引擎只把文件读进内存，读完即删缓存。
        this.cleanupPendingImport();
        if (payload.ok === true) {
          const imported = Number(payload.imported ?? 0);
          const skipped = Number(payload.skipped ?? 0);
          const failed = Number(payload.failed ?? 0);
          let message = `已导入 ${imported} 条密码`;
          if (skipped > 0 || failed > 0) {
            message = `导入 ${imported} 条，跳过 ${skipped} 条已有的，${failed} 条格式不对`;
          }
          AlertDialog.show({
            title: '导入完成',
            message: message,
            confirm: {
              value: '好的',
              action: (): void => {
              }
            }
          });
          this.reload();
        } else if (String(payload.reason ?? '') === 'authRequired') {
          this.verified = false;
          this.verifyError = '';
        } else {
          AlertDialog.show({
            title: '导入没有成功',
            message: this.importFailureText(String(payload.reason ?? '')),
            confirm: {
              value: '好的',
              action: (): void => {
              }
            }
          });
        }
        return;
      }
      if (kind === 'export') {
        if ((payload.requestId ?? 0) !== this.pendingExportRequestId ||
          this.pendingExportPath.length === 0) {
          return;
        }
        const stagedPath = this.pendingExportPath;
        this.pendingExportPath = '';
        if (payload.ok === true) {
          const count = Number(payload.count ?? 0);
          this.handExportToSaveDialog(stagedPath, count);
        } else if (String(payload.reason ?? '') === 'authRequired') {
          deleteStagedFile(stagedPath);
          this.verified = false;
          this.verifyError = '';
        } else {
          deleteStagedFile(stagedPath);
          AlertDialog.show({
            title: '导出没有成功',
            message: '没能写出密码文件，请再试一次。',
            confirm: {
              value: '好的',
              action: (): void => {
              }
            }
          });
        }
        return;
      }
    } catch (error) {
      this.busy = false;
    }
  }

  private importFailureText(reason: string): string {
    if (reason === 'tooLarge') {
      return '文件太大（超过 20 MB），没有导入。';
    }
    if (reason === 'badFormat') {
      return '这个文件里没有找到密码数据，没有导入。';
    }
    if (reason === 'ioError') {
      return '读不了这个文件，请再试一次。';
    }
    return '没能导入这个文件，请再试一次。';
  }

  private async handExportToSaveDialog(stagedPath: string, count: number): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      deleteStagedFile(stagedPath);
      return;
    }
    // 1.0.243：导出文件名去掉品牌名（原 'Aura 密码.csv'，装机反馈导出
    // 文件名还显示 aura）——保存框与系统下载列表里只应出现功能名。
    const saved = await saveExportedFile(context, stagedPath, '密码.csv');
    if (saved) {
      AlertDialog.show({
        title: '导出完成',
        message: `已导出 ${count} 条密码`,
        confirm: {
          value: '好的',
          action: (): void => {
          }
        }
      });
    }
  }

  private onPanelEvent(): void {
    if (this.panelEventJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.panelEventJson) as PanelEventPayload;
      if (String(payload.kind ?? '') === 'savedPasswordsChanged' && this.verified) {
        this.reload();
      }
    } catch (error) {
    }
  }

  // -- 本机身份验证（与引擎 UserAuthService.verify 同一套系统提示） --------

  private enrolledTypes(): userAuth.UserAuthType[] {
    const all: userAuth.UserAuthType[] = [
      userAuth.UserAuthType.FACE,
      userAuth.UserAuthType.FINGERPRINT,
      userAuth.UserAuthType.PIN
    ];
    return all.filter((type: userAuth.UserAuthType): boolean => {
      try {
        userAuth.getAvailableStatus(type, userAuth.AuthTrustLevel.ATL3);
        return true;
      } catch (error) {
        return false;
      }
    });
  }

  private verifyOnce(): void {
    if (this.verifying) {
      return;
    }
    const types = this.enrolledTypes();
    if (types.length === 0) {
      this.verifyError = '请先在系统设置里设置锁屏密码，才能查看已保存的密码';
      return;
    }
    this.verifying = true;
    this.verifyError = '';
    const challenge: Uint8Array = cryptoFramework.createRandom().generateRandomSync(32).data;
    const authParam: userAuth.AuthParam = {
      challenge: challenge,
      authType: types,
      authTrustLevel: userAuth.AuthTrustLevel.ATL3
    };
    const widgetParam: userAuth.WidgetParam = { title: '验证身份以管理密码' };
    let instance: userAuth.UserAuthInstance;
    try {
      instance = userAuth.getUserAuthInstance(authParam, widgetParam);
    } catch (error) {
      this.verifying = false;
      this.verifyError = '无法打开身份验证';
      return;
    }
    this.pendingAuthInstance = instance;
    instance.on('result', {
      onResult: (result: userAuth.UserAuthResult): void => {
        try {
          instance.off('result');
        } catch (error) {
        }
        if (this.pendingAuthInstance === instance) {
          this.pendingAuthInstance = null;
        }
        this.verifying = false;
        if (result.result === userAuth.UserAuthResultCode.SUCCESS) {
          this.verified = true;
          this.verifyError = '';
          this.onCommand({ command: 'passwordAuthGranted', validMs: 60000 });
          this.reload();
        } else {
          this.verifyError = '验证没有通过';
        }
      }
    });
    instance.start();
  }

  private showSecret(secret: string): void {
    AlertDialog.show({
      title: '密码',
      message: secret,
      autoCancel: true,
      primaryButton: {
        value: '复制',
        action: (): void => {
          this.copyText(secret);
        }
      },
      secondaryButton: {
        value: '关闭',
        action: (): void => {
        }
      }
    });
  }

  private copyText(text: string): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data);
    } catch (error) {
    }
  }

  // -- 详情 / 编辑 ------------------------------------------------------------

  // 'auraFavicons' 更新（含其它页触发的回包）：并进累积缓存后取整份快照，
  // 赋新对象触发重绘。@StorageLink 的初值不触发 @Watch，故 aboutToAppear 也调一次。
  private onFaviconsChanged(): void {
    ingestFavicons(this.faviconsJson);
    this.faviconMap = snapshotFavicons();
    // 回包可能只覆盖一部分 url（引擎只回命中的）：把还缺的补问一次。
    // Kit 内部按 url 记次数（≤3 次）并跳过已命中的，不会死循环。
    this.requestPasswordFavicons();
  }

  // 把当前密码条目的 origin 交给共享 FaviconKit 合批请求（去重 + 攒拍）。
  private requestPasswordFavicons(): void {
    const urls: string[] = [];
    for (const item of this.items) {
      if (item.origin && item.origin.length > 0) {
        urls.push(item.origin);
      }
    }
    requestFavicons(urls, this.onCommand);
  }

  private openDetail(item: SavedPasswordItem): void {
    this.view = 'detail';
    this.detailMode = 'view';
    this.editId = item.id;
    this.editOrigin = item.origin;
    this.editUsername = item.username;
    this.editPassword = '';
    this.editNote = '';
    this.revealed = false;
    this.usernameTouched = false;
    this.passwordTouched = false;
    this.noteTouched = false;
    this.pathStack.pushPathByName('detail', item.id);
    this.detailOnTop = true;
  }

  // 1.0.160：回列表 = 清详情态 + 弹掉详情 destination。删除/保存成功的引擎
  // 回包也走这里（onResultPayload）—— 只置 view='list' 不弹栈的话，详情页
  // 还压在列表上面，返回键会再次进详情。
  private backToList(): void {
    this.view = 'list';
    if (this.pathStack.size() > 0) {
      this.pathStack.pop();
      this.detailOnTop = false;
    }
  }

  private closeDetail(): void {
    if (this.detailMode === 'edit') {
      // 编辑态返回先回查看态，不丢详情。
      this.detailMode = 'view';
      return;
    }
    this.backToList();
    this.editId = '';
    this.editPassword = '';
    this.editNote = '';
    this.revealed = false;
  }

  private revealForEdit(): void {
    if (this.revealed || this.editId.length === 0) {
      return;
    }
    this.requestSeq += 1;
    this.onCommand({ command: 'revealPassword', requestId: this.requestSeq, id: this.editId });
  }

  private saveEdit(): void {
    if (this.busy || this.editId.length === 0) {
      return;
    }
    const username = this.editUsername.trim();
    const nothingChanged = !this.usernameTouched && !this.passwordTouched && !this.noteTouched;
    if (nothingChanged) {
      this.closeDetail();
      return;
    }
    const command: BrowserCommandPayload = {
      command: 'updatePassword',
      requestId: ++this.requestSeq,
      id: this.editId
    };
    command.username = username;
    if (this.passwordTouched) {
      command.password = this.editPassword;
    }
    if (this.noteTouched) {
      command.note = this.editNote;
    }
    this.busy = true;
    this.detailMode = 'view';
    this.onCommand(command);
    // busy 由回包清掉；失败时 onResultPayload 弹提示。
    setTimeout((): void => {
      this.busy = false;
    }, 3000);
  }

  private confirmRemove(item: SavedPasswordItem): void {
    AlertDialog.show({
      title: '删除这条密码？',
      message: `${displayUrl(item.origin)} 的这条密码会从浏览器删除，不能恢复。`,
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
          this.requestSeq += 1;
          this.onCommand({ command: 'deletePassword', requestId: this.requestSeq, id: item.id });
        }
      }
    });
  }

  // -- 批量管理 ----------------------------------------------------------------

  private isSelectedPwd(id: string): boolean {
    return this.selectedPwdIds.indexOf(id) >= 0;
  }

  private togglePwd(item: SavedPasswordItem): void {
    const idx = this.selectedPwdIds.indexOf(item.id);
    if (idx >= 0) {
      this.selectedPwdIds.splice(idx, 1);
    } else {
      this.selectedPwdIds.push(item.id);
    }
    this.selectedPwdIds = this.selectedPwdIds.slice();
  }

  private enterPwdSelect(): void {
    this.selectedPwdIds = [];
    this.selectMode = true;
  }

  private exitPwdSelect(): void {
    this.selectedPwdIds = [];
    this.selectMode = false;
  }

  private selectAllPwd(): void {
    const ids: string[] = [];
    for (const item of this.filteredPasswords) {
      ids.push(item.id);
    }
    this.selectedPwdIds = ids;
  }

  // 批量删除：循环发 deletePassword（引擎无复数删除命令）。每条回包触发
  // onResultPayload 的 deletePassword 分支（reload），列表自动刷新。
  private batchRemovePwd(): void {
    if (this.selectedPwdIds.length === 0) {
      return;
    }
    const ids = this.selectedPwdIds.slice();
    this.getUIContext().getPromptAction().showDialog({
      title: '删除所选',
      message: `确定删除选中的 ${ids.length} 条密码吗？删除后不能恢复。`,
      buttons: [
        { text: '取消', color: '#5F6368' },
        { text: '删除', color: '#E24B4A' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (result.index !== 1) {
        return;
      }
      for (const id of ids) {
        this.requestSeq += 1;
        this.onCommand({ command: 'deletePassword', requestId: this.requestSeq, id: id });
      }
      this.selectedPwdIds = [];
      this.selectMode = false;
    }).catch((error: Error): void => {
    });
  }

  // -- 导入 / 导出 -------------------------------------------

  // ⋯「导入密码」入口：先弹自绘弹窗（格式说明 + 增量/覆盖），选完模式
  // 再进系统文件选择器 —— 比旧版（先选文件再弹系统 AlertDialog）顺序更直觉。
  private openImportDialog(): void {
    if (this.busy || !this.verified) {
      return;
    }
    this.importOverwrite = false;
    this.importDialogVisible = true;
  }

  private async pickAndRunImport(overwrite: boolean): Promise<void> {
    if (this.busy || !this.verified) {
      return;
    }
    this.cleanupPendingImport();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    const path = await pickAndStageImportFile(context, ['密码文件|.csv']);
    if (path.length === 0) {
      return;
    }
    this.pendingImportPath = path;
    this.runImport(overwrite);
  }

  private runImport(overwrite: boolean): void {
    if (this.pendingImportPath.length === 0) {
      return;
    }
    this.busy = true;
    this.requestSeq += 1;
    this.onCommand({
      command: 'importPasswords',
      requestId: this.requestSeq,
      path: this.pendingImportPath,
      overwrite: overwrite
    });
  }

  private startExport(): void {
    if (this.busy || !this.verified) {
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    this.requestSeq += 1;
    this.pendingExportRequestId = this.requestSeq;
    this.pendingExportPath = `${context.filesDir}/aura-export-passwords.csv`;
    this.onCommand({
      command: 'exportPasswords',
      requestId: this.pendingExportRequestId,
      path: this.pendingExportPath
    });
  }

  // -- UI ---------------------------------------------------------------------


  @Builder
  private GateView() {
    Column({ space: 12 }) {
      Text('验证身份以管理密码')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text('查看、复制、编辑和导出密码前，先证明这是你的手机。')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
      if (this.verifyError.length > 0) {
        Text(this.verifyError)
          .fontSize(13)
          .fontColor($r('app.color.danger'))
          .textAlign(TextAlign.Center)
      }
      if (this.verifying) {
        LoadingProgress()
          .width(32)
          .height(32)
          .color($r('app.color.accent_primary'))
      } else {
        Button('验证身份')
          .width(200)
          .height(46)
          .fontSize(16)
          .fontColor($r('app.color.on_accent'))
          .backgroundColor($r('app.color.accent_primary'))
          .borderRadius(10)
          .onClick(() => {
            this.verifyOnce();
          })
      }
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 28, right: 28 })
  }

  @Builder
  private ListView() {
    Column() {
      if (this.items.length === 0) {
        Column({ space: 6 }) {
          Text(this.loading ? '加载中…' : '还没有保存的密码')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
          if (!this.loading) {
            Text('在网页上登录时，浏览器会询问是否保存密码。')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // 1.0.178：列表虚拟化。Scroll+Column+ForEach → List+LazyForEach +
        // @Reusable 行组件——getSavedPasswords 无条数上限，重度用户可上千条，
        // 官方实测 ForEach 到 10000 项即 560MB 内存 / 58% 丢帧。
        // 卡片观感由首/末行各自的圆角拼出（旧版是外层卡片 Column + clip）。
        List({ scroller: this.listScroller, space: 0 }) {
          // 1.0.179：顶部留白写成「内容项」而不是 List 视口的 padding ——
          // 视口 padding 会把滚动视口压低到标题行下方，内容永远进不了标题行
          // 区域，顶部渐变模糊丢失（1.0.121 同类教训）。留白作为第一个
          // ListItem：滚动时随内容滚走，内容才能穿过状态栏被渐变模糊盖住。
          ListItem() {
            Column()
              .width('100%')
              .height(glassHeaderInsetVp())
          }

          // 搜索框：随内容滚动（与旧版一致，位于大标题带之下）。
          ListItem() {
            AuraSearchBar({
              placeholder: '搜索密码',
              text: this.searchText,
              showClear: true,
              inputId: 'passwords_search_input',
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
          }

          if (this.filteredPasswords.length === 0) {
            ListItem() {
              Text('没有匹配的密码')
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .margin({ top: 40 })
            }
          }

          LazyForEach(this.pwdDataSource, (item: SavedPasswordItem, index: number) => {
            ListItem() {
              PasswordListRow({
                itemId: item.id,
                origin: item.origin,
                iconData: faviconData(item.origin, this.faviconMap),
                username: item.username,
                selectMode: this.selectMode,
                selected: this.isSelectedPwd(item.id),
                isFirst: index === 0,
                isLast: index === this.filteredPasswords.length - 1,
                onOpen: (id: string): void => {
                  const target = this.filteredPasswords.find((candidate: SavedPasswordItem): boolean =>
                    candidate.id === id);
                  if (target !== undefined) {
                    this.openDetail(target);
                  }
                },
                onToggle: (id: string): void => {
                  const target = this.filteredPasswords.find((candidate: SavedPasswordItem): boolean =>
                    candidate.id === id);
                  if (target !== undefined) {
                    this.togglePwd(target);
                  }
                }
              })
            }
          }, (item: SavedPasswordItem): string => item.id)

          ListItem() {
            Text('在网页上登录时，浏览器会询问是否保存密码；右上角可以导入、导出。')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 4, right: 4, top: 10 })
          }

          // 选择态末尾留白：同样写成内容项（不是视口）——列表铺满全高无死区，
          // 最后一行也能滚到悬浮操作条之上（见 BatchActionBar 注释）。
          if (this.selectMode && this.view === 'list') {
            ListItem() {
              Column()
                .width('100%')
                .height(50 + glassBottomInsetVp())
            }
          }
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        // 密码条目走 LazyForEach：缓存视口外几屏，避免快速滑动时边滑边建而顿一下。
        .cachedCount(6)
        .align(Alignment.TopStart)
        .onDidScroll(() => {
          // 搜索框随列表滚走后，在标题栏右侧（⋯ 菜单旁）浮现搜索按钮。
          // onDidScroll 给的是每帧偏移量，这里直接读绝对位置更稳。
          const off = this.listScroller.currentOffset().yOffset;
          const show = off > glassHeaderInsetVp() + 20 && this.items.length > 0;
          if (show !== this.searchFabVisible) {
            this.searchFabVisible = show;
          }
        })
      }

      // 批量操作条改为悬浮胶囊（见 BatchActionBar()，挂 body Stack，不占流式高度）。
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  private EditFieldLabel(text: string) {
    Text(text)
      .fontSize(13)
      .fontColor($r('app.color.text_secondary'))
      .width('100%')
      .margin({ bottom: 6 })
  }

  @Builder
  private DetailView() {
    Scroll(this.detailScroller) {
      Column() {
        AuraSectionLabel({ text: displayUrl(this.editOrigin), tightTop: true })

        if (this.detailMode === 'view') {
          // 查看态：行式布局 + 每行复制；编辑单独进入。
          Column() {
            Row({ space: 12 }) {
              Column({ space: 2 }) {
                Text('用户名')
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                Text(this.editUsername.length > 0 ? this.editUsername : '—')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Button({ type: ButtonType.Circle }) {
                Image($r('app.media.aura_copy'))
                  .width(18)
                  .height(18)
                  .fillColor($r('app.color.icon_secondary'))
              }
              .width(38)
              .height(38)
              .backgroundColor(Color.Transparent)
              .accessibilityText('复制用户名')
              .onClick(() => {
                if (this.editUsername.length > 0) {
                  this.copyText(this.editUsername);
                  this.getUIContext().getPromptAction().showToast({ message: '已复制', duration: 1500 });
                }
              })
            }
            .width('100%')
            .constraintSize({ minHeight: 56 })

            Divider()
              .color($r('app.color.divider'))

            Row({ space: 12 }) {
              Column({ space: 2 }) {
                Text('密码')
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                Text(this.revealed
                  ? (this.editPassword.length > 0 ? this.editPassword : '—')
                  : '••••••••')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Button({ type: ButtonType.Circle }) {
                Image($r('app.media.aura_eye'))
                  .width(18)
                  .height(18)
                  .fillColor($r('app.color.icon_secondary'))
              }
              .width(38)
              .height(38)
              .backgroundColor(Color.Transparent)
              .accessibilityText(this.revealed ? '隐藏密码' : '显示密码')
              .onClick(() => {
                if (this.revealed) {
                  this.revealed = false;
                } else {
                  this.revealForEdit();
                }
              })

              if (this.revealed && this.editPassword.length > 0) {
                Button({ type: ButtonType.Circle }) {
                  Image($r('app.media.aura_copy'))
                    .width(18)
                    .height(18)
                    .fillColor($r('app.color.icon_secondary'))
                }
                .width(38)
                .height(38)
                .backgroundColor(Color.Transparent)
                .accessibilityText('复制密码')
                .onClick(() => {
                  this.copyText(this.editPassword);
                  this.getUIContext().getPromptAction().showToast({ message: '已复制', duration: 1500 });
                })
              }
            }
            .width('100%')
            .constraintSize({ minHeight: 56 })

            Divider()
              .color($r('app.color.divider'))

            Row({ space: 12 }) {
              Column({ space: 2 }) {
                Text('备注')
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                Text(this.editNote.length > 0 ? this.editNote : '—')
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              if (this.editNote.length > 0) {
                Button({ type: ButtonType.Circle }) {
                  Image($r('app.media.aura_copy'))
                    .width(18)
                    .height(18)
                    .fillColor($r('app.color.icon_secondary'))
                }
                .width(38)
                .height(38)
                .backgroundColor(Color.Transparent)
                .accessibilityText('复制备注')
                .onClick(() => {
                  this.copyText(this.editNote);
                  this.getUIContext().getPromptAction().showToast({ message: '已复制', duration: 1500 });
                })
              }
            }
            .width('100%')
            .constraintSize({ minHeight: 56 })
          }
          .width('100%')
          .padding({ left: 16, right: 8, top: 4, bottom: 4 })
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))

          Row() {
            Text('编辑')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.on_accent'))
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
          .height(46)
          .borderRadius(12)
          .backgroundColor($r('app.color.accent_primary'))
          .margin({ top: 16 })
          .onClick(() => {
            this.detailMode = 'edit';
          })

          Row() {
            Text('删除这条密码')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.danger'))
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
          .height(46)
          .borderRadius(12)
          .backgroundColor($r('app.color.card_background'))
          .margin({ top: 10 })
          .onClick(() => {
            const item = this.items.find((candidate: SavedPasswordItem): boolean =>
              candidate.id === this.editId);
            if (item !== undefined) {
              this.confirmRemove(item);
            }
          })
        } else {
          // 编辑态：字段表单（改哪个存哪个）。
          Column({ space: 14 }) {
            Column() {
              this.EditFieldLabel('用户名')
              TextInput({ text: this.editUsername, placeholder: '没有用户名' })
                .height(46)
                .fontSize(15)
                .backgroundColor($r('app.color.surface_secondary'))
                .borderRadius(10)
                .onChange((value: string): void => {
                  this.editUsername = value;
                  this.usernameTouched = true;
                })
            }
            .width('100%')

            Column() {
              // 行尾眼睛按钮承载显示/隐藏（旧版"显示"文字会被挤出屏，
              // 且与 TextInput 自带的眼睛图标重复——用户定案保留眼睛）。
              Row({ space: 8 }) {
                Text('密码')
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
                Blank()
                Button({ type: ButtonType.Circle }) {
                  Image($r('app.media.aura_eye'))
                    .width(18)
                    .height(18)
                    .fillColor($r('app.color.icon_secondary'))
                }
                .width(34)
                .height(34)
                .backgroundColor(Color.Transparent)
                .accessibilityText(this.revealed ? '隐藏密码' : '显示密码')
                .onClick(() => {
                  if (this.revealed) {
                    this.revealed = false;
                  } else {
                    this.revealForEdit();
                  }
                })
              }
              .width('100%')

              TextInput({
                text: this.editPassword,
                placeholder: '不修改请留空；点眼睛载入'
              })
                .height(46)
                .fontSize(15)
                .type(this.revealed ? InputType.Normal : InputType.Password)
                .showPasswordIcon(false)
                .backgroundColor($r('app.color.surface_secondary'))
                .borderRadius(10)
                .onChange((value: string): void => {
                  this.editPassword = value;
                  this.passwordTouched = true;
                })
            }
            .width('100%')

            Column() {
              this.EditFieldLabel('备注')
              TextInput({ text: this.editNote, placeholder: '没有备注' })
                .height(46)
                .fontSize(15)
                .backgroundColor($r('app.color.surface_secondary'))
                .borderRadius(10)
                .onChange((value: string): void => {
                  this.editNote = value;
                  this.noteTouched = true;
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .alignItems(HorizontalAlign.Start)

          Text('改了哪个字段就保存哪个；什么都不改直接返回即可。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ left: 4, top: 10 })

          Row() {
            Text(this.busy ? '保存中…' : '保存')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.on_accent'))
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
          .height(46)
          .borderRadius(12)
          .backgroundColor($r('app.color.accent_primary'))
          .opacity(this.busy ? 0.5 : 1)
          .margin({ top: 16 })
          .onClick(() => {
            if (!this.busy) {
              this.saveEdit();
            }
          })
        }

      }
      .width('100%')
      // 大标题带：滚动内容穿过「密码详情」大标题时逐渐虚化（见 GlassPage 文件头）。
      .padding({ top: glassHeaderInsetVp() })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    .align(Alignment.TopStart)
  }

  // ⋯ 的子菜单改走系统 ActionSheet（本页是原生内容，系统弹窗可用）。
  // ⋯ 的子菜单：CustomDialog 承载（弹窗子窗口 = 沉浸材质允许区，真玻璃 +
  // 流光；形态对齐旧版 bindMenu：贴右上、标题行正下方弹出的小菜单卡）。
  private showMoreSheet(): void {
    if (this.view !== 'list') {
      return;
    }
    this.moreItems.length = 0;
    this.moreItems.push(
      {
        icon: $r('app.media.aura_import'),
        label: '导入密码',
        action: (): void => {
          this.openImportDialog();
        }
      },
      {
        icon: $r('app.media.aura_export'),
        label: '导出密码',
        action: (): void => {
          this.startExport();
        }
      }
    );
    if (this.verified) {
      this.moreItems.push(
        {
          icon: $r('app.media.aura_check'),
          label: '多选',
          action: (): void => {
            this.enterPwdSelect();
          }
        }
      );
    }
    this.moreMenuDialog.open();
  }

  private moreMenuDialog: CustomDialogController = new CustomDialogController({
    builder: MoreMenuDialog({
      items: this.moreItems
    }),
    autoCancel: true,
    customStyle: true,
    maskColor: Color.Transparent,
    alignment: DialogAlignment.TopEnd,
    offset: { dx: -12, dy: glassTopSafeVp() + 62 }
  });

  private listScroller: Scroller = new Scroller();
  private detailScroller: Scroller = new Scroller();
  @State private searchText: string = '';
  // 搜索框滚走后，标题栏右侧浮现搜索按钮（点它回顶 + 聚焦）。
  @State private searchFabVisible: boolean = false;
  // 详情 destination 是否在栈顶：搜索回顶按钮挂 Navigation overlay（内容层
  // 在 titleBar 之下，会被渐变模糊压住发暗），overlay 会盖住推入的详情页，
  // 故推入/弹出时联动隐藏。
  @State private detailOnTop: boolean = false;
  // 导入模式弹窗（自绘）：先选增量/覆盖，再进文件选择器。
  @State private importDialogVisible: boolean = false;
  @State private importOverwrite: boolean = false;
  // 过滤结果落 @State（同 HistoryPanel：方法间接读 @State 不建立更新依赖）。
  @State private filteredPasswords: SavedPasswordItem[] = [];
  // 批量管理：选择模式 + 已选密码 id 集合（仅列表态、已验证时可用）。
  @State private selectMode: boolean = false;
  @State private selectedPwdIds: string[] = [];

  // 重算过滤结果（写入 @State）：搜索词变化与数据源变化处都要调用。
  private recomputeFiltered(): void {
    const q = this.searchText.trim().toLowerCase();
    if (q.length === 0) {
      this.filteredPasswords = this.items;
      this.pwdDataSource.rebuild(this.items);
      return;
    }
    const out: SavedPasswordItem[] = [];
    for (const item of this.items) {
      if (item.origin.toLowerCase().includes(q) || item.username.toLowerCase().includes(q)) {
        out.push(item);
      }
    }
    this.filteredPasswords = out;
    this.pwdDataSource.rebuild(out);
  }

  // 搜索框滚走后，点右上角搜索按钮平滑回顶并聚焦搜索框。
  // 聚焦必须延迟到回顶动画结束之后：requestFocus 唤起输入法会触发重布局，
  // 打断进行中的回顶弹簧动画 —— 实测列表停在半路，搜索框压在视口上方露不出来。
  private scrollToSearch(): void {
    this.listScroller.scrollTo({
      xOffset: 0,
      yOffset: 0,
      animation: { duration: 320, curve: curves.springMotion(0.34, 0.84) }
    });
    setTimeout((): void => {
      this.getUIContext().getFocusController().requestFocus('passwords_search_input');
    }, 480);
  }

    // 导入模式弹窗（自绘）：格式说明 + 增量/覆盖选择。
  @Builder
  private ImportDialog() {
    if (this.importDialogVisible) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.modal_scrim'))
          // 遮罩柔和淡入淡出（1.0.66/67）：进入 260ms、退出 380ms（此前退出过快）。
          .transition(TransitionEffect.asymmetric(
            TransitionEffect.opacity(0).animation({ duration: 260, curve: Curve.Friction }),
            TransitionEffect.opacity(0).animation({ duration: 380, curve: Curve.Friction })
          ))
          .onClick(() => {
            this.importDialogVisible = false;
          })

        Row() {
        Column({ space: 14 }) {
          Text('导入密码')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Text('支持 Chrome、Edge、Firefox 导出的 CSV 密码文件（含网址、用户名、密码列）。')
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          Column({ space: 6 }) {
            Text('增量导入')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .width('100%')
            Text('已保存的同名账号保持不变，只导入新的账号。')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.surface_secondary'))
          .onClick(() => {
            this.importDialogVisible = false;
            this.pickAndRunImport(false);
          })

          Column({ space: 6 }) {
            Text('覆盖导入')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.danger'))
              .width('100%')
            Text('已保存的同名账号会被文件里的密码替换，请确认 CSV 来自可信来源。')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
          .width('100%')
          .padding(14)
          .borderRadius(12)
          .backgroundColor($r('app.color.surface_secondary'))
          .onClick(() => {
            this.importDialogVisible = false;
            this.pickAndRunImport(true);
          })

          Row() {
            Text('取消')
              .fontSize(15)
              .fontColor($r('app.color.text_secondary'))
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
          .height(40)
          .onClick(() => {
            this.importDialogVisible = false;
          })
        }
        .width('100%')
        .padding(20)
        .borderRadius(22)
        .backgroundColor($r('app.color.menu_glass'))
        .shadow({ radius: 26, color: $r('app.color.shadow'), offsetY: 8 })
        // 卡片入场/退场动效（1.0.67）：此前只有遮罩有过渡、卡片本体瞬跳。
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.opacity(0)
            .combine(TransitionEffect.scale({ x: 0.92, y: 0.92 }))
            .animation({ curve: curves.springMotion(0.3, 0.75) }),
          TransitionEffect.opacity(0)
            .combine(TransitionEffect.scale({ x: 0.95, y: 0.95 }))
            .animation({ duration: 320, curve: Curve.FastOutSlowIn })
        ))
        }
        .padding({ left: 44, right: 44 })
        .width('100%')
      }
      .width('100%')
      .height('100%')
      // 退场动效（1.0.68）：过渡必须挂在 if 分支根节点上 —— 挂子节点时进场
      // 能播、退场被整棵子树原子删除（真机："背景缓慢变暗，取消瞬间变亮"）。
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.opacity(1),
        TransitionEffect.opacity(0).animation({ duration: 340, curve: Curve.Friction })
      ))
    }
  }

  // 悬浮批量操作条：绝对定位于 body Stack 底部，自绘玻璃药丸（float_bar_bg +
  // 细描边 + 投影）。**宽度随内容走**：外层全宽 Row 只负责底部定位与水平居中，
  // 自身透明且透传点击；内层 Scroll 不设 minWidth，只约束 maxWidth 100%，
  // 只有一个「全选」时就是一小颗药丸，四周/下方露出列表与页面底色，不会被拉成
  // 横贯屏幕的白色长条。选中后出现「删除」，药丸随之变长，横向 Scroll 兜底。
  // 仅列表态（已验证）有意义。
  @Builder
  private BatchActionBar() {
    if (this.selectMode && this.view === 'list') {
      Stack({ alignContent: Alignment.Center }) {
        Scroll() {
          Row({ space: 8 }) {
            Row({ space: 6 }) {
              Image($r('app.media.aura_check'))
                .width(16)
                .height(16)
                .fillColor($r('app.color.accent_primary'))
              Text('全选')
                .fontSize(14)
                .fontColor($r('app.color.accent_primary'))
            }
            .height(36)
            .padding({ left: 16, right: 16 })
            .borderRadius(18)
            .onClick(() => {
              this.selectAllPwd();
            })

            if (this.selectedPwdIds.length > 0) {
              Row({ space: 6 }) {
                Image($r('app.media.aura_trash'))
                  .width(16)
                  .height(16)
                  .fillColor($r('app.color.danger'))
                Text(`删除 (${this.selectedPwdIds.length})`)
                  .fontSize(14)
                  .fontColor($r('app.color.danger'))
              }
              .height(36)
              .padding({ left: 16, right: 16 })
              .borderRadius(18)
              .onClick(() => {
                this.batchRemovePwd();
              })
            }
          }
          .justifyContent(FlexAlign.Center)
          .padding({ left: 8, right: 8 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .constraintSize({ maxWidth: '100%' })
        .clip(true)
        .backgroundColor($r('app.color.float_bar_bg'))
        // 不用 backgroundBlurStyle(Thin)：系统 Thin 材质会再叠一层白，实测把 60%
        // 白色药丸渲染成不透明纯白（254,254,254），用户看到的就是"不透"。
        .border({ width: 0.5, color: $r('app.color.divider') })
        .borderRadius(23)
        .shadow({ radius: 18, color: $r('app.color.shadow'), offsetY: 6 })
        .padding({ top: 5, bottom: 5 })
      }
      .width('100%')
      .position({ bottom: glassBottomInsetVp() })
      .hitTestBehavior(HitTestMode.Transparent)
    }
  }

  // 1.0.160：弃 GlassPage，面板自持 HdsNavigation + NavPathStack（同
  // SettingsPanel 1.0.159 / ExtensionPanel 1.0.157 套路）。列表是 Navigation
  // 内容、常驻挂载 —— 详情返回时滚动位置天然保留；详情作为 NavDestination
  // 推入，系统默认走原生鸿蒙层级转场（干净减速、零过冲、无回弹）。
  build() {
    HdsNavigation(this.pathStack) {
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          if (!this.verified) {
            this.GateView()
          } else {
            this.ListView()
          }
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16 })
        .backgroundColor($r('app.color.page_background'))

        // 导入模式弹窗 / 批量操作栏：悬浮层挂列表这层（viewport 固定）。
        // 搜索回顶入口由标题栏 menu 的「回到搜索」项统一提供，此处不再添加
        // 内容层悬浮按钮：其位置与命中区域均不如 menu 中的入口。
        this.ImportDialog()
        this.BatchActionBar()
      }
      .width('100%')
      .height('100%')
    }
    .titleBar({
      content: {
        title: { mainTitle: this.selectMode ? `已选 ${this.selectedPwdIds.length} 项` : '密码' },
        backIcon: {
          icon: $r('sys.symbol.chevron_backward'),
          isEnabled: true,
          action: (): void => {
            // 多选态返回先退出多选；否则退出整个密码页（详情的返回由
            // destination 自己的返回钮 / onBackPressed 处理）。
            if (this.selectMode) {
              this.exitPwdSelect();
            } else {
              this.onBack();
            }
          }
        },
        // 标题栏 menu：多选态显示「取消」；列表滚走搜索框后（searchFabVisible）
        // 在 ⋯ 左侧加「回到搜索」项——由标题栏自身渲染，天然浮于渐变模糊带
        // 之上且不拦截内容点击（内容层/overlay 两种挂法都翻过车，menu 是正解）。
        menu: this.selectMode
          ? {
            value: [
              {
                content: {
                  icon: $r('app.media.aura_close'),
                  label: '取消',
                  action: (): void => {
                    this.exitPwdSelect();
                  }
                }
              }
            ]
          }
          : (this.searchFabVisible && this.verified)
            ? {
              value: [
                {
                  content: {
                    icon: $r('app.media.chromium_search'),
                    label: '回到搜索',
                    action: (): void => {
                      this.scrollToSearch();
                    }
                  }
                },
                {
                  content: {
                    icon: $r('app.media.aura_more'),
                    label: '更多操作',
                    action: (): void => {
                      this.showMoreSheet();
                    }
                  }
                }
              ]
            }
            : {
              value: [
                {
                  content: {
                    icon: $r('app.media.aura_more'),
                    label: '更多操作',
                    action: (): void => {
                      this.showMoreSheet();
                    }
                  }
                }
              ]
            }
      },
      style: {
        // 官方渐变模糊滚动效果 + 沉浸光感材质（与 GlassPage 同一套）。
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: false
    })
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(false)
    .mode(NavigationMode.Stack)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .bindToScrollable([this.listScroller, this.detailScroller])
    .backgroundColor($r('app.color.page_background'))
    .navDestination(this.buildPasswordDestination)
    .width('100%')
    .height('100%')
  }

  // 1.0.160：详情页 destination（真路由栈推入）。编辑态是页内状态
  // （detailMode），返回先回查看态、不丢详情；查看态返回才弹栈回列表。
  @Builder
  private buildPasswordDestination(name: string, _param: Object): void {
    if (name !== 'detail') {
      HdsNavDestination() {
        Column().width('100%').height('100%')
      }
    } else {
      HdsNavDestination() {
        Column() {
          this.DetailView()
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16 })
      }
      .width('100%')
      .height('100%')
      .titleBar({
        content: {
          title: { mainTitle: '密码详情' },
          backIcon: {
            icon: $r('sys.symbol.chevron_backward'),
            isEnabled: true,
            action: (): void => {
              this.closeDetail();
            }
          },
          // 详情的「更多操作」菜单本就带 view!=='list' 守卫（死按钮），
          // 这里不再挂。
          menu: undefined
        },
        style: {
          scrollEffectOpts: {
            enableScrollEffect: true,
            scrollEffectType: ScrollEffectType.GRADIENT_BLUR
          },
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.ADAPTIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        },
        avoidLayoutSafeArea: true,
        enableComponentSafeArea: false
      })
      .titleMode(HdsNavDestinationTitleMode.MINI)
      .hideBackButton(false)
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .bindToScrollable([this.detailScroller])
      .backgroundColor($r('app.color.page_background'))
      .onBackPressed((): boolean => {
        this.closeDetail();
        return true;
      })
    }
  }
}

/*
 * 手机密码页（对齐 Lumie v2）。
 * 流程：进入先做本机身份验证（系统锁屏密码/指纹/人脸），通过后向引擎发
 * passwordAuthGranted {validMs:60000}，再拉 getSavedPasswords 列表；
 * 列表 -> 详情（编辑用户名/密码/备注，updatePassword；显示走 revealPassword；
 * 删除走 deletePassword）；顶部 ⋯ 菜单：导入密码（CSV）/ 导出密码（CSV）。
 * 导入导出对齐 Lumie v2：系统文件选择器 <-> 沙箱暂存 -> 引擎读写 -> 外壳清理。
 * 引擎回 authRequired 时回到验证门。应用退后台时由 AuraShell 发
 * passwordAuthReset 作废窗口。
 */
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { userAuth } from '@kit.UserAuthenticationKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { GlassPage, glassHeaderInsetVp, glassTopSafeVp } from './GlassPage';
import { MoreMenuDialog, MoreMenuItemSpec } from './MoreMenuDialog';
import {
  BrowserCommandPayload,
  PasswordCommandResultEvent,
  PasswordRevealedEvent,
  SavedPasswordItem,
  SavedPasswordsEvent
} from 'engine';
import { displayUrl, pickAndStageImportFile, saveExportedFile, deleteStagedFile } from './PanelBridge';
import { AuraChevron, AuraSectionLabel } from './LumieKit';

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

@Component
export struct PasswordsPanel {
  @StorageLink('auraPanelPasswords') @Watch('onPasswordsPayload') passwordsJson: string = '';
  @StorageLink('auraPanelPasswordSecret') @Watch('onSecretPayload') secretJson: string = '';
  @StorageLink('auraPanelPasswordResult') @Watch('onResultPayload') resultJson: string = '';
  @StorageLink('auraPanelPasswordIo') @Watch('onIoPayload') ioJson: string = '';
  @StorageLink('auraPanelEvent') @Watch('onPanelEvent') panelEventJson: string = '';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onBack: () => void = (): void => {};
  onClose: () => void = (): void => {};

  @State private items: SavedPasswordItem[] = [];
  // 试探法：组件创建即发 getSavedPasswords —— 引擎授权窗口（60s）内直接
  // 出列表（免重复验证）；未授权回 authRequired 再回验证门。
  @State private verified: boolean = true;
  private retryTimer: number = -1;
  private retryCount: number = 0;
  private pendingSeq: number = 0;
  @State private verifying: boolean = false;
  @State private verifyError: string = '';
  @State private loading: boolean = true;
  @State private view: string = 'list';
  @State private editId: string = '';
  // 详情页两态：查看（Lumie 风格行式 + 复制）默认；编辑单独进入。
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
    if (this.passwordsJson.length > 0) {
      try {
        const cached = JSON.parse(this.passwordsJson) as SavedPasswordsEvent;
        this.items = (cached.items ?? []) as SavedPasswordItem[];
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
          this.view = 'list';
          this.reload();
        } else if (command === 'updatePassword') {
          this.view = 'list';
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
    const saved = await saveExportedFile(context, stagedPath, 'Aura 密码.csv');
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
  }

  private closeDetail(): void {
    if (this.detailMode === 'edit') {
      // 编辑态返回先回查看态，不丢详情。
      this.detailMode = 'view';
      return;
    }
    this.view = 'list';
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

  // -- 导入 / 导出（对齐 Lumie v2） -------------------------------------------

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
  private PasswordRow(item: SavedPasswordItem, index: number) {
    Column() {
      Row({ space: 12 }) {
        Image($r('app.media.aura_lock'))
          .width(22)
          .height(22)
          .fillColor($r('app.color.icon_primary'))

        Column({ space: 2 }) {
          Text(displayUrl(item.origin))
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(item.username.length > 0 ? item.username : '（没有用户名）')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        AuraChevron()
      }
      .width('100%')
      .constraintSize({ minHeight: 60 })
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .onClick(() => {
        this.openDetail(item);
      })

      if (index < this.items.length - 1) {
        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 50 })
      }
    }
    .width('100%')
  }

  @Builder
  private ListView() {
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
      Scroll(this.listScroller) {
        Column() {
          Row({ space: 8 }) {
            Image($r('app.media.chromium_search'))
              .width(16)
              .height(16)
              .fillColor($r('app.color.icon_secondary'))
            TextInput({ text: this.searchText, placeholder: '搜索密码' })
              .layoutWeight(1)
              .height(38)
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .placeholderColor($r('app.color.text_secondary'))
              .backgroundColor(Color.Transparent)
              .onChange((value: string) => {
                this.searchText = value;
                this.recomputeFiltered();
              })
          }
          .width('100%')
          .height(40)
          .borderRadius(20)
          .backgroundColor($r('app.color.surface_secondary'))
          .padding({ left: 12, right: 12 })
          .margin({ bottom: 10 })

          if (this.filteredPasswords.length === 0) {
            Text('没有匹配的密码')
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 40 })
          }
          Column() {
            ForEach(this.filteredPasswords, (item: SavedPasswordItem, index: number) => {
              this.PasswordRow(item, index)
            }, (item: SavedPasswordItem): string => item.id)
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)

          Text('在网页上登录时，浏览器会询问是否保存密码；右上角可以导入、导出。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .padding({ left: 4, right: 4, top: 10 })
        }
        .width('100%')
        // 大标题带：滚动内容穿过「密码」大标题时逐渐虚化（见 GlassPage 文件头）。
        .padding({ top: glassHeaderInsetVp() })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }
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
          // 查看态（Lumie 风格）：行式布局 + 每行复制；编辑单独进入。
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
    .align(Alignment.TopStart)
  }

  // ⋯ 的子菜单改走系统 ActionSheet（本页是原生内容，系统弹窗可用）。
  // ⋯ 的子菜单：CustomDialog 承载（弹窗子窗口 = 沉浸材质允许区，真玻璃 +
  // 流光；形态对齐旧版 bindMenu：贴右上、标题行正下方弹出的小菜单卡）。
  private showMoreSheet(): void {
    if (this.view !== 'list') {
      return;
    }
    this.moreMenuDialog.open();
  }

  private moreMenuDialog: CustomDialogController = new CustomDialogController({
    builder: MoreMenuDialog({
      items: [
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
      ] as MoreMenuItemSpec[]
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
  // 导入模式弹窗（自绘）：先选增量/覆盖，再进文件选择器。
  @State private importDialogVisible: boolean = false;
  @State private importOverwrite: boolean = false;
  // 过滤结果落 @State（同 HistoryPanel：方法间接读 @State 不建立更新依赖）。
  @State private filteredPasswords: SavedPasswordItem[] = [];

  // 重算过滤结果（写入 @State）：搜索词变化与数据源变化处都要调用。
  private recomputeFiltered(): void {
    const q = this.searchText.trim().toLowerCase();
    if (q.length === 0) {
      this.filteredPasswords = this.items;
      return;
    }
    const out: SavedPasswordItem[] = [];
    for (const item of this.items) {
      if (item.origin.toLowerCase().includes(q) || item.username.toLowerCase().includes(q)) {
        out.push(item);
      }
    }
    this.filteredPasswords = out;
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
          .onClick(() => {
            this.importDialogVisible = false;
          })

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
        .margin({ left: 44, right: 44 })
      }
      .width('100%')
      .height('100%')
    }
  }

  build() {
    // 标题栏放进 Navigation（HarmonyOS 7 之后只有 Navigation 标题栏 / 底部
    // TabBar / 弹窗类还在沉浸光感的生效范围内）。右侧还有「更多」，故不用
    // GlassPage，自己包一层。
    GlassPage({
      title: this.view === 'detail' ? '密码详情' : '密码',
      scrollers: [this.listScroller, this.detailScroller],
      menus: {
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
      },
      onBack: (): void => {
        if (this.view === 'detail') {
          this.closeDetail();
        } else {
          this.onBack();
        }
      }
    }) {
    // body 包 Stack：导入模式弹窗等悬浮层挂这里（viewport 固定，遮罩盖满全屏）。
    Stack({ alignContent: Alignment.TopStart }) {
    Column() {
      if (!this.verified) {
        this.GateView()
      } else if (this.view === 'detail') {
        this.DetailView()
      } else {
        this.ListView()
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.page_background'))

    this.ImportDialog()
    }
    .width('100%')
    .height('100%')
    }
  }
}

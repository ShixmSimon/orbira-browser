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
import { GlassBackButton, GlassContentHeader, GLASS_TITLE_ZONE_VP } from './GlassPage';
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
  @State private verified: boolean = false;
  @State private verifying: boolean = false;
  @State private verifyError: string = '';
  @State private loading: boolean = true;
  @State private view: string = 'list';
  @State private editId: string = '';
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
    if (this.pendingAuthInstance !== null) {
      try {
        this.pendingAuthInstance.cancel();
      } catch (error) {
      }
      this.pendingAuthInstance = null;
    }
    this.cleanupPendingImport();
  }

  private cleanupPendingImport(): void {
    if (this.pendingImportPath.length > 0) {
      deleteStagedFile(this.pendingImportPath);
      this.pendingImportPath = '';
    }
  }

  private reload(): void {
    this.loading = true;
    this.requestSeq += 1;
    this.onCommand({ command: 'getSavedPasswords', requestId: this.requestSeq });
  }

  private onPasswordsPayload(): void {
    if (this.passwordsJson.length === 0) {
      return;
    }
    try {
      this.items = JSON.parse(this.passwordsJson) as SavedPasswordItem[];
      this.loading = false;
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

  private async startImport(): Promise<void> {
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
    AlertDialog.show({
      title: '导入密码',
      message: '从 Chrome、Edge、Firefox 导出的 CSV 文件导入。遇到已保存过的同名账号怎么处理？',
      autoCancel: true,
      primaryButton: {
        value: '保留原有',
        action: (): void => {
          this.runImport(false);
        }
      },
      secondaryButton: {
        value: '用导入的覆盖',
        action: (): void => {
          this.runImport(true);
        }
      }
    });
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
  private TitleBar() {
    Row({ space: 12 }) {
      GlassBackButton({
        onAction: (): void => {
          if (this.view === 'detail') {
            this.closeDetail();
          } else {
            this.onBack();
          }
        }
      })

      // 标题与返回钮并排（22fp，v1 版式），随 view 动态切换。
      Text(this.view === 'detail' ? '密码详情' : '密码')
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))

      Blank()

      if (this.view === 'list') {
        Button({ type: ButtonType.Circle }) {
          Image($r('app.media.aura_more'))
            .width(22)
            .height(22)
            .fillColor($r('app.color.icon_primary'))
        }
        .width(44)
        .height(44)
        .backgroundColor($r('app.color.surface_secondary'))
        .accessibilityText('更多操作')
        .bindMenu([
          {
            value: '导入密码',
            action: (): void => {
              this.startImport();
            }
          },
          {
            value: '导出密码',
            action: (): void => {
              this.startExport();
            }
          }
        ])
      }
    }
    .width('100%')
    .height(56)
  }

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
      Scroll() {
        Column() {
          AuraSectionLabel({ text: `已保存的密码 · ${this.items.length}` })

          Column() {
            ForEach(this.items, (item: SavedPasswordItem, index: number) => {
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
        .padding({ top: GLASS_TITLE_ZONE_VP })
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
    Scroll() {
      Column() {
        AuraSectionLabel({ text: displayUrl(this.editOrigin) })

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
            Row() {
              this.EditFieldLabel('密码')
              Blank()
              if (!this.revealed) {
                Text('显示')
                  .fontSize(13)
                  .fontColor($r('app.color.accent_primary'))
                  .onClick(() => {
                    this.revealForEdit();
                  })
              } else {
                Text('隐藏')
                  .fontSize(13)
                  .fontColor($r('app.color.accent_primary'))
                  .onClick(() => {
                    this.revealed = false;
                  })
              }
            }
            .width('100%')

            TextInput({
              text: this.editPassword,
              placeholder: this.revealed ? '不修改请留空' : '点"显示"载入已保存的密码'
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

        Button(this.busy ? '保存中…' : '保存')
          .width('100%')
          .height(46)
          .fontSize(16)
          .fontColor($r('app.color.on_accent'))
          .backgroundColor($r('app.color.accent_primary'))
          .borderRadius(12)
          .margin({ top: 16 })
          .enabled(!this.busy)
          .onClick(() => {
            this.saveEdit();
          })

        Button('删除这条密码')
          .width('100%')
          .height(46)
          .fontSize(16)
          .fontColor($r('app.color.danger'))
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(12)
          .margin({ top: 10 })
          .onClick(() => {
            const item = this.items.find((candidate: SavedPasswordItem): boolean =>
              candidate.id === this.editId);
            if (item !== undefined) {
              this.confirmRemove(item);
            }
          })
      }
      .width('100%')
      // 大标题带：滚动内容穿过「密码详情」大标题时逐渐虚化（见 GlassPage 文件头）。
      .padding({ top: GLASS_TITLE_ZONE_VP })
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .align(Alignment.TopStart)
  }

  build() {
    // 标题栏放进 Navigation（HarmonyOS 7 之后只有 Navigation 标题栏 / 底部
    // TabBar / 弹窗类还在沉浸光感的生效范围内）。右侧还有「更多」，故不用
    // GlassPage，自己包一层。
    Navigation() {
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
    .padding({ left: 16, right: 16, bottom: 16 })
    .backgroundColor($r('app.color.page_background'))

    // 大标题带已取消：内容区顶部只留渐隐带（GlassContentHeader）。
    GlassContentHeader()
    }
    .width('100%')
    .height('100%')
    }
    .hideBackButton(true)
    .titleMode(NavigationTitleMode.Mini)
    .title(this.TitleBar)
    .mode(NavigationMode.Stack)
    .backgroundColor($r('app.color.page_background'))
    .width('100%')
    .height('100%')
  }
}

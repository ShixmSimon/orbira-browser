/*
 * 手机密码页（参考外壳扩展）。
 * 流程：进入先做本机身份验证（系统锁屏密码/指纹/人脸），通过后向引擎发
 * passwordAuthGranted {validMs:60000}，再拉 getSavedPasswords 列表；
 * 显示/删除走 revealPassword / deletePassword；引擎回 authRequired 时
 * 回到验证门。应用退后台时由 AuraShell 发 passwordAuthReset 作废窗口。
 */
import { pasteboard } from '@kit.BasicServicesKit';
import { userAuth } from '@kit.UserAuthenticationKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import {
  BrowserCommandPayload,
  PasswordCommandResultEvent,
  PasswordRevealedEvent,
  SavedPasswordItem,
  SavedPasswordsEvent
} from 'engine';
import { displayUrl } from './PanelBridge';

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

@Component
export struct PasswordsPanel {
  @StorageLink('auraPanelPasswords') @Watch('onPasswordsPayload') passwordsJson: string = '';
  @StorageLink('auraPanelPasswordSecret') @Watch('onSecretPayload') secretJson: string = '';
  @StorageLink('auraPanelPasswordResult') @Watch('onResultPayload') resultJson: string = '';
  @StorageLink('auraPanelEvent') @Watch('onPanelEvent') panelEventJson: string = '';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onBack: () => void = (): void => {};
  onClose: () => void = (): void => {};

  @State private items: SavedPasswordItem[] = [];
  @State private verified: boolean = false;
  @State private verifying: boolean = false;
  @State private verifyError: string = '';
  @State private loading: boolean = true;
  private requestSeq: number = 0;
  private pendingAuthInstance: userAuth.UserAuthInstance | null = null;

  aboutToDisappear(): void {
    if (this.pendingAuthInstance !== null) {
      try {
        this.pendingAuthInstance.cancel();
      } catch (error) {
      }
      this.pendingAuthInstance = null;
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
      if (secret.length > 0) {
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
          try {
            const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, secret);
            pasteboard.getSystemPasteboard().setData(data);
          } catch (error) {
          }
        }
      },
      secondaryButton: {
        value: '关闭',
        action: (): void => {
        }
      }
    });
  }

  private reveal(item: SavedPasswordItem): void {
    this.requestSeq += 1;
    this.onCommand({ command: 'revealPassword', requestId: this.requestSeq, id: item.id });
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
  private GateView() {
    Column({ space: 12 }) {
      Text('验证身份以管理密码')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
      Text('查看已保存的密码前，先证明这是你的手机。')
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
      if (this.verifyError.length > 0) {
        Text(this.verifyError)
          .fontSize(13)
          .fontColor('#E24B4A')
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
      Row({ space: 10 }) {
        Column({ space: 3 }) {
          Text(displayUrl(item.origin))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
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

        Row({ space: 6 }) {
          this.ActionChip('显示', (): void => this.reveal(item))
          this.DangerChip('删除', (): void => this.confirmRemove(item))
        }
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })

      if (index < this.items.length - 1) {
        Divider()
          .color($r('app.color.divider'))
      }
    }
    .width('100%')
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

        Text('密码')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 12 })

        Blank()
      }
      .width('100%')
      .height(52)

      if (!this.verified) {
        this.GateView()
      } else if (this.items.length === 0) {
        Column() {
          Text(this.loading ? '加载中…' : '还没有保存过密码')
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Text(`已保存 · ${this.items.length}`)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .margin({ top: 6, bottom: 8 })
        Scroll() {
          Column() {
            ForEach(this.items, (item: SavedPasswordItem, index: number) => {
              this.PasswordRow(item, index)
            }, (item: SavedPasswordItem): string => item.id)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.TopStart)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 20, right: 20, bottom: 16 })
    .backgroundColor($r('app.color.surface_primary'))
  }
}

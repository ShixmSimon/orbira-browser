/*
 * 华为账号页（对齐 Lumie v2：设置里的账号卡 -> 登录 / 已登录 + 退出登录）。
 *
 * 登录界面用 Account Kit 的 LoginWithHuaweiIDButton（华为账号官方登录按钮组件）；
 * 授权结果只拿 openID / unionID 落本地（见 utils/account/HuaweiAccountService），
 * "退出登录"只清本地状态。
 * 注意：LoginWithHuaweiIDButton 需要在 AGC（AppGallery Connect）为应用配置
 * 华为账号服务后才能在真机走通授权；未配置时点击会回错误码，这里如实提示。
 */
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { loginComponentManager, LoginWithHuaweiIDButton } from '@kit.AccountKit';
import { AuraSectionLabel } from './LumieKit';
import { glassHeaderInsetVp } from './GlassPage';
import {
  clearAccount,
  HuaweiAccountInfo,
  loadAccount,
  saveAccount
} from '../../utils/account/HuaweiAccountService';

@Component
export struct HuaweiAccountView {
  onBack: () => void = (): void => {};

  @StorageLink('auraHuaweiAccount') accountJson: string = '';
  @State private signingIn: boolean = false;
  @State private controller: loginComponentManager.LoginWithHuaweiIDButtonController =
    new loginComponentManager.LoginWithHuaweiIDButtonController()
      .onClickLoginWithHuaweiIDButton((error: BusinessError,
        response: loginComponentManager.HuaweiIDCredential): void => {
        this.onLoginResult(error, response);
      });

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.Context | undefined;
    if (context) {
      loadAccount(context);
    }
  }

  private accountInfo(): HuaweiAccountInfo {
    if (this.accountJson.length === 0) {
      return { signedIn: false, openID: '', unionID: '' };
    }
    try {
      const value = JSON.parse(this.accountJson) as HuaweiAccountInfo;
      return {
        signedIn: value.signedIn === true,
        openID: String(value.openID ?? ''),
        unionID: String(value.unionID ?? '')
      };
    } catch (error) {
      return { signedIn: false, openID: '', unionID: '' };
    }
  }

  private onLoginResult(error: BusinessError,
    response: loginComponentManager.HuaweiIDCredential): void {
    this.signingIn = false;
    const context = this.getUIContext().getHostContext() as common.Context | undefined;
    if (error) {
      AlertDialog.show({
        title: '没能登录',
        message: `华为账号没有登录成功，请稍后再试。（错误码 ${error.code}）`,
        confirm: {
          value: '好的',
          action: (): void => {
          }
        }
      });
      return;
    }
    if (!context) {
      return;
    }
    const info: HuaweiAccountInfo = {
      signedIn: true,
      openID: String(response.openID ?? ''),
      unionID: String(response.unionID ?? '')
    };
    saveAccount(context, info);
  }

  private confirmSignOut(): void {
    AlertDialog.show({
      title: '退出华为账号？',
      message: '只在浏览器里退出，系统的华为账号和云空间里的数据都不受影响。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '退出登录',
        fontColor: '#E24B4A',
        action: (): void => {
          const context = this.getUIContext().getHostContext() as common.Context | undefined;
          if (context) {
            clearAccount(context);
          }
        }
      }
    });
  }

  // 标题栏（含圆形玻璃返回钮）由 SettingsPanel 的 GlassPage 统一提供 ——
  // 本页是设置的二级页，共用同一条 Navigation 标题栏，自己再画一条会双标题，
  // 而且自绘标题栏落在内容区，挂材质也没用（HarmonyOS 7 生效范围）。
  build() {
    Column() {
      if (this.accountInfo().signedIn) {
        AuraSectionLabel({ text: '账号', tightTop: true })
        Column() {
          Row({ space: 12 }) {
            Image($r('app.media.aura_account'))
              .width(22)
              .height(22)
              .fillColor($r('app.color.icon_primary'))
            Column({ space: 2 }) {
              Text('已登录华为账号')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Text('书签和密码可以在登录同一华为账号的设备间同步（云同步功能陆续开放）')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
                .maxLines(2)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        }
        .width('100%')
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))
        .clip(true)

        AuraSectionLabel({ text: '操作' })
        Column() {
          Row() {
            Text('退出登录')
              .fontSize(16)
              .fontColor($r('app.color.danger'))
            Blank()
          }
          .width('100%')
          .height(56)
          .padding({ left: 16, right: 16 })
          .onClick(() => {
            this.confirmSignOut();
          })
        }
        .width('100%')
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))
        .clip(true)

        Text('退出只会清掉浏览器里的登录状态，系统里的华为账号不受影响。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ left: 4, right: 4, top: 10 })
      } else {
        AuraSectionLabel({ text: '登录', tightTop: true })
        Column() {
          Row({ space: 12 }) {
            Image($r('app.media.aura_account'))
              .width(22)
              .height(22)
              .fillColor($r('app.color.icon_primary'))
            Column({ space: 2 }) {
              Text('华为账号')
                .fontSize(16)
                .fontColor($r('app.color.text_primary'))
              Text('登录后同步书签和密码')
                .fontSize(12)
                .fontColor($r('app.color.text_secondary'))
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 12, bottom: 12 })
        }
        .width('100%')
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))
        .clip(true)

        Column() {
          LoginWithHuaweiIDButton({
            params: {
              style: loginComponentManager.Style.BUTTON_WHITE_OUTLINE,
              borderRadius: 12,
              supportDarkMode: true
            },
            controller: this.controller
          })
            .width('100%')
        }
        .width('100%')
        .margin({ top: 16 })

        Text('需要设备已经登录华为账号；登录按钮由华为账号服务提供。')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .padding({ left: 4, right: 4, top: 10 })
      }
    }
    .width('100%')
    .height('100%')
    // top：给内容区顶部的「华为账号」大标题带让位（设置二级页共用 GlassPage 头部）。
    .padding({ left: 16, right: 16, top: glassHeaderInsetVp(), bottom: 16 })
    .backgroundColor($r('app.color.page_background'))
  }
}

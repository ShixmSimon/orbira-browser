/*
 * 扫一扫：Scan Kit 的系统扫码页（startScanForResult），一次调用返回识别文本。
 * 相机是 user_grant 权限，先向系统申请再拉起扫码。
 */
import { abilityAccessCtrl, Permissions, common } from '@kit.AbilityKit';
import { scanBarcode } from '@kit.ScanKit';

export class ScanService {
  // Returns the decoded text, or '' when the camera permission was denied,
  // the user backed out of the scanner, or nothing was recognised.
  static async scanOnce(context: common.UIAbilityContext): Promise<string> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const perms: Array<Permissions> = ['ohos.permission.CAMERA'];
      const grant = await atManager.requestPermissionsFromUser(context, perms);
      let granted = false;
      for (const r of grant.authResults) {
        if (r === 0) {
          granted = true;
        }
      }
      if (!granted) {
        return '';
      }
      const result = await scanBarcode.startScanForResult(context);
      return result && result.originalValue ? result.originalValue : '';
    } catch (error) {
      console.error('Scan failed:', JSON.stringify(error));
      return '';
    }
  }
}

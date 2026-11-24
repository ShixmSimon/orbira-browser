/*
 * 网页发起的原生交互应答层：站点权限、<select> 弹层、日期时间输入、
 * 通讯录选择、语音识别。引擎把这些请求的 JSON 事件推给外壳，外壳在此
 * 画系统级面板，并用对应的 xxxResult 命令回一次（且只回一次）。
 *
 * 请求排在同一个 AppStorage 队列里（AuraShell 写入），一屏只显示最早一条；
 * 答完或引擎撤销后由 AuraShell 出队。用队列而不是单条状态，是因为同一页
 * 连续请求两次时后一条不能把前一条吞掉——引擎还在等前一条的应答。
 */
import {
  BrowserCommandPayload,
  PickedContact,
  SelectPopupOption,
  SitePermissionDecision
} from 'engine';

const KIND_PERMISSION: string = 'permission';
const KIND_SELECT: string = 'select';
const KIND_DATE_TIME: string = 'dateTime';
const KIND_CONTACTS: string = 'contacts';
const KIND_SPEECH: string = 'speech';

function permissionLabel(value: string): string {
  if (value === 'location') {
    return '位置';
  }
  if (value === 'camera') {
    return '相机';
  }
  if (value === 'microphone') {
    return '麦克风';
  }
  if (value === 'notifications') {
    return '通知';
  }
  if (value === 'clipboard') {
    return '剪贴板';
  }
  return value;
}

function dateTimeHint(inputType: string): string {
  if (inputType === 'datetime-local') {
    return '年-月-日T时:分，例如 2026-11-24T09:30';
  }
  if (inputType === 'month') {
    return '年-月，例如 2026-11';
  }
  if (inputType === 'time') {
    return '时:分，例如 09:30';
  }
  if (inputType === 'week') {
    return '年-W周，例如 2026-W48';
  }
  return '年-月-日，例如 2026-11-24';
}

@Component
export struct SitePromptOverlays {
  @StorageLink('auraSitePromptQueue') @Watch('onQueueChanged') queueJson: string = '';
  onAnswer: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onResolved: (requestId: number) => void = (_requestId: number): void => {};

  @State private kind: string = '';
  @State private requestId: number = 0;
  @State private origin: string = '';
  @State private isSecure: boolean = false;
  @State private permissions: string[] = [];
  @State private options: SelectPopupOption[] = [];
  @State private selectedIndices: number[] = [];
  @State private multiple: boolean = false;
  @State private inputType: string = 'date';
  @State private inputValue: string = '';
  @State private minValue: string = '';
  @State private maxValue: string = '';
  @State private properties: string[] = [];
  @State private contacts: PickedContact[] = [];
  @State private contactName: string = '';
  @State private contactEmail: string = '';
  @State private contactTel: string = '';
  @State private contactAddress: string = '';
  @State private speechLanguage: string = '';
  @State private speechText: string = '';
  private shownId: number = -1;

  aboutToAppear(): void {
    this.onQueueChanged();
  }

  private asStrings(value: Object): string[] {
    const result: string[] = [];
    try {
      const raw = value as Object[];
      for (const item of raw) {
        result.push(String(item));
      }
    } catch (error) {
    }
    return result;
  }

  private asRecords(value: Object): Record<string, Object>[] {
    const result: Record<string, Object>[] = [];
    try {
      const raw = value as Object[];
      for (const item of raw) {
        result.push(item as Record<string, Object>);
      }
    } catch (error) {
    }
    return result;
  }

  private head(): Record<string, Object> | null {
    try {
      const root = JSON.parse(this.queueJson) as Record<string, Object>;
      const items = root['items'] as Object[];
      if (items.length > 0) {
        return items[0] as Record<string, Object>;
      }
    } catch (error) {
    }
    return null;
  }

  private onQueueChanged(): void {
    const item = this.head();
    if (item === null) {
      this.kind = '';
      this.shownId = -1;
      return;
    }
    const id: number = Number(item['requestId'] ?? 0);
    // 同一条请求的队列刷新（新请求入队、旧请求出队）不应冲掉用户正在输入
    // 的内容；只有换了请求才重置表单。
    if (id === this.shownId && this.kind.length > 0) {
      return;
    }
    this.shownId = id;
    this.requestId = id;
    const name: string = String(item['event'] ?? '');
    this.origin = String(item['origin'] ?? '');
    this.isSecure = item['isSecure'] === true;
    this.multiple = item['multiple'] === true;
    this.minValue = String(item['min'] ?? '');
    this.maxValue = String(item['max'] ?? '');
    this.inputValue = String(item['value'] ?? '');
    this.permissions = this.asStrings(item['webPermissions'] ?? []);
    this.properties = this.asStrings(item['properties'] ?? []);
    this.speechLanguage = String(item['language'] ?? '');
    this.contacts = [];
    this.contactName = '';
    this.contactEmail = '';
    this.contactTel = '';
    this.contactAddress = '';
    this.speechText = '';
    this.selectedIndices = [];
    const rawOptions: Record<string, Object>[] = this.asRecords(item['options'] ?? []);
    const options: SelectPopupOption[] = [];
    for (const raw of rawOptions) {
      const option: SelectPopupOption = {
        label: String(raw['label'] ?? ''),
        type: raw['type'] === 'group' || raw['type'] === 'separator' ? raw['type'] : 'option',
        enabled: raw['enabled'] !== false,
        checked: raw['checked'] === true
      } as SelectPopupOption;
      options.push(option);
      if (option.checked) {
        this.selectedIndices.push(options.length - 1);
      }
    }
    this.options = options;
    const selected: number = Number(item['selectedIndex'] ?? -1);
    if (this.selectedIndices.length === 0 && selected >= 0 && selected < options.length) {
      this.selectedIndices = [selected];
    }
    if (name === 'sitePermissionRequested') {
      this.kind = KIND_PERMISSION;
    } else if (name === 'selectPopupRequested') {
      this.kind = KIND_SELECT;
    } else if (name === 'dateTimePickerRequested') {
      this.kind = KIND_DATE_TIME;
      const type: string = String(item['inputType'] ?? 'date');
      this.inputType = type === 'datetime-local' || type === 'month' || type === 'time' || type === 'week'
        ? type : 'date';
    } else if (name === 'contactsPickerRequested') {
      this.kind = KIND_CONTACTS;
    } else if (name === 'speechRecognitionRequested') {
      this.kind = KIND_SPEECH;
    } else {
      this.kind = '';
    }
  }

  private finish(command: BrowserCommandPayload, id: number): void {
    this.onAnswer(command);
    this.onResolved(id);
  }

  private answerPermission(decision: SitePermissionDecision): void {
    this.finish({ command: 'sitePermissionDecision', requestId: this.requestId, decision: decision },
      this.requestId);
  }

  private answerSelect(canceled: boolean): void {
    if (canceled) {
      this.finish({ command: 'selectPopupResult', requestId: this.requestId, canceled: true },
        this.requestId);
      return;
    }
    this.finish({ command: 'selectPopupResult', requestId: this.requestId, indices: this.selectedIndices.slice() },
      this.requestId);
  }

  private pickOption(index: number): void {
    if (index < 0 || index >= this.options.length) {
      return;
    }
    if (!this.multiple) {
      this.selectedIndices = [index];
      this.answerSelect(false);
      return;
    }
    const chosen: number[] = this.selectedIndices.slice();
    const at: number = chosen.indexOf(index);
    if (at >= 0) {
      chosen.splice(at, 1);
    } else {
      chosen.push(index);
    }
    this.selectedIndices = chosen;
  }

  private isPicked(index: number): boolean {
    return this.selectedIndices.indexOf(index) >= 0;
  }

  private validDateTime(): boolean {
    const value: string = this.inputValue.trim();
    if (value.length === 0) {
      return false;
    }
    if (this.inputType === 'date') {
      return new RegExp('^\\d{4}-\\d{2}-\\d{2}$').test(value);
    }
    if (this.inputType === 'datetime-local') {
      return new RegExp('^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}(:\\d{2})?$').test(value);
    }
    if (this.inputType === 'month') {
      return new RegExp('^\\d{4}-\\d{2}$').test(value);
    }
    if (this.inputType === 'time') {
      return new RegExp('^\\d{2}:\\d{2}(:\\d{2})?$').test(value);
    }
    return new RegExp('^\\d{4}-W\\d{2}$').test(value);
  }

  private answerDateTime(canceled: boolean, clear: boolean): void {
    if (canceled) {
      this.finish({ command: 'dateTimePickerResult', requestId: this.requestId, canceled: true },
        this.requestId);
      return;
    }
    if (clear) {
      this.finish({ command: 'dateTimePickerResult', requestId: this.requestId, value: '' },
        this.requestId);
      return;
    }
    if (!this.validDateTime()) {
      this.getUIContext().getPromptAction().showToast({
        message: `请按格式填写：${dateTimeHint(this.inputType)}`,
        duration: 2500
      });
      return;
    }
    this.finish({ command: 'dateTimePickerResult', requestId: this.requestId, value: this.inputValue.trim() },
      this.requestId);
  }

  private splitValues(value: string): string[] {
    const parts: string[] = value.split(/[,，;；\n]+/);
    const result: string[] = [];
    for (const part of parts) {
      const trimmed: string = part.trim();
      if (trimmed.length > 0) {
        result.push(trimmed);
      }
    }
    return result;
  }

  private currentContact(): PickedContact | null {
    const name: string[] = this.contactName.trim().length > 0 ? this.splitValues(this.contactName) : [];
    const email: string[] = this.contactEmail.trim().length > 0 ? this.splitValues(this.contactEmail) : [];
    const tel: string[] = this.contactTel.trim().length > 0 ? this.splitValues(this.contactTel) : [];
    const address: string[] = this.contactAddress.trim().length > 0 ? this.splitValues(this.contactAddress) : [];
    if (name.length === 0 && email.length === 0 && tel.length === 0 && address.length === 0) {
      return null;
    }
    const contact: PickedContact = {} as PickedContact;
    if (name.length > 0) {
      contact.name = name;
    }
    if (email.length > 0) {
      contact.email = email;
    }
    if (tel.length > 0) {
      contact.tel = tel;
    }
    if (address.length > 0) {
      contact.address = address;
    }
    return contact;
  }

  private addContact(): void {
    const contact = this.currentContact();
    if (contact === null) {
      this.getUIContext().getPromptAction().showToast({ message: '请至少填写一项', duration: 2000 });
      return;
    }
    this.contacts = this.contacts.concat([contact]);
    this.contactName = '';
    this.contactEmail = '';
    this.contactTel = '';
    this.contactAddress = '';
  }

  private answerContacts(canceled: boolean): void {
    if (canceled) {
      this.finish({ command: 'contactsPickerResult', requestId: this.requestId, canceled: true },
        this.requestId);
      return;
    }
    const current = this.currentContact();
    const chosen: PickedContact[] = current === null ? this.contacts.slice() : this.contacts.concat([current]);
    if (chosen.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '请至少填写一项', duration: 2000 });
      return;
    }
    this.finish({ command: 'contactsPickerResult', requestId: this.requestId, contacts: chosen },
      this.requestId);
  }

  private answerSpeech(text: string): void {
    const id: number = this.requestId;
    this.onAnswer({ command: 'speechRecognitionEvent', requestId: id, speechEvent: 'audioStart' });
    this.onAnswer({
      command: 'speechRecognitionEvent',
      requestId: id,
      speechEvent: 'result',
      transcript: text,
      isFinal: true,
      confidence: 1
    });
    this.onAnswer({ command: 'speechRecognitionEvent', requestId: id, speechEvent: 'end' });
    this.onResolved(id);
  }

  private failSpeech(error: string): void {
    const id: number = this.requestId;
    this.onAnswer({ command: 'speechRecognitionEvent', requestId: id, speechEvent: 'error', error: error });
    this.onAnswer({ command: 'speechRecognitionEvent', requestId: id, speechEvent: 'end' });
    this.onResolved(id);
  }

  private dismiss(): void {
    if (this.kind === KIND_PERMISSION) {
      this.answerPermission('dismiss');
    } else if (this.kind === KIND_SELECT) {
      this.answerSelect(true);
    } else if (this.kind === KIND_DATE_TIME) {
      this.answerDateTime(true, false);
    } else if (this.kind === KIND_CONTACTS) {
      this.answerContacts(true);
    } else if (this.kind === KIND_SPEECH) {
      this.failSpeech('aborted');
    }
  }

  private title(): string {
    if (this.kind === KIND_PERMISSION) {
      return '网站权限请求';
    }
    if (this.kind === KIND_SELECT) {
      return '选择一个选项';
    }
    if (this.kind === KIND_DATE_TIME) {
      return '选择日期和时间';
    }
    if (this.kind === KIND_CONTACTS) {
      return '选择联系人';
    }
    return '语音输入';
  }

  @Builder
  private PromptContent() {
    if (this.kind === KIND_PERMISSION) {
      Column({ space: 8 }) {
        ForEach(this.permissions, (permission: string): void => {
          Row() {
            Text(permissionLabel(permission))
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 9, bottom: 9 })
          .borderRadius(10)
          .backgroundColor($r('app.color.surface_secondary'))
        }, (permission: string): string => permission)
      }
      .width('100%')
    } else if (this.kind === KIND_SELECT) {
      Column({ space: 2 }) {
        ForEach(this.options, (option: SelectPopupOption, index: number): void => {
          if (option.type === 'group') {
            Text(option.label)
              .fontSize(12)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
              .padding({ left: 12, top: 10, bottom: 4 })
          } else if (option.type === 'separator') {
            Divider().color($r('app.color.divider')).margin({ top: 6, bottom: 6 })
          } else {
            Row({ space: 10 }) {
              Text(option.label)
                .fontSize(15)
                .fontColor(option.enabled ?
                  $r('app.color.text_primary') : $r('app.color.text_secondary'))
                .layoutWeight(1)
              if (this.isPicked(index)) {
                Text('✓')
                  .fontSize(16)
                  .fontColor($r('app.color.accent_primary'))
              }
            }
            .width('100%')
            .constraintSize({ minHeight: 44 })
            .padding({ left: 12, right: 12 })
            .borderRadius(8)
            .opacity(option.enabled ? 1 : 0.45)
            .onClick(() => {
              if (option.enabled) {
                this.pickOption(index);
              }
            })
          }
        }, (option: SelectPopupOption, index: number): string => `${index}-${option.label}`)
      }
      .width('100%')
    } else if (this.kind === KIND_DATE_TIME) {
      Column({ space: 10 }) {
        Text(dateTimeHint(this.inputType))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        TextInput({ text: this.inputValue, placeholder: dateTimeHint(this.inputType) })
          .width('100%')
          .height(44)
          .fontSize(15)
          .onChange((value: string): void => {
            this.inputValue = value;
          })
        if (this.minValue.length > 0 || this.maxValue.length > 0) {
          Text(`可选范围：${this.minValue} ~ ${this.maxValue}`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
      }
      .width('100%')
    } else if (this.kind === KIND_CONTACTS) {
      Column({ space: 8 }) {
        if (this.properties.indexOf('name') >= 0 || this.properties.length === 0) {
          TextInput({ placeholder: '姓名' })
            .width('100%').height(44).fontSize(15)
            .onChange((value: string): void => {
              this.contactName = value;
            })
        }
        if (this.properties.indexOf('email') >= 0 || this.properties.length === 0) {
          TextInput({ placeholder: '邮箱' })
            .width('100%').height(44).fontSize(15)
            .onChange((value: string): void => {
              this.contactEmail = value;
            })
        }
        if (this.properties.indexOf('tel') >= 0 || this.properties.length === 0) {
          TextInput({ placeholder: '电话' })
            .width('100%').height(44).fontSize(15)
            .onChange((value: string): void => {
              this.contactTel = value;
            })
        }
        if (this.properties.indexOf('address') >= 0 || this.properties.length === 0) {
          TextInput({ placeholder: '地址' })
            .width('100%').height(44).fontSize(15)
            .onChange((value: string): void => {
              this.contactAddress = value;
            })
        }
        if (this.contacts.length > 0) {
          Text(`已添加 ${this.contacts.length} 位联系人`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        Text('多个值用逗号分隔')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
    } else if (this.kind === KIND_SPEECH) {
      Column({ space: 10 }) {
        Text(this.speechLanguage.length > 0 ? `识别语言：${this.speechLanguage}` : '语音识别')
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
        TextInput({ placeholder: '输入识别结果' })
          .width('100%').height(44).fontSize(15)
          .onChange((value: string): void => {
            this.speechText = value;
          })
      }
      .width('100%')
    }
  }

  @Builder
  private PromptActions() {
    // 权限有四个动作，两行两列对齐排布；其余面板保持右对齐横排。
    // 用 Row + layoutWeight 均分，避免 Flex 换行后长短不一。
    if (this.kind === KIND_PERMISSION) {
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Button('忽略本次').layoutWeight(1).onClick(() => this.answerPermission('dismiss'))
          Button('拒绝').layoutWeight(1).onClick(() => this.answerPermission('block'))
        }
        .width('100%')
        Row({ space: 8 }) {
          Button('允许一次').layoutWeight(1).onClick(() => this.answerPermission('allowOnce'))
          if (this.isSecure) {
            Button('始终允许').layoutWeight(1).onClick(() => this.answerPermission('allowAlways'))
          }
        }
        .width('100%')
      }
      .width('100%')
    } else {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.End }) {
      if (this.kind === KIND_SELECT) {
        Button('取消').margin({ left: 8, top: 6 }).onClick(() => this.answerSelect(true))
        if (this.multiple) {
          Button('确定').margin({ left: 8, top: 6 }).onClick(() => this.answerSelect(false))
        }
      } else if (this.kind === KIND_DATE_TIME) {
        Button('取消').margin({ left: 8, top: 6 }).onClick(() => this.answerDateTime(true, false))
        Button('清空').margin({ left: 8, top: 6 }).onClick(() => this.answerDateTime(false, true))
        Button('确定').margin({ left: 8, top: 6 }).onClick(() => this.answerDateTime(false, false))
      } else if (this.kind === KIND_CONTACTS) {
        Button('取消').margin({ left: 8, top: 6 }).onClick(() => this.answerContacts(true))
        if (this.multiple || this.contacts.length > 0) {
          Button('再添加一位').margin({ left: 8, top: 6 }).onClick(() => this.addContact())
        }
        Button('确定').margin({ left: 8, top: 6 }).onClick(() => this.answerContacts(false))
      } else if (this.kind === KIND_SPEECH) {
        Button('取消').margin({ left: 8, top: 6 }).onClick(() => this.failSpeech('aborted'))
        Button('无结果').margin({ left: 8, top: 6 }).onClick(() => this.failSpeech('no-speech'))
        Button('完成').margin({ left: 8, top: 6 }).onClick(() => this.answerSpeech(this.speechText.trim()))
      }
      }
      .width('100%')
    }
  }

  build() {
    // 没有请求时整个组件都不存在：若只让内层 if 为空、外层留下全屏 Stack，
    // 它会盖在浏览器层之上吞掉主页磁贴与底栏的点击（真机实测）。
    if (this.kind.length > 0) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#99000000')
          .onClick(() => {
            this.dismiss();
          })
        Column({ space: 10 }) {
          Text(this.title())
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          if (this.kind === KIND_PERMISSION || this.kind === KIND_SPEECH) {
            Text(this.origin)
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
          }
          Scroll() {
            Column() {
              this.PromptContent()
            }
            .width('100%')
          }
          .width('100%')
          // 不能 layoutWeight(1)：那会把 Scroll 撑满剩余高度，权限项只有两行
          // 时弹窗也跟着变成接近整屏（真机实测）。高度交给内容，最多 220vp。
          .constraintSize({ maxHeight: 220 })
          .scrollBar(BarState.Off)
          this.PromptActions()
        }
        .width('88%')
        .constraintSize({ maxHeight: '78%' })
        .padding(18)
        .borderRadius(20)
        .backgroundColor($r('app.color.card_background'))
      }
      .width('100%')
      .height('100%')
    }
  }
}

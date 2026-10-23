import { BrowserCommandPayload, BrowserRuntimeEvent, ContextMenuAction } from 'engine';
import { hasSystemPlainText, showSystemPasteDialog } from './SystemPasteDialog';

// Long-press / right-click menus on the phone (2026-10-09 v13).
//
// The engine does not draw this menu: the startup config forces contextMenu
// 'shell', so the engine sends contextMenuRequested and waits for exactly one
// reply -- contextMenuAction (a choice) or contextMenuDismissed (closed).
// This module keeps the half that is not UI: which label goes on each action
// the engine offered, which entry needs the system clipboard dialog. The shell
// then draws a card of its own from the model (MobileBrowserOverlay's
// ContextMenuLayer). It used to open the system action sheet instead -- the
// protocol was right but the sheet read as "the native UI" to the reader.
//
// While the menu is open the engine may send contextMenuActionsChanged (the
// "copy link to highlight" entry lights up one round trip late); merge it with
// updateContextMenuModel.
//
// Phones draw the card; tablets and 2in1 have no such card in their UI yet and
// keep the system action sheet below (showContextMenuSheet).

const ACTION_LABELS: Record<ContextMenuAction, string> = {
  'openLinkInNewTab': '在新标签页中打开',
  'copyLinkAddress': '复制链接地址',
  'copyLinkText': '复制链接文字',
  'saveLinkAs': '下载链接',
  'openImageInNewTab': '在新标签页中打开图片',
  'saveImageAs': '保存图片',
  'copyImage': '复制图片',
  'copyImageAddress': '复制图片地址',
  'toggleLoop': '循环播放',
  'toggleControls': '显示控件',
  'openMediaInNewTab': '在新标签页中打开',
  'saveMediaAs': '保存',
  'copyMediaAddress': '复制地址',
  'copyVideoFrame': '复制视频帧',
  'pictureInPicture': '画中画',
  'copy': '复制',
  'cut': '剪切',
  'paste': '粘贴',
  'selectAll': '全选',
  'searchSelection': '搜索',
  'openLinkInIncognito': '在无痕窗口中打开',
  'copyLinkToHighlight': '复制指向所选文字的链接',
  'pasteAsPlainText': '粘贴为纯文本',
  'delete': '删除',
  'undo': '撤销',
  'redo': '重做',
  'suggestPassword': '建议强密码',
  'selectSavedPassword': '选择已保存的密码',
  'managePasswords': '管理密码',
  'spellSuggestion:0': '',
  'spellSuggestion:1': '',
  'spellSuggestion:2': '',
  'spellSuggestion:3': '',
  'spellSuggestion:4': '',
  'addToDictionary': '添加到词典',
  'shareLink': '分享链接',
  // Never shown: the shell's own "share image" and "look up image" run it.
  'imageToFile': ''
};

export interface ContextMenuItem {
  action: ContextMenuAction;
  label: string;
}

// What the shell's own card renders. Everything here is plain data so it can
// travel through AppStorage as JSON.
export interface ContextMenuModel {
  requestId: number;
  // Where the press was, in vp in the window. The shell anchors the card to it.
  x: number;
  y: number;
  title: string;
  subtitle: string;
  items: ContextMenuItem[];
  // The browser process cannot read the clipboard: "paste" opens the system
  // plain-text dialog and comes back through insertText. True when this menu
  // should carry that entry.
  systemPaste: boolean;
  // Raw payload for the copy actions the shell runs itself (shellCopyTextFor):
  // the engine's own copies show a native toast pinned to the status bar that
  // an immersive window clips in half, so plain-text copies never reach it.
  linkUrl: string;
  linkText: string;
  srcUrl: string;
  selectionText: string;
}

export const EMPTY_CONTEXT_MENU_MODEL: ContextMenuModel = {
  requestId: 0,
  x: 0,
  y: 0,
  title: '',
  subtitle: '',
  items: [],
  systemPaste: false,
  linkUrl: '',
  linkText: '',
  srcUrl: '',
  selectionText: ''
};

function labelFor(event: BrowserRuntimeEvent, action: ContextMenuAction): string {
  const flags = event.mediaFlags;
  // A spelling suggestion is labelled with the word it suggests, which only
  // the event knows.
  if (action.startsWith('spellSuggestion:')) {
    const index = Number.parseInt(action.substring('spellSuggestion:'.length), 10);
    const suggestions = event.spellSuggestions;
    return suggestions && index >= 0 && index < suggestions.length
      ? suggestions[index] : '';
  }
  if (action === 'toggleLoop' && flags?.loop) {
    return '取消循环播放';
  }
  if (action === 'toggleControls' && flags?.controls) {
    return '隐藏控件';
  }
  return ACTION_LABELS[action] ?? action;
}

function titleFor(event: BrowserRuntimeEvent): string {
  if (event.linkUrl) {
    return event.linkUrl;
  }
  if (event.mediaType === 'image') {
    return '图片';
  }
  if (event.mediaType === 'video') {
    return '视频';
  }
  if (event.mediaType === 'audio') {
    return '音频';
  }
  if (event.selectionText) {
    return event.selectionText.length > 40 ?
      `${event.selectionText.slice(0, 40)}…` : event.selectionText;
  }
  return event.isEditable ? '编辑' : '网页';
}

// Spelling suggestions carry the word rather than a fixed label, and
// imageToFile is something this shell runs itself rather than shows. An entry
// with no label would be a blank row.
function itemsFor(event: BrowserRuntimeEvent, actions: ContextMenuAction[]): ContextMenuItem[] {
  const items: ContextMenuItem[] = [];
  actions.forEach((action: ContextMenuAction): void => {
    const label: string = labelFor(event, action);
    if (label.length > 0) {
      items.push({ action: action, label: label });
    }
  });
  return items;
}

function wantsSystemPaste(event: BrowserRuntimeEvent, actions: ContextMenuAction[]): boolean {
  return event.systemPasteAllowed === true &&
    !actions.includes('paste') && hasSystemPlainText();
}

function pressX(event: BrowserRuntimeEvent): number {
  return typeof event.x === 'number' ? event.x : 0;
}

function pressY(event: BrowserRuntimeEvent): number {
  return typeof event.y === 'number' ? event.y : 0;
}

// Undefined means "nothing to show": the caller replies contextMenuDismissed
// without opening anything (an empty card would be worse than none).
export function buildContextMenuModel(event: BrowserRuntimeEvent): ContextMenuModel | undefined {
  const actions: ContextMenuAction[] = event.supportedActions ?? [];
  const items: ContextMenuItem[] = itemsFor(event, actions);
  const systemPaste: boolean = wantsSystemPaste(event, actions);
  if (items.length === 0 && !systemPaste) {
    return undefined;
  }
  return {
    requestId: event.requestId ?? 0,
    x: pressX(event),
    y: pressY(event),
    title: titleFor(event),
    subtitle: event.linkText ?? '',
    items: items,
    systemPaste: systemPaste,
    linkUrl: event.linkUrl ?? '',
    linkText: event.linkText ?? '',
    srcUrl: event.srcUrl ?? '',
    selectionText: event.selectionText ?? ''
  };
}

// contextMenuActionsChanged: same press, a refreshed action list. Keeps the
// parts only the original event had (title, position) and replaces the rest.
// Undefined means the refreshed list has nothing left to show.
export function updateContextMenuModel(previous: ContextMenuModel,
  event: BrowserRuntimeEvent): ContextMenuModel | undefined {
  const actions: ContextMenuAction[] = event.supportedActions ?? [];
  const items: ContextMenuItem[] = itemsFor(event, actions);
  const systemPaste: boolean = wantsSystemPaste(event, actions);
  if (items.length === 0 && !systemPaste) {
    return undefined;
  }
  return {
    requestId: previous.requestId,
    x: previous.x,
    y: previous.y,
    title: previous.title,
    subtitle: previous.subtitle,
    items: items,
    systemPaste: systemPaste,
    linkUrl: event.linkUrl ?? previous.linkUrl,
    linkText: event.linkText ?? previous.linkText,
    srcUrl: event.srcUrl ?? previous.srcUrl,
    selectionText: event.selectionText ?? previous.selectionText
  };
}

// The copy actions the shell runs itself. The engine's copies are fine except
// for one thing: Chromium shows its own "copied" toast pinned near the top of
// the window (libweb_engine.so carries toastCopiedLink / kLinkCopiedTo*), and
// in an immersive shell window that toast lands under the status bar and gets
// clipped in half. So for plain-text copies the shell writes the pasteboard
// and shows its own toast, and the engine only hears contextMenuDismissed --
// its native toast never happens. Returns the text to copy, or undefined when
// the action must still go to the engine (image data, save-as, navigation...).
export function shellCopyTextFor(model: ContextMenuModel,
  action: ContextMenuAction): string | undefined {
  switch (action) {
    case 'copyLinkAddress':
    case 'copyLinkToHighlight':
      // The highlight variant is a URL with a text fragment the engine builds;
      // the plain link URL is the useful part and is what we have.
      return model.linkUrl.length > 0 ? model.linkUrl : undefined;
    case 'copyLinkText':
      return model.linkText.length > 0 ? model.linkText : undefined;
    case 'copyImageAddress':
    case 'copyMediaAddress':
      return model.srcUrl.length > 0 ? model.srcUrl : undefined;
    case 'copy':
      return model.selectionText.length > 0 ? model.selectionText : undefined;
    default:
      return undefined;
  }
}

export function parseContextMenuModel(json: string): ContextMenuModel | undefined {
  if (!json || json.length === 0) {
    return undefined;
  }
  try {
    return JSON.parse(json) as ContextMenuModel;
  } catch (error) {
    return undefined;
  }
}

// The system action sheet, kept for tablets / 2in1 until they grow the phone's
// card. A shell with its own design draws its own; the protocol is the same
// (docs/SHELL_CONTRACT.md).
export function showContextMenuSheet(uiContext: UIContext, event: BrowserRuntimeEvent,
  send: (command: BrowserCommandPayload) => void): void {
  const requestId = event.requestId ?? 0;
  const actions: ContextMenuAction[] = event.supportedActions ?? [];
  const systemPaste = event.systemPasteAllowed === true &&
    !actions.includes('paste') && hasSystemPlainText();
  if (actions.length === 0 && !systemPaste) {
    send({ command: 'contextMenuDismissed', requestId: requestId });
    return;
  }
  const shown: ContextMenuAction[] = actions.filter(
    (action: ContextMenuAction): boolean => labelFor(event, action).length > 0);
  if (shown.length === 0 && !systemPaste) {
    send({ command: 'contextMenuDismissed', requestId: requestId });
    return;
  }
  const sheets: SheetInfo[] = shown.map((action: ContextMenuAction): SheetInfo => ({
    title: labelFor(event, action),
    action: (): void => {
      send({ command: 'contextMenuAction', requestId: requestId, action: action });
    }
  }));
  if (systemPaste) {
    sheets.push({
      title: '粘贴',
      action: (): void => {
        setTimeout((): void => {
          showSystemPasteDialog(uiContext,
            (text: string): void => {
              send({ command: 'insertText', requestId: requestId, text: text });
            },
            (): void => {
              send({ command: 'contextMenuDismissed', requestId: requestId });
            });
        }, 0);
      }
    });
  }
  uiContext.showActionSheet({
    title: titleFor(event),
    message: event.linkText ?? '',
    autoCancel: true,
    alignment: DialogAlignment.Bottom,
    sheets: sheets,
    cancel: (): void => {
      send({ command: 'contextMenuDismissed', requestId: requestId });
    }
  });
}

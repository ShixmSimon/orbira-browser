/*
 * 手机自绘书签页 v3.1（2026-10-10）：分层书签树 + 文件夹管理。
 *
 * 数据流：getBookmarks（parentId 省略 = 三个根文件夹；带 = 该文件夹子节点）
 * -> bookmarkList 事件（AuraShell 转存 'auraPanelBookmarkList'）——点文件夹
 * 进入（navStack 记路径）、返回钮逐级上退；搜索走 searchBookmarks（引擎
 * 按标题/网址匹配，命中带 path）。写入走版本 1-3 稳定命令：addBookmark /
 * createBookmarkFolder / updateBookmark（改名/编辑）/ removeBookmark（文件夹
 * 级联删）。引擎回 bookmarkCreated / bookmarksChanged / bookmarkOpResult
 * （转存 'auraPanelEvent'）后重拉当前层。
 * ⚠️ 不要用 getBookmarksForSync/applyBookmarks（版本 4）：当前引擎 HAR 的
 * bookmarkApiVersion 还没实现它们，命令会被吞、页面永远"加载中"（实测）。
 * 标题栏 + = 添加书签 / 新建文件夹（两选项）；⋯ 菜单 = 导入/导出/多选。
 */
import { common } from '@kit.AbilityKit';
import { display, promptAction, curves } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { BookmarkNode, BrowserCommandPayload } from 'engine';
import { HomePrefs } from '../../utils/appearance/HomePrefs';
import { displayUrl, pickAndStageImportFile, saveExportedFile, deleteStagedFile } from './PanelBridge';
import { AuraSectionLabel } from './AuraKit';
import { GlassPage, glassBottomInsetVp, glassHeaderInsetVp, glassTopSafeVp } from './GlassPage';
import { MoreMenuDialog, MoreMenuItemSpec } from './MoreMenuDialog';

interface BookmarkIoPayload {
  kind?: string;
  requestId?: number;
  ok?: boolean;
  bookmarkCount?: number;
  folderCount?: number;
  skippedCount?: number;
  error?: string;
}

interface BookmarkListPayload {
  requestId?: number;
  parentId?: string;
  nodes?: BookmarkNode[];
}

type FormMode = '' | 'addBookmark' | 'editBookmark' | 'addFolder' | 'renameFolder';

// 「移动到」选择器的一项文件夹（title 为含路径的显示名）。
interface FolderOption {
  id: string;
  title: string;
  childCount: number;
}

// 「移动到」选择器用的可复用行：整棵树可被 BFS 扁平化（可上千项），
// 用 @Reusable 让 List 滑动时回收复用，避免逐条重建组件（官方实测丢帧 3.7%→0%）。
@Component
@Reusable
struct FolderPickerRow {
  // ⚠️ 不能叫 id：与 CustomComponent 基类的通用属性 .id() setter 撞名，
  // ArkTS 报 10505001（'string' 不兼容 '(value: string) => CommonAttribute'）。
  @Prop folderId: string = '';
  @Prop title: string = '';
  @Prop childCount: number = 0;
  // 普通属性（非状态）：stable 回调，复用时不重新求值，由本行 @Prop id 决定目标。
  onPick: (id: string) => void = (_id: string): void => {};

  build(): void {
    Row({ space: 12 }) {
      Image($r('app.media.aura_folder'))
        .width(20)
        .height(20)
        .fillColor($r('app.color.icon_secondary'))
      Text(this.title)
        .fontSize(15)
        .fontColor($r('app.color.text_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(`${this.childCount} 项`)
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
    }
    .width('100%')
    .height(48)
    .padding({ left: 12, right: 12 })
    .borderRadius(10)
    .onClick(() => {
      this.onPick(this.folderId);
    })
  }
}

// LazyForEach 数据源（整棵树作为扁平数组）。
// 注意：IDataSource / DataChangeListener 是 ArkTS 全局类型（编译器内置声明），
// **不可**从 '@kit.ArkUI' import（该 kit 不导出它们，会报 10505001）。
class FolderOptionDataSource implements IDataSource {
  private listeners: DataChangeListener[] = [];
  private data: FolderOption[] = [];

  constructor(data: FolderOption[]) {
    this.data = data;
  }

  totalCount(): number {
    return this.data.length;
  }

  getData(index: number): FolderOption {
    return this.data[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) === -1) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index !== -1) {
      this.listeners.splice(index, 1);
    }
  }

  notifyDataReload(): void {
    this.listeners.forEach((listener: DataChangeListener): void => {
      listener.onDataReloaded();
    });
  }
}

const MAX_LOAD_RETRIES: number = 3;
const LOAD_RETRY_MS: number = 700;
const LOAD_SHOW_MS: number = 350;

@Component
export struct BookmarksPanel {
  // A' 面板页化（Phase 2）：改为独立路由页后不再从 overlay 以构造参数传入，
  // 改由 AppStorage 读取（overlay 的 onBrowserStateChanged 已同步这两个键）。
  @StorageLink('auraCurrentUrl') currentUrl: string = '';
  @StorageLink('auraCurrentTitle') currentTitle: string = '';
  // 当前层节点（getBookmarks 回包；根级 = 三个根文件夹）。
  @StorageLink('auraPanelBookmarkList') @Watch('onListChanged') listJson: string = '';
  // 最近添加（根级下方平铺；getRecentBookmarks 通道）。
  @StorageLink('auraPanelBookmarks') @Watch('onRecentChanged') bookmarksJson: string = '';
  @StorageLink('auraPanelBookmarkIo') @Watch('onIoPayload') bookmarkIoJson: string = '';
  @StorageLink('auraPanelEvent') @Watch('onPanelEvent') panelEventJson: string = '';
  // 主页书签（「首页」文件夹）id：主页发现后写进 AppStorage；根级置顶行用它
  // 直接跳进该文件夹（HomeSurface 的磁贴数据源）。
  @StorageLink('auraHomeFolderId') homeFolderId: string = '';
  onCommand: (command: BrowserCommandPayload) => void = (_command: BrowserCommandPayload): void => {};
  onBack: () => void = (): void => {};
  onClose: () => void = (): void => {};

  @State private currentNodes: BookmarkNode[] = [];
  @State private recentNodes: BookmarkNode[] = [];
  // 当前所在文件夹 id（'' = 根级）。
  @State private currentFolderId: string = '';
  // 移动设备根（根级回包里 rootType==='mobile'；根级新建的默认落点）。
  @State private mobileFolderId: string = '';
  // ⚠️ 初值必须是 false（2026-10-10 用户反馈「进页面直接显示加载中」）：
  // 引擎正常回包只要几十毫秒，loading=true 初值会让首帧就渲染出「加载中…」，
  // 看起来像卡了一下。真实逻辑见 loadLayer（延迟 LOAD_SHOW_MS 才显形）。
  @State private loading: boolean = false;
  private navStack: string[] = [];
  // 回包匹配：只采用最新一次请求的回包（layer = 目录层，search = 搜索）。
  private pendingKind: 'layer' | 'search' | 'collect' = 'layer';
  private pendingSeq: number = 0;
  private requestSeq: number = 0;
  private retryTimer: number = -1;
  private loadTimer: number = -1;
  private retryCount: number = 0;
  private pendingImportPath: string = '';
  private pendingExportPath: string = '';
  private pendingExportRequestId: number = 0;

  // 表单弹窗（添加/编辑书签、新建/重命名文件夹共用）。
  @State private dialogMode: FormMode = '';
  @State private formTitle: string = '';
  @State private formUrl: string = '';
  private editUuid: string = '';

  // 搜索（searchBookmarks 命令，命中带 path）。
  @State private searchText: string = '';
  @State private searchResults: BookmarkNode[] = [];

  // 行菜单（自绘卡，首页同款）：目标节点 + 落点。
  @State private rowMenuId: string = '';
  @State private rowMenuIsFolder: boolean = false;
  @State private rowMenuX: number = 0;
  @State private rowMenuY: number = 0;
  private menuPressX: number = 0;
  private menuPressY: number = 0;
  private windowW: number = 360;
  private windowH: number = 780;

  // 「移动到」：打开选择器时 BFS 拉全树，收集全部文件夹。
  @State private pickerVisible: boolean = false;
  @State private pickerFolders: FolderOption[] = [];
  // LazyForEach 数据源：打开选择器时按当前整树重建（pickerVisible 切 true 时子树全新挂载，读最新实例）。
  private pickerDataSource: FolderOptionDataSource = new FolderOptionDataSource([]);
  // 表单里选中的移动目标（'' = 不移动）。
  @State private moveTargetId: string = '';
  // 正在编辑/新建的节点的父文件夹（显示「所在文件夹」用）。
  @State private formParentId: string = '';
  private folderIds: string[] = [];
  private folderParent: Map<string, string> = new Map();
  private folderTitle: Map<string, string> = new Map();
  private folderKids: Map<string, number> = new Map();
  // 父→子 列表（移动文件夹时递归排除子孙用）。
  private folderChildren: Map<string, string[]> = new Map();
  // 从行菜单直接触发移动（不进编辑表单）：源节点 id、是否文件夹、要排除的子树根。
  @State private moveNodeId: string = '';
  @State private moveNodeIsFolder: boolean = false;
  @State private moveExcludeRoot: string = '';
  private collectSeen: Set<string> = new Set();
  private collectOutstanding: number = 0;
  private collectStartSeq: number = 0;

  // 批量管理：选择模式 + 已选 id 集合 + 批量移动标记。
  @State private selectMode: boolean = false;
  @State private selectedIds: string[] = [];
  @State private batchMoveMode: boolean = false;

  // ⋯ 菜单项（原地 mutate，让「多选」按需出现）。
  private moreItems: MoreMenuItemSpec[] = [];
  // + 按钮菜单项：添加书签 / 新建文件夹（原「手动添加书签」从 ⋯ 移到了这里）。
  private plusItems: MoreMenuItemSpec[] = [];

  private listScroller: Scroller = new Scroller();

  aboutToAppear(): void {
    const dsp = display.getDefaultDisplaySync();
    this.windowW = dsp.width / dsp.densityPixels;
    this.windowH = dsp.height / dsp.densityPixels;
    // 用持久化的书签列表直接填充首屏（@StorageLink 跨挂载保留），避免「进页面
    // 就闪加载中」——已有缓存数据时静默重拉，只有真正首次无数据才走 loading。
    this.hydrateFromCache();
    this.onRecentChanged();
    // 「首页」文件夹 id：主页发现后会写进 AppStorage；书签页可能先于主页打开
    // （进程重启后），从 prefs 捞一次兜底，捞到就补上根级置顶行。
    if (this.homeFolderId.length === 0) {
      const host = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
      HomePrefs.loadFolderId(host).then((id: string): void => {
        if (id.length > 0 && this.homeFolderId.length === 0) {
          this.homeFolderId = id;
        }
      });
    }
    this.loadLayer('');
  }

  aboutToDisappear(): void {
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    this.cleanupPendingImport();
  }

  /** 首屏 hydration：从持久化的 auraPanelBookmarkList 直接回填根层。
   *  @StorageLink 跨挂载保留，所以重进页面时通常已有缓存——直接填进 currentNodes
   *  让 hadData=true，loadLayer 就不会闪「加载中」。仅回填根层（parentId 为空）；
   *  搜索回包也走这个存储且无 parentId，但书签同源，短暂闪一下随即被 loadLayer
   *  刷新，比「加载中」体验好。 */
  private hydrateFromCache(): void {
    if (this.listJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.listJson) as BookmarkListPayload;
      if ((payload.parentId ?? '').length > 0) {
        return;
      }
      const nodes = payload.nodes ?? [];
      if (nodes.length > 0) {
        this.currentNodes = nodes;
        for (const node of nodes) {
          if (node.rootType === 'mobile') {
            this.mobileFolderId = node.id;
            break;
          }
        }
      }
    } catch (error) {
    }
  }

  // -- 数据层 -----------------------------------------------------------------

  /** 拉取某层：parentId 空 = 三个根文件夹，否则该文件夹的直接子节点。 */
  private loadLayer(parentId: string): void {
    this.clearLoadTimers();
    this.retryCount = 0;
    this.pendingKind = 'layer';
    this.requestSeq += 1;
    this.pendingSeq = this.requestSeq;
    // 「加载中」默认不显示（loading 初值 false）：已有数据时完全静默重拉；
    // 无数据时才等 LOAD_SHOW_MS 再显形——引擎正常回包（< 350ms）一个字的
    // 加载提示都不会闪，只有偶发吞命令（引擎真没回）才显形并触发重试。
    this.loading = false;
    const hadData = this.currentNodes.length > 0 ||
      (this.currentFolderId.length === 0 && this.recentNodes.length > 0);
    if (!hadData) {
      const seq = this.pendingSeq;
      this.loadTimer = setTimeout((): void => {
        this.loadTimer = -1;
        if (this.pendingSeq === seq) {
          this.loading = true;
          this.scheduleRetry();
        }
      }, LOAD_SHOW_MS);
    }
    if (parentId.length === 0) {
      this.onCommand({ command: 'getBookmarks', requestId: this.requestSeq });
    } else {
      this.onCommand({ command: 'getBookmarks', requestId: this.requestSeq, parentId: parentId });
    }
  }

  // 统一清理加载相关的两个定时器（延迟显示 + 重试）。
  private clearLoadTimers(): void {
    if (this.loadTimer !== -1) {
      clearTimeout(this.loadTimer);
      this.loadTimer = -1;
    }
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  private scheduleRetry(): void {
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    if (this.retryCount >= MAX_LOAD_RETRIES) {
      return;
    }
    this.retryCount += 1;
    const seq = this.pendingSeq;
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      if (this.loading && this.pendingSeq === seq) {
        // 引擎没回：重发同一层。
        if (this.pendingKind === 'layer') {
          const parentId = this.currentFolderId;
          this.requestSeq += 1;
          this.pendingSeq = this.requestSeq;
          if (parentId.length === 0) {
            this.onCommand({ command: 'getBookmarks', requestId: this.requestSeq });
          } else {
            this.onCommand({ command: 'getBookmarks', requestId: this.requestSeq, parentId: parentId });
          }
          this.scheduleRetry();
        }
      }
    }, LOAD_RETRY_MS);
  }

  private onListChanged(): void {
    if (this.listJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.listJson) as BookmarkListPayload;
      if (this.pendingKind === 'collect') {
        // 文件夹收集：接受收集开始之后的任何回包（多层并发在途）。
        if ((payload.requestId ?? -1) >= this.collectStartSeq) {
          this.onCollectPacket(payload.nodes ?? []);
        }
        return;
      }
      if ((payload.requestId ?? -1) !== this.pendingSeq) {
        return;
      }
      const nodes = payload.nodes ?? [];
      if (this.pendingKind === 'layer') {
        this.currentNodes = nodes;
        if (this.currentFolderId.length === 0) {
          for (const node of nodes) {
            if (node.rootType === 'mobile') {
              this.mobileFolderId = node.id;
              break;
            }
          }
        }
      } else {
        this.searchResults = nodes;
      }
      this.loading = false;
      this.clearLoadTimers();
    } catch (error) {
      this.loading = false;
    }
  }

  private onRecentChanged(): void {
    if (this.bookmarksJson.length === 0) {
      return;
    }
    try {
      this.recentNodes = JSON.parse(this.bookmarksJson) as BookmarkNode[];
    } catch (error) {
    }
  }

  private onPanelEvent(): void {
    // bookmarkCreated / bookmarkOpResult / bookmarksChanged: 重拉当前层。
    if (this.searchText.trim().length > 0) {
      this.runSearch(this.searchText);
      return;
    }
    this.loadLayer(this.currentFolderId);
  }

  /** 搜索走引擎（searchBookmarks，按标题/网址匹配，命中带 path）。 */
  private runSearch(query: string): void {
    const q = query.trim();
    if (q.length === 0) {
      this.searchResults = [];
      return;
    }
    this.pendingKind = 'search';
    this.requestSeq += 1;
    this.pendingSeq = this.requestSeq;
    this.onCommand({ command: 'searchBookmarks', requestId: this.requestSeq, query: q, maxCount: 50 });
  }

  /** 返回钮：选择态先退出多选 → 子文件夹逐级上退 → 到根再关面板。 */
  private handleBack(): void {
    if (this.selectMode) {
      this.exitSelect();
      return;
    }
    if (this.navStack.length > 0) {
      const parent = this.navStack.pop();
      this.currentFolderId = parent !== undefined ? parent : '';
      this.loadLayer(this.currentFolderId);
      return;
    }
    this.onBack();
  }

  // -- 「移动到」：BFS 收集全部文件夹 -------------------------------------------

  private openFolderPicker(): void {
    this.folderIds = [];
    this.folderParent.clear();
    this.folderTitle.clear();
    this.folderKids.clear();
    this.folderChildren.clear();
    this.collectSeen.clear();
    this.collectSeen.add('');
    this.collectOutstanding = 1;
    this.collectStartSeq = this.requestSeq + 1;
    this.pendingKind = 'collect';
    this.requestSeq += 1;
    this.onCommand({ command: 'getBookmarks', requestId: this.requestSeq });
  }

  private onCollectPacket(nodes: BookmarkNode[]): void {
    this.collectOutstanding -= 1;
    for (const node of nodes) {
      if (node.type !== 'folder') {
        continue;
      }
      if (!this.folderParent.has(node.id)) {
        this.folderIds.push(node.id);
      }
      this.folderParent.set(node.id, node.parentId);
      this.folderTitle.set(node.id, node.title.length > 0 ? node.title : '未命名文件夹');
      this.folderKids.set(node.id, node.childCount ?? 0);
      // 建 父→子 列表（移动文件夹时递归排除子孙用）。
      const par = node.parentId;
      if (!this.folderChildren.has(par)) {
        this.folderChildren.set(par, []);
      }
      this.folderChildren.get(par)!.push(node.id);
      if (!this.collectSeen.has(node.id)) {
        this.collectSeen.add(node.id);
        this.collectOutstanding += 1;
        this.requestSeq += 1;
        this.onCommand({ command: 'getBookmarks', requestId: this.requestSeq, parentId: node.id });
      }
    }
    if (this.collectOutstanding <= 0) {
      this.buildPickerOptions();
    }
  }

  /** 文件夹显示名：沿父链拼路径（移动设备书签 / 工作 / 账号）。 */
  private folderDisplayPath(id: string): string {
    const parts: string[] = [];
    let cursor = id;
    let guard = 0;
    while (cursor.length > 0 && this.folderTitle.has(cursor) && guard < 8) {
      const title = this.folderTitle.get(cursor);
      parts.unshift(title !== undefined ? title : '');
      const parent = this.folderParent.get(cursor);
      cursor = parent !== undefined ? parent : '';
      guard += 1;
    }
    return parts.join(' / ');
  }

  /** 收集 root 及其全部后代（移动文件夹时排除自身与子孙）。 */
  private collectDescendants(root: string, out: Set<string>): void {
    out.add(root);
    const kids = this.folderChildren.get(root) ?? [];
    for (const k of kids) {
      this.collectDescendants(k, out);
    }
  }

  private buildPickerOptions(): void {
    const excluded = new Set<string>();
    if (this.moveExcludeRoot.length > 0) {
      // 文件夹不能移进自己或自己的子孙。
      this.collectDescendants(this.moveExcludeRoot, excluded);
    }
    const out: FolderOption[] = [];
    for (const id of this.folderIds) {
      if (excluded.has(id)) {
        continue;
      }
      const kids = this.folderKids.get(id);
      out.push({
        id: id,
        title: this.folderDisplayPath(id),
        childCount: kids !== undefined ? kids : 0
      } as FolderOption);
    }
    this.pickerFolders = out;
    // 整棵树作为扁平数组喂给 LazyForEach（pickerVisible 切 true 时子树全新挂载，读最新实例）。
    this.pickerDataSource = new FolderOptionDataSource(out);
    this.pickerVisible = true;
  }

  private pickMoveTarget(id: string): void {
    const ids = this.batchMoveMode
      ? this.selectedIds.slice()
      : (this.moveNodeId.length > 0 ? [this.moveNodeId] : []);
    this.pickerVisible = false;
    this.moveNodeId = '';
    this.moveNodeIsFolder = false;
    this.moveExcludeRoot = '';
    this.batchMoveMode = false;
    if (ids.length === 0) {
      return;
    }
    this.requestSeq += 1;
    this.onCommand({
      command: 'moveBookmarks',
      ids: ids,
      parentId: id,
      index: this.folderKids.get(id) ?? 0,
      requestId: this.requestSeq
    });
    this.getUIContext().getPromptAction().showToast({
      message: `已移动 ${ids.length} 项`,
      duration: 1500
    });
    this.selectedIds = [];
    this.selectMode = false;
    // 移动后当前层内容变化（书签离开 / 文件夹换父），主动重拉。
    this.loadLayer(this.currentFolderId);
  }

  /** 从行菜单进入「移动到」（不进编辑表单）。 */
  private openMove(node: BookmarkNode): void {
    this.moveNodeId = node.id;
    this.moveNodeIsFolder = node.type === 'folder';
    // 文件夹移动：排除自身及子孙；书签移动：不排除（可移进任意文件夹）。
    this.moveExcludeRoot = node.type === 'folder' ? node.id : '';
    this.rowMenuId = '';
    this.openFolderPicker();
  }

  /** 行菜单/列表里按 id 找节点（覆盖当前层 / 最近添加 / 搜索结果）。 */
  private findNodeById(id: string): BookmarkNode | undefined {
    return this.currentNodes.find((c: BookmarkNode): boolean => c.id === id) ??
      this.recentNodes.find((c: BookmarkNode): boolean => c.id === id) ??
      this.searchResults.find((c: BookmarkNode): boolean => c.id === id);
  }

  private openNode(node: BookmarkNode): void {
    if (node.type === 'folder') {
      this.navStack.push(this.currentFolderId);
      this.currentFolderId = node.id;
      this.loadLayer(node.id);
      return;
    }
    if (node.url === undefined || node.url.length === 0) {
      return;
    }
    this.onCommand({ command: 'navigate', url: node.url });
    this.onClose();
  }

  /** 新建书签/文件夹的父层：根级落到移动设备根，子层落到当前文件夹。 */
  private targetParentId(): string {
    if (this.currentFolderId.length > 0) {
      return this.currentFolderId;
    }
    return this.mobileFolderId;
  }

  // -- 行菜单 -----------------------------------------------------------------

  private openRowMenu(node: BookmarkNode): void {
    const cardW = 190;
    const cardH = node.type === 'folder' ? 156 : 252;
    this.rowMenuX = Math.min(Math.max(this.menuPressX - cardW / 2, 12),
      Math.max(12, this.windowW - cardW - 12));
    this.rowMenuY = Math.min(this.menuPressY + 8, Math.max(12, this.windowH - cardH - 96));
    this.rowMenuIsFolder = node.type === 'folder';
    this.rowMenuId = node.id;
  }

  private copyLink(url: string): void {
    const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, url);
    pasteboard.getSystemPasteboard().setData(data).catch((): void => {
    });
    this.getUIContext().getPromptAction().showToast({ message: '链接已复制', duration: 1500 });
  }

  private removeWithConfirm(node: BookmarkNode): void {
    this.getUIContext().getPromptAction().showDialog({
      title: node.type === 'folder' ? '删除文件夹' : '删除书签',
      message: node.title.length > 0 ? node.title : (node.url ?? ''),
      buttons: [
        { text: '取消', color: '#5F6368' },
        { text: '删除', color: '#E24B4A' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (result.index !== 1) {
        return;
      }
      this.requestSeq += 1;
      this.onCommand({ command: 'removeBookmarks', ids: [node.id], requestId: this.requestSeq });
      if (node.type === 'folder' && this.currentFolderId === node.id) {
        // 删除的是正浏览的文件夹：立即退回上一层。
        const parent = this.navStack.length > 0 ? this.navStack.pop() : undefined;
        this.currentFolderId = parent !== undefined ? parent : '';
        this.loadLayer(this.currentFolderId);
      }
    }).catch((error: Error): void => {
    });
  }

  // -- 批量管理（选择模式 + 批量删除 / 批量移动） -------------------------------

  private isSelected(id: string): boolean {
    return this.selectedIds.indexOf(id) >= 0;
  }

  private toggleSelect(id: string): void {
    const idx = this.selectedIds.indexOf(id);
    if (idx >= 0) {
      this.selectedIds.splice(idx, 1);
    } else {
      this.selectedIds.push(id);
    }
    // 重新赋值触发 @State 更新（ArkUI 对数组原地修改不重渲染）。
    this.selectedIds = this.selectedIds.slice();
  }

  // 当前视图可见的节点 id（根级含「最近添加」平铺区）。
  private visibleNodeIds(): string[] {
    const ids: string[] = [];
    for (const node of this.currentNodes) {
      ids.push(node.id);
    }
    if (this.currentFolderId.length === 0) {
      for (const node of this.recentNodes) {
        ids.push(node.id);
      }
    }
    return ids;
  }

  private selectAllVisible(): void {
    this.selectedIds = this.visibleNodeIds();
  }

  private enterSelect(): void {
    this.selectedIds = [];
    this.selectMode = true;
  }

  private exitSelect(): void {
    this.selectedIds = [];
    this.selectMode = false;
  }

  // 批量删除：统一走复数命令 removeBookmarks（引擎契约带 ids[]，
  // BookmarkOpResultEvent.failedIds 标识跳过的项）。单条删除也改用复数，
  // 修正此前单数 removeBookmark 可能不被引擎识别的问题。
  private batchRemove(): void {
    if (this.selectedIds.length === 0) {
      return;
    }
    const count = this.selectedIds.length;
    const ids = this.selectedIds.slice();
    this.getUIContext().getPromptAction().showDialog({
      title: '删除所选',
      message: `确定删除选中的 ${count} 项吗？文件夹会连同里面的内容一起删除。`,
      buttons: [
        { text: '取消', color: '#5F6368' },
        { text: '删除', color: '#E24B4A' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse): void => {
      if (result.index !== 1) {
        return;
      }
      this.requestSeq += 1;
      this.onCommand({ command: 'removeBookmarks', ids: ids, requestId: this.requestSeq });
      if (ids.indexOf(this.currentFolderId) >= 0) {
        // 删掉的正好是当前文件夹：退回上一层。
        const parent = this.navStack.length > 0 ? this.navStack.pop() : undefined;
        this.currentFolderId = parent !== undefined ? parent : '';
      }
      this.selectedIds = [];
      this.selectMode = false;
      this.loadLayer(this.currentFolderId);
    }).catch((error: Error): void => {
    });
  }

  // 批量移动：打开文件夹选择器（batchMoveMode），选完发复数 moveBookmarks。
  private batchMove(): void {
    if (this.selectedIds.length === 0) {
      return;
    }
    this.batchMoveMode = true;
    this.openFolderPicker();
  }

  // -- 表单弹窗（添加/编辑书签、新建/重命名文件夹） -----------------------------

  private openForm(mode: FormMode, node?: BookmarkNode): void {
    this.editUuid = node !== undefined ? node.id : '';
    this.moveTargetId = '';
    this.formParentId = mode === 'addBookmark' || mode === 'addFolder'
      ? this.targetParentId()
      : (node !== undefined ? node.parentId : '');
    this.formTitle = node !== undefined ? node.title : '';
    this.formUrl = node !== undefined && node.url !== undefined ? node.url : '';
    if (mode === 'addBookmark') {
      // 手动添加：预填当前页（承接原「收藏当前网页」，+ 撤掉后这里是唯一入口）。
      if (this.formTitle.length === 0 && this.formUrl.length === 0) {
        this.formUrl = this.currentUrl;
        this.formTitle = this.currentTitle;
      }
    }
    this.dialogMode = mode;
  }

  private cancelForm(): void {
    this.dialogMode = '';
    this.editUuid = '';
    this.formTitle = '';
    this.formUrl = '';
  }

  private confirmForm(): void {
    const title = this.formTitle.trim();
    if (this.dialogMode === 'addBookmark') {
      const url = this.formUrl.trim();
      if (url.length === 0) {
        return;
      }
      this.requestSeq += 1;
      const parent = this.targetParentId();
      if (parent.length === 0) {
        this.onCommand({ command: 'addBookmark', url: url, title: title, requestId: this.requestSeq });
      } else {
        this.onCommand({
          command: 'addBookmark',
          url: url,
          title: title,
          parentId: parent,
          requestId: this.requestSeq
        });
      }
    } else if (this.dialogMode === 'addFolder') {
      const name = title.length > 0 ? title : '新建文件夹';
      this.requestSeq += 1;
      this.onCommand({
        command: 'createBookmarkFolder',
        requestId: this.requestSeq,
        parentId: this.targetParentId(),
        title: name
      });
    } else if (this.dialogMode === 'editBookmark' || this.dialogMode === 'renameFolder') {
      if (this.editUuid.length === 0) {
        this.cancelForm();
        return;
      }
      this.requestSeq += 1;
      this.onCommand({
        command: 'updateBookmark',
        id: this.editUuid,
        title: title.length > 0 ? title : undefined,
        url: this.dialogMode === 'editBookmark' ? this.formUrl.trim() : undefined,
        requestId: this.requestSeq
      });
      if (this.moveTargetId.length > 0 && this.moveTargetId !== this.formParentId) {
        // 「移动到」：放到目标文件夹末尾（引擎收到后推 bookmarksChanged，本页重拉）。
        const kids = this.folderKids.get(this.moveTargetId);
        this.requestSeq += 1;
        this.onCommand({
          command: 'moveBookmarks',
          ids: [this.editUuid],
          parentId: this.moveTargetId,
          index: kids !== undefined ? kids : 0,
          requestId: this.requestSeq
        });
      }
    }
    this.cancelForm();
    this.moveTargetId = '';
  }

  private formHeadline(): string {
    if (this.dialogMode === 'addBookmark') {
      return '添加书签';
    }
    if (this.dialogMode === 'editBookmark') {
      return '编辑书签';
    }
    if (this.dialogMode === 'addFolder') {
      return '新建文件夹';
    }
    return '重命名文件夹';
  }

  // -- 导入 / 导出 ----------------------------------

  private cleanupPendingImport(): void {
    if (this.pendingImportPath.length > 0) {
      deleteStagedFile(this.pendingImportPath);
      this.pendingImportPath = '';
    }
  }

  private onIoPayload(): void {
    if (this.bookmarkIoJson.length === 0) {
      return;
    }
    try {
      const payload = JSON.parse(this.bookmarkIoJson) as BookmarkIoPayload;
      const kind = String(payload.kind ?? '');
      if (kind === 'import') {
        this.cleanupPendingImport();
        if (payload.ok === true) {
          const count = Number(payload.bookmarkCount ?? 0);
          const skipped = Number(payload.skippedCount ?? 0);
          let message = `已导入 ${count} 个书签`;
          if (skipped > 0) {
            message = `${message}（跳过 ${skipped} 条）`;
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
          this.loadLayer(this.currentFolderId);
        } else {
          AlertDialog.show({
            title: '导入没有成功',
            message: this.importFailureText(String(payload.error ?? '')),
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
          this.handExportToSaveDialog(stagedPath, Number(payload.bookmarkCount ?? 0));
        } else {
          deleteStagedFile(stagedPath);
          AlertDialog.show({
            title: '导出没有成功',
            message: '没能写出书签文件，请再试一次。',
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
    }
  }

  private importFailureText(error: string): string {
    if (error === 'tooLarge') {
      return '文件太大（超过 20 MB），没有导入。';
    }
    if (error === 'notBookmarkFile') {
      return '这个文件里没有找到书签数据，没有导入。';
    }
    if (error === 'fileNotFound') {
      return '读不了这个文件，请再试一次。';
    }
    return '没能导入书签，请再试一次。';
  }

  private async handExportToSaveDialog(stagedPath: string, count: number): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      deleteStagedFile(stagedPath);
      return;
    }
    const saved = await saveExportedFile(context, stagedPath, 'Aura 书签.html');
    if (saved) {
      AlertDialog.show({
        title: '导出完成',
        message: `已导出 ${count} 个书签`,
        confirm: {
          value: '好的',
          action: (): void => {
          }
        }
      });
    }
  }

  private async startImport(): Promise<void> {
    this.cleanupPendingImport();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    const path = await pickAndStageImportFile(context, ['书签文件|.html']);
    if (path.length === 0) {
      return;
    }
    this.pendingImportPath = path;
    this.requestSeq += 1;
    this.onCommand({
      command: 'importBookmarks',
      requestId: this.requestSeq,
      path: path,
      title: '导入的书签'
    });
  }

  private startExport(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
    if (!context) {
      return;
    }
    this.requestSeq += 1;
    this.pendingExportRequestId = this.requestSeq;
    this.pendingExportPath = `${context.filesDir}/aura-export-bookmarks.html`;
    this.onCommand({
      command: 'exportBookmarks',
      requestId: this.pendingExportRequestId,
      path: this.pendingExportPath
    });
  }

  // -- ⋯ 子菜单（CustomDialog）------------------------------------------------

  private showMoreSheet(): void {
    this.moreItems.length = 0;
    this.moreItems.push(
      {
        icon: $r('app.media.aura_import'),
        label: '导入书签',
        action: (): void => {
          this.startImport();
        }
      },
      {
        icon: $r('app.media.aura_export'),
        label: '导出书签',
        action: (): void => {
          this.startExport();
        }
      },
      {
        icon: $r('app.media.aura_check'),
        label: '多选',
        action: (): void => {
          this.enterSelect();
        }
      }
    );
    this.moreMenuDialog.open();
  }

  // + 按钮：两种操作（添加书签 / 新建文件夹）。原「手动添加书签」从 ⋯ 菜单
  // 移到这里，让 + 既管书签也管文件夹（用户要求）。
  private showPlusSheet(): void {
    this.plusItems.length = 0;
    this.plusItems.push(
      {
        icon: $r('app.media.aura_bookmark'),
        label: '添加书签',
        action: (): void => {
          this.openForm('addBookmark');
        }
      },
      {
        icon: $r('app.media.aura_folder'),
        label: '新建文件夹',
        action: (): void => {
          this.openForm('addFolder');
        }
      }
    );
    this.plusMenuDialog.open();
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

  // + 按钮的两选项菜单（添加书签 / 新建文件夹），与 ⋯ 菜单共用 MoreMenuDialog 样式。
  private plusMenuDialog: CustomDialogController = new CustomDialogController({
    builder: MoreMenuDialog({
      items: this.plusItems
    }),
    autoCancel: true,
    customStyle: true,
    maskColor: Color.Transparent,
    alignment: DialogAlignment.TopEnd,
    offset: { dx: -12, dy: glassTopSafeVp() + 62 }
  });

  // -- UI ---------------------------------------------------------------------

  @Builder
  private SelectBox(id: string) {
    Column() {
      if (this.isSelected(id)) {
        Image($r('app.media.aura_check'))
          .width(16)
          .height(16)
          .fillColor($r('app.color.on_accent'))
      }
    }
    .width(26)
    .height(26)
    .borderRadius(13)
    .border({ width: 2, color: this.isSelected(id) ? $r('app.color.accent_primary') : $r('app.color.divider') })
    .backgroundColor(this.isSelected(id) ? $r('app.color.accent_primary') : Color.Transparent)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  private FolderRow(node: BookmarkNode) {
    Column() {
      Row({ space: 12 }) {
        if (this.selectMode) {
          this.SelectBox(node.id)
        } else {
          Column() {
            Image($r('app.media.aura_folder'))
              .width(20)
              .height(20)
              .fillColor($r('app.color.text_primary'))
          }
          .width(38)
          .height(38)
          .borderRadius(10)
          .backgroundColor($r('app.color.surface_secondary'))
          .justifyContent(FlexAlign.Center)
        }

        Column({ space: 2 }) {
          Text(node.title.length > 0 ? node.title : '未命名文件夹')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text(`${node.childCount ?? 0} 项`)
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (!this.selectMode) {
          Button({ type: ButtonType.Circle }) {
            Image($r('app.media.aura_more'))
              .width(18)
              .height(18)
              .fillColor($r('app.color.icon_secondary'))
          }
          .width(40)
          .height(40)
          .backgroundColor(Color.Transparent)
          .accessibilityText('文件夹操作')
          .onClick(() => {
            this.openRowMenu(node);
          })

          Image($r('app.media.aura_chevron'))
            .width(16)
            .height(16)
            .fillColor($r('app.color.icon_secondary'))
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 60 })
      .padding({ left: 16, right: 12, top: 8, bottom: 8 })
      .onClick(() => {
        if (this.selectMode) {
          this.toggleSelect(node.id);
        } else {
          this.openNode(node);
        }
      })
    }
    .width('100%')
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down && event.touches.length > 0) {
        this.menuPressX = event.touches[0].windowX;
        this.menuPressY = event.touches[0].windowY;
      }
    })
  }

  // 根级置顶「首页」入口：直接跳进主页书签文件夹（HomeSurface 磁贴数据源）。
  // 不进选择模式（跳转入口不参与批量勾选），样式与 FolderRow 完全同族。
  @Builder
  private HomeFolderRow() {
    Column() {
      Row({ space: 12 }) {
        Column() {
          Image($r('app.media.aura_home'))
            .width(20)
            .height(20)
            .fillColor($r('app.color.text_primary'))
        }
        .width(38)
        .height(38)
        .borderRadius(10)
        .backgroundColor($r('app.color.surface_secondary'))
        .justifyContent(FlexAlign.Center)

        Column({ space: 2 }) {
          Text('首页')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text('这里的书签会显示在主页')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Image($r('app.media.aura_chevron'))
          .width(16)
          .height(16)
          .fillColor($r('app.color.icon_secondary'))
      }
      .width('100%')
      .constraintSize({ minHeight: 60 })
      .padding({ left: 16, right: 12, top: 8, bottom: 8 })
      .onClick(() => {
        this.navStack.push(this.currentFolderId);
        this.currentFolderId = this.homeFolderId;
        this.loadLayer(this.homeFolderId);
      })
    }
    .width('100%')
  }

  @Builder
  private BookmarkRow(node: BookmarkNode, index: number, total: number) {
    Column() {
      Row({ space: 12 }) {
        if (this.selectMode) {
          this.SelectBox(node.id)
        } else {
          Image($r('app.media.aura_bookmark'))
            .width(22)
            .height(22)
            .fillColor($r('app.color.icon_primary'))
        }

        Column({ space: 2 }) {
          Text(node.title.length > 0 ? node.title : displayUrl(node.url ?? ''))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
          Text(displayUrl(node.url ?? ''))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (!this.selectMode) {
          Button({ type: ButtonType.Circle }) {
            Image($r('app.media.aura_more'))
              .width(18)
              .height(18)
              .fillColor($r('app.color.icon_secondary'))
          }
          .width(40)
          .height(40)
          .backgroundColor(Color.Transparent)
          .accessibilityText('书签操作')
          .onClick(() => {
            this.openRowMenu(node);
          })
        }
      }
      .width('100%')
      .constraintSize({ minHeight: 60 })
      .padding({ left: 16, right: 6, top: 8, bottom: 8 })
      .onClick(() => {
        if (this.selectMode) {
          this.toggleSelect(node.id);
        } else {
          this.openNode(node);
        }
      })

      if (index < total - 1) {
        Divider()
          .color($r('app.color.divider'))
          .margin({ left: 50 })
      }
    }
    .width('100%')
    .onTouch((event: TouchEvent): void => {
      if (event.type === TouchType.Down && event.touches.length > 0) {
        this.menuPressX = event.touches[0].windowX;
        this.menuPressY = event.touches[0].windowY;
      }
    })
  }

  @Builder
  private RowMenuRow(icon: Resource, label: string, action: () => void, iconAngle: number) {
    Row({ space: 14 }) {
      Image(icon)
        .width(21)
        .height(21)
        .fillColor($r('app.color.icon_primary'))
        .rotate({ angle: iconAngle })
      Text(label)
        .fontSize(15)
        .fontColor(label === '删除' ? $r('app.color.danger') : $r('app.color.text_primary'))
      Blank()
    }
    .width('100%')
    .height(48)
    .padding({ left: 18, right: 16 })
    .onClick(action)
  }

  // 行菜单：自绘悬浮卡挂 body Stack（viewport 固定；首页同款机制）。
  @Builder
  private RowMenuOverlay() {
    if (this.rowMenuId.length > 0) {
      Stack({ alignContent: Alignment.TopStart }) {
        Column()
          .width('100%')
          .height('100%')
          .onClick(() => {
            this.rowMenuId = '';
          })

        Column() {
          if (this.rowMenuIsFolder) {
            this.RowMenuRow($r('app.media.aura_edit'), '重命名', (): void => {
              const node = this.findNodeById(this.rowMenuId);
              this.rowMenuId = '';
              if (node !== undefined) {
                this.openForm('renameFolder', node);
              }
            }, 0)
            this.RowMenuRow($r('app.media.aura_folder'), '移动到', (): void => {
              const node = this.findNodeById(this.rowMenuId);
              if (node !== undefined) {
                this.openMove(node);
              }
            }, 0)
            this.RowMenuRow($r('app.media.aura_trash'), '删除', (): void => {
              const node = this.findNodeById(this.rowMenuId);
              this.rowMenuId = '';
              if (node !== undefined) {
                this.removeWithConfirm(node);
              }
            }, 0)
          } else {
            this.RowMenuRow($r('app.media.aura_window'), '在新标签页打开', (): void => {
              const node = this.findNodeById(this.rowMenuId);
              this.rowMenuId = '';
              if (node !== undefined) {
                this.openNode(node);
              }
            }, 0)
            this.RowMenuRow($r('app.media.aura_edit'), '编辑', (): void => {
              const node = this.findNodeById(this.rowMenuId);
              this.rowMenuId = '';
              if (node !== undefined) {
                this.openForm('editBookmark', node);
              }
            }, 0)
            this.RowMenuRow($r('app.media.aura_folder'), '移动到', (): void => {
              const node = this.findNodeById(this.rowMenuId);
              if (node !== undefined) {
                this.openMove(node);
              }
            }, 0)
            this.RowMenuRow($r('app.media.aura_copy'), '复制链接', (): void => {
              const node = this.findNodeById(this.rowMenuId);
              this.rowMenuId = '';
              if (node !== undefined && node.url !== undefined) {
                this.copyLink(node.url);
              }
            }, 0)
            this.RowMenuRow($r('app.media.aura_trash'), '删除', (): void => {
              const node = this.findNodeById(this.rowMenuId);
              this.rowMenuId = '';
              if (node !== undefined) {
                this.removeWithConfirm(node);
              }
            }, 0)
          }
        }
        .width(190)
        .padding({ top: 6, bottom: 6 })
        .borderRadius(22)
        .backgroundColor($r('app.color.menu_glass'))
        .shadow({ radius: 26, color: $r('app.color.shadow'), offsetY: 8 })
        .position({ x: this.rowMenuX, y: this.rowMenuY })
        .transition(TransitionEffect.asymmetric(
          TransitionEffect.opacity(0)
            .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 })),
          TransitionEffect.opacity(0)
        ).animation({ duration: 180, curve: Curve.Friction }))
      }
      .width('100%')
      .height('100%')
    }
  }

  // 添加/编辑表单（页内自绘，弹层挂 body Stack = 遮罩盖满全屏、卡片居中）。
  @Builder
  private FormDialog() {
    if (this.dialogMode !== '') {
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
            this.cancelForm();
          })

        Row() {
        Column({ space: 14 }) {
          Text(this.formHeadline())
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Column({ space: 6 }) {
            Text('名称')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
              .width('100%')
            TextInput({ text: this.formTitle, placeholder: '名称' })
              .height(46)
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
              .backgroundColor($r('app.color.surface_secondary'))
              .borderRadius(12)
              .onChange((value: string): void => {
                this.formTitle = value;
              })
          }
          .width('100%')

          if (this.dialogMode === 'addBookmark' || this.dialogMode === 'editBookmark') {
            Column({ space: 6 }) {
              Text('网址')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
              TextInput({ text: this.formUrl, placeholder: 'https://…' })
                .height(46)
                .fontSize(15)
                .fontColor($r('app.color.text_primary'))
                .backgroundColor($r('app.color.surface_secondary'))
                .borderRadius(12)
                .onChange((value: string): void => {
                  this.formUrl = value;
                })
            }
            .width('100%')
          }

          Row({ space: 12 }) {
            Row() {
              Text('取消')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.text_primary'))
            }
            .justifyContent(FlexAlign.Center)
            .layoutWeight(1)
            .height(44)
            .borderRadius(12)
            .backgroundColor($r('app.color.surface_secondary'))
            .onClick(() => {
              this.cancelForm();
            })

            Row() {
              Text('保存')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('app.color.on_accent'))
            }
            .justifyContent(FlexAlign.Center)
            .layoutWeight(1)
            .height(44)
            .borderRadius(12)
            .backgroundColor($r('app.color.accent_primary'))
            .onClick(() => {
              this.confirmForm();
            })
          }
          .width('100%')
        }
        .width('100%')
        .padding(20)
        .borderRadius(22)
        .backgroundColor($r('app.color.menu_glass'))
        .shadow({ radius: 26, color: $r('app.color.shadow'), offsetY: 8 })
        // 卡片入场/退场动效（1.0.67）：此前只有遮罩有过渡、卡片本体瞬跳 ——
        // 「新建/编辑」弹窗开和关都"很快"。进入用弹簧弹出、退出 320ms 柔和收起。
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
      // 能播、退场被整棵子树原子删除（真机："取消时瞬间变亮闪一下"）。
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.opacity(1),
        TransitionEffect.opacity(0).animation({ duration: 340, curve: Curve.Friction })
      ))
    }
  }

  // 「移动到」文件夹选择器（自绘卡，列表 = BFS 收集的全部文件夹）。
  @Builder
  private FolderPicker() {
    if (this.pickerVisible) {
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.modal_scrim'))
          // 遮罩柔和淡入淡出（1.0.66/67）：同 FormDialog（进入 260ms / 退出 380ms）。
          .transition(TransitionEffect.asymmetric(
            TransitionEffect.opacity(0).animation({ duration: 260, curve: Curve.Friction }),
            TransitionEffect.opacity(0).animation({ duration: 380, curve: Curve.Friction })
          ))
          .onClick(() => {
            this.pickerVisible = false;
          })

        Row() {
        Column({ space: 12 }) {
          Text('移动到')
            .fontSize(17)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          List({ space: 4 }) {
            LazyForEach(this.pickerDataSource, (option: FolderOption) => {
              ListItem() {
                FolderPickerRow({
                  folderId: option.id,
                  title: option.title,
                  childCount: option.childCount,
                  onPick: (id: string): void => {
                    this.pickMoveTarget(id);
                  }
                })
              }
            }, (option: FolderOption): string => option.id)
          }
          .constraintSize({ maxHeight: 380 })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
          .width('100%')
        }
        .width('100%')
        .padding(20)
        .borderRadius(22)
        .backgroundColor($r('app.color.menu_glass'))
        .shadow({ radius: 26, color: $r('app.color.shadow'), offsetY: 8 })
        // 卡片入场/退场动效（1.0.67）：同 FormDialog（「移动到」选择器）。
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
      // 退场动效（1.0.68）：同 FormDialog（挂根节点）。
      .transition(TransitionEffect.asymmetric(
        TransitionEffect.opacity(1),
        TransitionEffect.opacity(0).animation({ duration: 340, curve: Curve.Friction })
      ))
    }
  }

  // 悬浮批量操作条：绝对定位于 body Stack 底部，自绘仿玻璃药丸（float_bar_bg +
  // 细描边 + 投影）。**宽度随内容走**：外层全宽 Row 只负责底部定位与水平居中，
  // 自身透明且透传点击；内层 Scroll 不再设 minWidth，只约束 maxWidth 100%，
  // 于是只有一个「全选」时就是一小颗药丸，四周/下方都露出列表与页面底色，
  // 不会被拉成横贯屏幕的白色长条（用户反馈「和长」「有遮罩」）。
  // 选中后出现「删除 / 移动」，药丸随之变长；极端宽字符靠横向 Scroll 兜底。
  // 药丸高 36 / 圆角 18（1.0.69：用户反馈「全选胶囊高度很大」，42→36 与
  // 整体控件尺度统一：粘贴 32 / 取消 36 / 地址胶囊 40；容器仍 5vp 衬距，
  // 46 总高配 23 圆角恰为整圆胶囊）。列表底部留白随之为 50。
  @Builder
  private BatchActionBar() {
    if (this.selectMode) {
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
              this.selectAllVisible();
            })

            if (this.selectedIds.length > 0) {
              Row({ space: 6 }) {
                Image($r('app.media.aura_trash'))
                  .width(16)
                  .height(16)
                  .fillColor($r('app.color.danger'))
                Text(`删除 (${this.selectedIds.length})`)
                  .fontSize(14)
                  .fontColor($r('app.color.danger'))
              }
              .height(36)
              .padding({ left: 16, right: 16 })
              .borderRadius(18)
              .onClick(() => {
                this.batchRemove();
              })

              Row({ space: 6 }) {
                Image($r('app.media.aura_folder'))
                  .width(16)
                  .height(16)
                  .fillColor($r('app.color.accent_primary'))
                Text(`移动 (${this.selectedIds.length})`)
                  .fontSize(14)
                  .fontColor($r('app.color.accent_primary'))
              }
              .height(36)
              .padding({ left: 16, right: 16 })
              .borderRadius(18)
              .onClick(() => {
                this.batchMove();
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

  build() {
    GlassPage({
      title: this.selectMode ? `已选 ${this.selectedIds.length} 项` : '书签',
      scrollers: [this.listScroller],
      menus: {
        value: this.selectMode
          ? [
            {
              content: {
                icon: $r('app.media.aura_close'),
                label: '取消',
                action: (): void => {
                  this.exitSelect();
                }
              }
            }
          ]
          : [
            {
              content: {
                icon: $r('app.media.aura_plus'),
                label: '添加',
                isEnabled: true,
                action: (): void => {
                  this.showPlusSheet();
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
      },
      onBack: (): void => {
        this.handleBack();
      }
    }) {
    // body 包 Stack：行菜单/表单弹窗挂这里（viewport 固定，遮罩盖满全屏）。
    Stack({ alignContent: Alignment.TopStart }) {
    Column() {
      // 1.0.179：搜索框与列表合并进同一个 Scroll —— 外层 top padding 会把
      // 滚动视口压低到标题行下方，内容进不了标题行区域（顶部渐变模糊丢失，
      // 1.0.121 同类教训）；搜索框随内容滚动，输入时组件不重建、焦点不丢。
      Scroll(this.listScroller) {
      Column() {
      Row({ space: 8 }) {
        Image($r('app.media.chromium_search'))
          .width(16)
          .height(16)
          .fillColor($r('app.color.icon_secondary'))
        TextInput({ text: this.searchText, placeholder: '搜索书签' })
          .layoutWeight(1)
          .height(38)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .placeholderColor($r('app.color.text_secondary'))
          .backgroundColor(Color.Transparent)
          .onChange((value: string) => {
            const wasSearching: boolean = this.searchText.trim().length > 0;
            this.searchText = value;
            this.runSearch(value);
            // 搜索态 ↔ 普通态内容整体替换：归顶（旧版靠两个互斥 Scroll 重建
            // 自然归零；合并后显式下发，且仅在切换瞬间，与旧行为一致）。
            if (wasSearching !== (value.trim().length > 0)) {
              setTimeout((): void => {
                this.listScroller.scrollEdge(Edge.Top);
              }, 0);
            }
          })
      }
      .width('100%')
      .height(40)
      .borderRadius(20)
      .backgroundColor($r('app.color.surface_secondary'))
      .padding({ left: 12, right: 12 })
      .margin({ bottom: 12 })

      if (this.searchText.trim().length > 0) {
        // 搜索：引擎全树匹配（searchBookmarks，命中带 path）。
        if (this.searchResults.length === 0) {
          Text('没有匹配的书签')
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 40 })
        }
        Column() {
          // 键值带上标题/网址：ForEach 键值不变会直接复用旧组件（item builder
          // 不重跑），改名/改网址保存后行内文案就不会刷新（同 HomeSurface 磁贴
          // 的「已保存未生效」根因）。
          ForEach(this.searchResults, (node: BookmarkNode, index: number) => {
            this.BookmarkRow(node, index, this.searchResults.length)
          }, (node: BookmarkNode): string => `s|${node.id}|${node.title}|${node.url ?? ''}`)
        }
        .width('100%')
        .borderRadius(16)
        .backgroundColor($r('app.color.card_background'))
        .clip(true)
      } else if (this.loading) {
        Text('加载中…')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 40 })
      } else {
        if (this.currentNodes.length === 0 && this.currentFolderId.length > 0) {
          // 空文件夹提示（v3.1 重写时遗漏，用户反馈补回）。
          Column({ space: 6 }) {
            Text('这个文件夹是空的')
              .fontSize(15)
              .fontColor($r('app.color.text_secondary'))
            Text('右上角 + 可以添加书签或新建文件夹')
              .fontSize(13)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .margin({ top: 60 })
        } else {
        // 根级置顶：主页书签（「首页」文件夹）入口 —— 主页磁贴显示的就是这里
        // 的书签；文件夹由主页在手机书签根下自动创建维护。选择模式不出（这条
        // 是跳转入口，不参与批量勾选）。
        if (this.currentFolderId.length === 0 && !this.selectMode && this.homeFolderId.length > 0) {
          this.HomeFolderRow()
        }
        // 当前层：根级 = 三个根文件夹；子层 = 该文件夹内容（文件夹在前）。
        ForEach(this.currentNodes, (node: BookmarkNode, index: number) => {
          if (node.type === 'folder') {
            this.FolderRow(node)
          }
        }, (node: BookmarkNode): string =>
          `f|${node.id}#${node.childCount ?? 0}|${node.title}`)

        if (this.currentFolderId.length === 0 && this.recentNodes.length > 0) {
          AuraSectionLabel({ text: '最近添加' })
          Column() {
            ForEach(this.recentNodes, (node: BookmarkNode, index: number) => {
              this.BookmarkRow(node, index, this.recentNodes.length)
            }, (node: BookmarkNode): string => `r|${node.id}|${node.title}|${node.url ?? ''}`)
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)
        } else if (this.currentFolderId.length > 0) {
          Column() {
            ForEach(this.currentNodes, (node: BookmarkNode, index: number) => {
              if (node.type !== 'folder') {
                this.BookmarkRow(node, index, this.currentNodes.length)
              }
            }, (node: BookmarkNode): string => `u|${node.id}|${node.title}|${node.url ?? ''}`)
          }
          .width('100%')
          .borderRadius(16)
          .backgroundColor($r('app.color.card_background'))
          .clip(true)
        }
        }
      }
      }
      .width('100%')
      // 大标题带：滚动内容穿过「书签」大标题时逐渐虚化（见 GlassPage 文件头）。
      // 顶部留白进内容层（不是视口）：视口保持全高，内容才能穿过状态栏/标题行；
      // 末尾留白同理写进滚动内容，列表铺满全高无死区（见 BatchActionBar 注释）。
      .padding({ top: glassHeaderInsetVp(), bottom: this.selectMode ? (50 + glassBottomInsetVp()) : 0 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .align(Alignment.TopStart)

      // 批量操作条改为悬浮胶囊（见 BatchActionBar()，挂 body Stack，不占流式高度）。
    }
    .width('100%')
    .height('100%')
    .padding({
      left: 16,
      right: 16
      // 1.0.179：top 移入滚动内容层——外层 top padding 会压低滚动视口，
      // 内容永远进不了标题行区域，顶部渐变模糊丢失（1.0.121 同类教训）。
      // 选择态底部占位不写在这里：会缩短滚动视口 → 视口边缘出现切一半的行
      // + 底部死区（用户反馈的"有遮罩"）。改为写进滚动内容末尾。
    })

    this.RowMenuOverlay()
    this.FormDialog()
    this.FolderPicker()
    this.BatchActionBar()
    }
    .width('100%')
    .height('100%')
    }
  }
}

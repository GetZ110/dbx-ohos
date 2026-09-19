/**
 * Native file-picker bridge for local database files.
 *
 * Exposed to the Web page as `window.dbxNativeWindow.pickDatabaseFile`
 * (ArkWeb keeps only one `javaScriptProxy` registration per page, see
 * ShellBridge); the injected
 * `filePickerScript` in Index.ets turns the "file path" row of the connection
 * dialog into a read-only display box plus a "select file" button, and routes
 * the button through this bridge.
 *
 * Why this exists: the upstream dialog browses files with
 * `@tauri-apps/plugin-dialog`, which is unavailable on HarmonyOS (the shell is
 * "desktop-like" but deliberately not Tauri), and HarmonyOS denies an app
 * access to arbitrary paths. The sanctioned way to obtain a usable path is the
 * system document picker plus `ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY`
 * (already declared in module.json5 and allowed by the signing profile), which
 * lets the Rust backend open SQLite files stored under the user's Documents
 * directory directly.
 *
 * Pickers are asynchronous but `javaScriptProxy` methods are synchronous, so
 * every request carries an id and the result is pushed back with
 * `WebviewController.runJavaScript('window.__dbxFilePickerDeliver(...)')`.
 *
 * Delivery contract (see filePickerScript):
 *   status 'ok'      -> `path` is usable by the backend as-is;
 *   status 'copied'  -> `path` is a sandbox copy (edits do not reach the original);
 *   status 'error'   -> `message` explains the failure;
 *   status 'cancelled'/unknown -> the page stays silent.
 */
import { abilityAccessCtrl, bundleManager, common, Permissions } from '@kit.AbilityKit';
import { Environment, fileIo, fileShare, fileUri, picker } from '@kit.CoreFileKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { webview } from '@kit.ArkWeb';
import { ThemePrefs } from './ThemePrefs';

const DOMAIN = 0xDB9;
const TAG = 'DBX_FILEPICKER';
/** Restricted permission granted to the app through its signing profile. */
const DOCUMENTS_PERMISSION: Permissions = 'ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY';
/** `authResults[]` value that means "granted". */
const PERMISSION_GRANTED: number = 0;
/** Folder under the user Documents directory that holds every local database. */
const IMPORT_DIR_NAME: string = 'DBX';
/** Preferences key holding user-authorized folders ("uri|path" per line). */
const LAST_DIR_KEY = 'dbx-last-dir';
const GRANTED_FOLDERS_KEY: string = 'dbx-granted-folders';
/** READ_MODE | WRITE_MODE for fileShare policies. */
const READ_WRITE_MODE: number = 3;
/** Suffix filters offered by the select page ("description|.ext,.ext"). */
const DB_SUFFIX_FILTERS: string[] = ['数据库文件|.db,.sqlite,.sqlite3,.db3,.duckdb,.accdb'];
/** Suffix choices offered by the save page. */
const DB_SUFFIX_CHOICES: string[] = ['SQLite 数据库|.db,.sqlite,.sqlite3', 'DuckDB 数据库|.duckdb'];
/** Default name pre-filled by the "create database file" action. */
const DEFAULT_DB_NAME: string = 'database.db';

/** One picker round-trip, delivered back into the page. */
interface PickerReply {
  status: string;
  path: string;
  message: string;
}

/** Build a reply (explicitly typed: ArkTS rejects bare object literals). */
function reply(status: string, path: string, message: string): PickerReply {
  const value: PickerReply = { status: status, path: path, message: message };
  return value;
}

/** User cancelled the picker (or a rejection that means the same). */
const CANCELLED: PickerReply = { status: 'cancelled', path: '', message: '' };

/** A folder the user authorized through the system folder picker. */
interface GrantedFolder {
  uri: string;
  path: string;
}

/**
 * Page-facing bridge object (exposed through `ShellBridge` as
 * `window.dbxNativeWindow`, because ArkWeb keeps only one proxy object).
 */
export class FilePickerBridge {
  private controller: webview.WebviewController | null = null;
  private context: common.UIAbilityContext | null = null;
  /** Guards against a second picker while a system dialog is already up. */
  private busy: boolean = false;

  /**
   * Called from Index.aboutToAppear: the bridge needs the controller to push
   * results back and the ability context to open the picker and copy files.
   */
  attach(controller: webview.WebviewController, context: common.UIAbilityContext): void {
    this.controller = controller;
    this.context = context;
  }

  /**
   * Opens the system document picker and reports the chosen path back to the
   * page. `mode` is 'open' (pick an existing database) or 'create' (save page,
   * which creates an empty file the SQLite driver then initialises).
   */
  pickDatabaseFile(requestId: string, mode: string): void {
    const ctx: common.UIAbilityContext | null = this.context;
    if (ctx === null) {
      this.deliver(requestId, 'error', '', '应用上下文不可用');
      return;
    }
    if (this.busy) {
      this.deliver(requestId, 'error', '', '已有文件选择正在进行');
      return;
    }
    this.busy = true;
    hilog.info(DOMAIN, TAG, 'pick requested, mode=%{public}s, id=%{public}s', mode, requestId);
    this.ensureDocumentsPermission(ctx)
      .then((granted: boolean) => {
        return mode === 'create' ? this.saveNew(ctx, granted) : this.selectExisting(ctx, granted);
      })
      .then((reply: PickerReply) => {
        this.busy = false;
        hilog.info(DOMAIN, TAG, 'pick finished, status=%{public}s, path=%{public}s',
          reply.status, reply.path.length > 0 ? reply.path : '(none)');
        this.deliver(requestId, reply.status, reply.path, reply.message);
      })
      .catch((err: BusinessError) => {
        this.busy = false;
        hilog.warn(DOMAIN, TAG, 'pick failed: %{public}s', err.message);
        this.deliver(requestId, FilePickerBridge.classify(err.message), '', err.message);
      });
  }

  /**
   * Ask the user to authorize a folder, then remember it for good.
   *
   * This is what makes databases outside `Documents/DBX` editable in place.
   * A folder picked through the system picker only carries a temporary grant,
   * but `fileShare.persistPermission()` makes it durable and — verified on
   * device 2026-09-19 — the granted folder is writable *by path*, recursively,
   * including creating the `-journal`/`-wal` siblings SQLite needs. The grant
   * is not active by itself after a restart: `activateGrantedFolders()` has to
   * re-arm it on every launch.
   */
  pickDatabaseFolder(requestId: string): void {
    const ctx: common.UIAbilityContext | null = this.context;
    if (ctx === null) {
      this.deliver(requestId, 'error', '', '应用上下文不可用');
      return;
    }
    this.runFolderGrant(ctx, requestId).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'folder grant failed: %{public}s', err.message);
      this.deliver(requestId, FilePickerBridge.classify(err.message), '', err.message);
    });
  }

  /** Re-arm every remembered folder grant (call on launch and on foreground). */
  activateGrantedFolders(): void {
    this.runActivateGranted().catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'activate granted folders failed: %{public}s', err.message);
    });
  }

  /**
   * `<Documents>/DBX`: the app's own drop folder. It is not revoked here
   * because it is not a picker grant - it depends on the user_grant
   * `READ_WRITE_DOCUMENTS_DIRECTORY` permission, whose live state
   * `documentsStatus()` reports.
   */
  defaultFolder(): string {
    FilePickerBridge.ensureDbxDir();
    return FilePickerBridge.dbxDir();
  }

  /**
   * Live state of `<Documents>/DBX` as `'<permission>|<writable>'`.
   *
   * permission: 'granted' | 'denied' | 'unknown'
   * writable:   'yes' | 'no'   (proved by creating and deleting a probe file)
   *
   * The folder is *not* unconditionally available: it is governed by the
   * `user_grant` permission `READ_WRITE_DOCUMENTS_DIRECTORY`, which the user can
   * deny or revoke in system settings at any time, so the manager panel asks for
   * this every time it refreshes instead of assuming.
   */
  documentsStatus(): string {
    const permission: string = FilePickerBridge.documentsPermissionState();
    const dir: string = FilePickerBridge.dbxDir();
    let writable: string = 'no';
    if (dir.length > 0) {
      writable = FilePickerBridge.ensureWritableDir(dir) ? 'yes' : 'no';
    }
    hilog.info(DOMAIN, TAG, 'documents status: %{public}s|%{public}s', permission, writable);
    return `${permission}|${writable}`;
  }

  /**
   * Ask the system for the Documents directory permission (no-op, no dialog,
   * when it is already granted) and deliver 'granted' | 'denied' | 'error'.
   */
  requestDocumentsPermission(requestId: string): void {
    const ctx: common.UIAbilityContext | null = this.context;
    if (ctx === null) {
      this.deliver(requestId, 'error', '', '应用上下文不可用');
      return;
    }
    if (this.busy) {
      this.deliver(requestId, 'error', '', '已有文件操作正在进行');
      return;
    }
    this.busy = true;
    this.ensureDocumentsPermission(ctx)
      .then((granted: boolean) => {
        this.busy = false;
        this.deliver(requestId, granted ? 'granted' : 'denied', '', '');
      })
      .catch((err: BusinessError) => {
        this.busy = false;
        this.deliver(requestId, 'error', '', err.message);
      });
  }

  /**
   * Forget an authorized folder and drop its persistent grant.  /**
   * Forget an authorized folder and drop its persistent grant.
   *
   * Returns 'ok' | 'notfound'. The entry is removed from the remembered list
   * synchronously (so the page can re-read `grantedFolders()` right away) while
   * the platform calls run in the background: a persisted grant only becomes
   * effective through `activatePermission()`, and we no longer run that for a
   * forgotten folder, so dropping it here really does cut access on the next
   * launch even if the async revoke fails.
   */
  revokeGrantedFolder(path: string): string {
    if (path.length === 0) {
      return 'notfound';
    }
    const kept: GrantedFolder[] = [];
    let target: GrantedFolder | null = null;
    for (const folder of FilePickerBridge.loadGrantedFolders()) {
      if (folder.path === path) {
        target = folder;
      } else {
        kept.push(folder);
      }
    }
    if (target === null) {
      hilog.info(DOMAIN, TAG, 'revoke: %{public}s is not in the granted list', path);
      return 'notfound';
    }
    FilePickerBridge.saveGrantedFolders(kept);
    if (ThemePrefs.getPref(LAST_DIR_KEY) === path) {
      ThemePrefs.savePref(LAST_DIR_KEY, '');
    }
    this.runRevoke(target);
    return 'ok';
  }

  /** Newline-separated list of authorized folders, for the page to display. */
  grantedFolders(): string {
    const paths: string[] = [];
    for (const folder of FilePickerBridge.loadGrantedFolders()) {
      paths.push(folder.path);
    }
    return paths.join('\n');
  }

  private async runFolderGrant(ctx: common.UIAbilityContext, requestId: string): Promise<void> {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.selectMode = picker.DocumentSelectMode.FOLDER;
    const anchor: string = FilePickerBridge.anchorUri();
    if (anchor.length > 0) {
      options.defaultFilePathUri = anchor;
    }
    const documentPicker = new picker.DocumentViewPicker(ctx);
    const uris: string[] = await documentPicker.select(options);
    if (uris.length === 0 || uris[0].length === 0) {
      this.deliver(requestId, 'cancelled', '', '');
      return;
    }
    const result: PickerReply = await FilePickerBridge.registerGrantedFolder(uris[0]);
    this.deliver(requestId, result.status, result.path, result.message);
  }

  /** Persist a folder URI handed out by the picker and remember it. */
  private static async registerGrantedFolder(uri: string): Promise<PickerReply> {
    const path: string = FilePickerBridge.realPath(uri);
    if (path.length === 0) {
      return reply('error', '', '无法解析所选文件夹的路径');
    }
    const policy: fileShare.PolicyInfo = { uri: uri, operationMode: READ_WRITE_MODE };
    await fileShare.persistPermission([policy]);
    const kept: GrantedFolder[] = [];
    for (const folder of FilePickerBridge.loadGrantedFolders()) {
      if (folder.uri !== uri) {
        kept.push(folder);
      }
    }
    const entry: GrantedFolder = { uri: uri, path: path };
    kept.push(entry);
    FilePickerBridge.saveGrantedFolders(kept);
    ThemePrefs.savePref(LAST_DIR_KEY, path);
    const writable: boolean = FilePickerBridge.ensureWritableDir(path);
    hilog.info(DOMAIN, TAG, 'folder granted: %{public}s writable=%{public}s', path,
      writable ? 'true' : 'false');
    return writable ? reply('granted', path, '') : reply('error', path, '所选文件夹不可写');
  }

  /** Current grant state of the Documents directory permission. */
  private static documentsPermissionState(): string {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      const tokenId: number = info.appInfo.accessTokenId;
      const manager = abilityAccessCtrl.createAtManager();
      const status: number = manager.checkAccessTokenSync(tokenId, DOCUMENTS_PERMISSION);
      return status === PERMISSION_GRANTED ? 'granted' : 'denied';
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'permission check failed: %{public}s', e.message);
      return 'unknown';
    }
  }

  /** Best-effort platform revoke; failures only mean the memory is gone first. */
  private runRevoke(folder: GrantedFolder): void {
    const policy: fileShare.PolicyInfo = { uri: folder.uri, operationMode: READ_WRITE_MODE };
    fileShare.deactivatePermission([policy])
      .then(() => fileShare.revokePermission([policy]))
      .then(() => {
        hilog.info(DOMAIN, TAG, 'revoked folder grant %{public}s', folder.path);
      })
      .catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'platform revoke failed (%{public}s): %{public}d %{public}s',
          folder.path, err.code, err.message);
      });
  }

  private async runActivateGranted(): Promise<void> {
    for (const folder of FilePickerBridge.loadGrantedFolders()) {
      const policy: fileShare.PolicyInfo = { uri: folder.uri, operationMode: READ_WRITE_MODE };
      try {
        await fileShare.activatePermission([policy]);
        hilog.info(DOMAIN, TAG, 'activated granted folder %{public}s', folder.path);
      } catch (err) {
        const e = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'activate failed (%{public}s): code=%{public}d %{public}s',
          folder.path, e.code, e.message);
      }
    }
  }

  /**
   * Remembered authorized folders, one `uri|path` per line.
   *
   * Only printable characters plus '\n' may be used: the preferences backend is
   * an XML file, and a raw control character makes it unparsable (the framework
   * then resets the whole store). A picker URI never contains '|', so the first
   * one separates the two fields.
   */
  private static loadGrantedFolders(): GrantedFolder[] {
    const out: GrantedFolder[] = [];
    const raw: string = ThemePrefs.getPref(GRANTED_FOLDERS_KEY);
    if (raw.length === 0) {
      return out;
    }
    for (const line of raw.split('\n')) {
      const sep: number = line.indexOf('|');
      if (sep <= 0 || sep >= line.length - 1) {
        continue;
      }
      const entry: GrantedFolder = { uri: line.substring(0, sep), path: line.substring(sep + 1) };
      out.push(entry);
    }
    return out;
  }

  private static saveGrantedFolders(folders: GrantedFolder[]): void {
    const lines: string[] = [];
    for (const folder of folders) {
      lines.push(`${folder.uri}|${folder.path}`);
    }
    ThemePrefs.savePref(GRANTED_FOLDERS_KEY, lines.join('\n'));
  }

  private async ensureDocumentsPermission(ctx: common.UIAbilityContext): Promise<boolean> {
    try {
      const manager = abilityAccessCtrl.createAtManager();
      const perms: Permissions[] = [DOCUMENTS_PERMISSION];
      const result = await manager.requestPermissionsFromUser(ctx, perms);
      const granted: boolean = result.authResults.length > 0 && result.authResults[0] === PERMISSION_GRANTED;
      hilog.info(DOMAIN, TAG, 'Documents permission granted=%{public}s', granted ? 'true' : 'false');
      return granted;
    } catch (err) {
      const e = err as BusinessError;
      // Typically 12100001: the profile of this build does not allow the ACL.
      hilog.warn(DOMAIN, TAG, 'Documents permission request failed: %{public}s', e.message);
      return false;
    }
  }

  /**
   * Where the picker should open: the directory used last time, else
   * `<Documents>/DBX`. `defaultFilePathUri` only positions the system UI (it
   * cannot restrict it), but it saves the user from re-navigating every time.
   */
  private static anchorUri(): string {
    let target: string = ThemePrefs.getPref(LAST_DIR_KEY);
    if (target.length === 0) {
      // Nothing picked yet: fall back to the most recently granted folder, so
      // the first pick after a grant starts inside it.
      const folders: GrantedFolder[] = FilePickerBridge.loadGrantedFolders();
      if (folders.length > 0) {
        target = folders[folders.length - 1].path;
      }
    }
    if (target.length > 0) {
      const uri: string = FilePickerBridge.uriOf(target);
      if (uri.length > 0) {
        return uri;
      }
    }
    return FilePickerBridge.dbxUri();
  }

  /** Select an existing database file from `<Documents>/DBX`. */
  private async selectExisting(ctx: common.UIAbilityContext, granted: boolean): Promise<PickerReply> {
    if (!FilePickerBridge.ensureDbxDir()) {
      return reply('error', '', `无法创建或写入 Documents/${IMPORT_DIR_NAME} 目录`);
    }
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = DB_SUFFIX_FILTERS;
    const anchor: string = FilePickerBridge.anchorUri();
    if (anchor.length > 0) {
      options.defaultFilePathUri = anchor;
    }
    const documentPicker = new picker.DocumentViewPicker(ctx);
    const uris: string[] = await documentPicker.select(options);
    if (uris.length === 0 || uris[0].length === 0) {
      return CANCELLED;
    }
    return FilePickerBridge.resolve(uris[0], granted);
  }

  /** Create a new (empty) database file inside `<Documents>/DBX`. */
  private async saveNew(ctx: common.UIAbilityContext, granted: boolean): Promise<PickerReply> {
    if (!FilePickerBridge.ensureDbxDir()) {
      return reply('error', '', `无法创建或写入 Documents/${IMPORT_DIR_NAME} 目录`);
    }
    const options = new picker.DocumentSaveOptions();
    options.newFileNames = [DEFAULT_DB_NAME];
    options.fileSuffixChoices = DB_SUFFIX_CHOICES;
    const anchor: string = FilePickerBridge.anchorUri();
    if (anchor.length > 0) {
      options.defaultFilePathUri = anchor;
    }
    const documentPicker = new picker.DocumentViewPicker(ctx);
    const uris: string[] = await documentPicker.save(options);
    if (uris.length === 0 || uris[0].length === 0) {
      return CANCELLED;
    }
    return FilePickerBridge.resolve(uris[0], granted);
  }

  /**
   * Turn a picked URI into the path the Rust backend should open.
   *
   * Only files under `<Documents>/DBX` (the one place the app holds a durable
   * directory ACL for, ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY) or under
   * a folder the user authorized are accepted. Anything else
   * is refused with `status='outside'`: the picker only grants a temporary,
   * single-file permission, and SQLite also needs to create
   * `-journal`/`-wal`/`-shm` siblings, which that grant never covers. Silently
   * copying instead would make "I picked this file but my inserts went
   * somewhere else" possible, which is exactly what we refuse.
   */
  private static async resolve(uri: string, granted: boolean): Promise<PickerReply> {
    const realPath: string = FilePickerBridge.realPath(uri);
    if (!FilePickerBridge.isAllowedPath(realPath)) {
      hilog.info(DOMAIN, TAG, 'rejected path outside the allowed roots: %{public}s', realPath);
      return reply('outside', realPath, '');
    }
    const dir: string = FilePickerBridge.dirOf(realPath);
    if (!granted || dir.length === 0 || !FilePickerBridge.ensureWritableDir(dir)) {
      return reply('error', '', '无法写入所选目录（授权可能已失效，请重新授权该文件夹）');
    }
    ThemePrefs.savePref(LAST_DIR_KEY, dir);
    return reply('ok', realPath, '');
  }

  /** Directory part of `path` ('' when there is none). */
  private static dirOf(path: string): string {
    const slash: number = path.lastIndexOf('/');
    return slash > 0 ? path.substring(0, slash) : '';
  }

  /** Resolve `file://docs/...` to the underlying absolute path. */
  private static realPath(uri: string): string {
    try {
      const path: string = new fileUri.FileUri(uri).path;
      return path.length > 0 ? path : '';
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'uri -> path failed (%{public}s): %{public}s', uri, e.message);
      return '';
    }
  }

  /** `file://docs/...` URI of a directory path ('' when it cannot be built). */
  private static uriOf(dir: string): string {
    try {
      return dir.length > 0 ? fileUri.getUriFromPath(dir) : '';
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'path -> uri failed (%{public}s): %{public}s', dir, e.message);
      return '';
    }
  }

  /** `<Documents>/DBX`, or '' when the Documents directory is unavailable. */
  private static dbxDir(): string {
    const documents: string = FilePickerBridge.documentsDir();
    return documents.length > 0 ? `${documents}/${IMPORT_DIR_NAME}` : '';
  }

  /** URI of that folder, used as the picker's start location. */
  private static dbxUri(): string {
    const dir: string = FilePickerBridge.dbxDir();
    if (dir.length === 0) {
      return '';
    }
    try {
      return fileUri.getUriFromPath(dir);
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'dbx dir uri failed: %{public}s', e.message);
      return '';
    }
  }

  /**
   * True when `path` may be edited in place.
   *
   * Two kinds of location qualify: `Documents/DBX` (covered by the Documents
   * directory permission) and any folder the user authorized through the folder
   * picker. The picker cannot be locked to a folder (its 最近/桌面/文档/下载
   * navigation is system UI), so a pick anywhere else is refused outright
   * instead of being silently copied — what the user selected is exactly what
   * the connection edits.
   */
  private static isAllowedPath(path: string): boolean {
    if (path.length === 0) {
      return false;
    }
    if (FilePickerBridge.isUnder(path, FilePickerBridge.dbxDir())) {
      return true;
    }
    for (const folder of FilePickerBridge.loadGrantedFolders()) {
      if (FilePickerBridge.isUnder(path, folder.path)) {
        return true;
      }
    }
    return false;
  }

  private static isUnder(path: string, root: string): boolean {
    if (root.length === 0) {
      return false;
    }
    return path === root || path.startsWith(`${root}/`);
  }

  /** Make sure the folder exists and is writable; create it when missing. */
  private static ensureDbxDir(): boolean {
    const dir: string = FilePickerBridge.dbxDir();
    return dir.length > 0 && FilePickerBridge.ensureWritableDir(dir);
  }

  /**
   * Prove write access to `dir` with a throwaway file.
   *
   * A directory probe (not "can I open this file") is the check that matches
   * what SQLite needs: it creates `-journal`/`-wal`/`-shm` siblings next to the
   * database, which a single-file picker grant never covers.
   */
  private static ensureWritableDir(dir: string): boolean {
    try {
      if (!fileIo.accessSync(dir)) {
        fileIo.mkdirSync(dir, true);
      }
      const probe: string = `${dir}/.dbx-write-probe-${Date.now()}`;
      const file = fileIo.openSync(probe,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, 'p');
      fileIo.closeSync(file);
      fileIo.unlinkSync(probe);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      hilog.info(DOMAIN, TAG, 'directory not writable (%{public}s): %{public}s', dir, e.message);
      return false;
    }
  }

  /** Absolute path of the user Documents directory ('' when unavailable). */
  private static documentsDir(): string {
    try {
      const dir: string = Environment.getUserDocumentDir();
      return dir.length > 0 ? dir : '';
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'getUserDocumentDir failed: %{public}s', e.message);
      return '';
    }
  }

  /** Picker rejections caused by the user backing out must not surface as errors. */
  private static classify(message: string): string {
    const lowered: string = message.toLowerCase();
    if (lowered.includes('cancel') || message.includes('取消')) {
      return 'cancelled';
    }
    return 'error';
  }

  /** Push one result back into the page. */
  private deliver(requestId: string, status: string, path: string, message: string): void {
    const controller = this.controller;
    if (controller === null) {
      hilog.warn(DOMAIN, TAG, 'result dropped, no WebviewController attached');
      return;
    }
    const js: string = `window.__dbxFilePickerDeliver(${JSON.stringify(requestId)},`
      + `${JSON.stringify(status)},${JSON.stringify(path)},${JSON.stringify(message)})`;
    controller.runJavaScript(js).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'deliver failed: %{public}s', err.message);
    });
  }
}

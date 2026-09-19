/**
 * Single JavaSciptProxy object for the HarmonyOS shell bridges.
 *
 * ArkWeb's Web component keeps only the LAST `javaScriptProxy` registration.
 * Verified on device 2026-09-19: with three registrations
 * (`dbxNativePrefs`, `dbxNativeWindow`, `dbxNativeFilePicker`) only the last one
 * was visible in the page — `window.dbxNativeWindow` disappeared, so the
 * injected `ensureSpacing()` fell back to its 8px reserve and the web toolbar
 * buttons slid underneath the OS window buttons. Every page-facing native
 * method therefore has to hang off ONE registered object.
 *
 * The proxy name stays `dbxNativeWindow` on purpose:
 *   - the built dbx frontend bundle already calls
 *     `globalThis.dbxNativeWindow` (`openExternal`, `toggleMaximize`,
 *     `startMove`), and the dist cannot be rebuilt locally;
 *   - every injected shell script (`windowInjectionScript`,
 *     `harmonyDesktopModeScript`, `windowSafeAreaScript`) reads that name for
 *     the toolbar reserve, theme sync and safe-area padding.
 *
 * `WebPrefsBridge` is deliberately NOT folded in here: it has been inert since
 * the second `javaScriptProxy` was added (only the last registration survives),
 * and enabling native theme persistence is a separate behaviour change that
 * must not ride along with a regression fix. See AGENTS.md.
 */
import { common } from '@kit.AbilityKit';
import { webview } from '@kit.ArkWeb';
import { FilePickerBridge } from './FilePickerBridge';
import { WindowBridge } from './WindowBridge';

export class ShellBridge {
  private windowBridge: WindowBridge = new WindowBridge();
  private filePicker: FilePickerBridge = new FilePickerBridge();

  /**
   * Called from Index.aboutToAppear: the picker needs the controller to push
   * results back into the page and the ability context to open the system
   * picker and copy files.
   */
  attach(controller: webview.WebviewController, context: common.UIAbilityContext): void {
    this.filePicker.attach(controller, context);
  }

  // --- window control (see WindowBridge) ---------------------------------

  minimize(): void {
    this.windowBridge.minimize();
  }

  toggleMaximize(): void {
    this.windowBridge.toggleMaximize();
  }

  close(): void {
    this.windowBridge.close();
  }

  startMove(): void {
    this.windowBridge.startMove();
  }

  isMaximized(): boolean {
    return this.windowBridge.isMaximized();
  }

  getBottomNavHeight(): number {
    return this.windowBridge.getBottomNavHeight();
  }

  getTitleButtonReserveWidth(): number {
    return this.windowBridge.getTitleButtonReserveWidth();
  }

  setDarkMode(dark: boolean): void {
    this.windowBridge.setDarkMode(dark);
  }

  setThemeModeFromWeb(mode: string): void {
    this.windowBridge.setThemeModeFromWeb(mode);
  }

  setAppearanceFromWeb(appearance: string): void {
    this.windowBridge.setAppearanceFromWeb(appearance);
  }

  syncSystemAppearance(): string {
    return this.windowBridge.syncSystemAppearance();
  }

  getEffectiveAppearance(): string {
    return this.windowBridge.getEffectiveAppearance();
  }

  openExternal(url: string): void {
    this.windowBridge.openExternal(url);
  }

  // --- local database file picker (see FilePickerBridge) -----------------

  pickDatabaseFile(requestId: string, mode: string): void {
    this.filePicker.pickDatabaseFile(requestId, mode);
  }

  /** Ask for a folder grant so databases outside Documents/DBX can be edited. */
  pickDatabaseFolder(requestId: string): void {
    this.filePicker.pickDatabaseFolder(requestId);
  }

  /** `<Documents>/DBX`: always usable, shown as a fixed entry in the manager. */
  defaultFolder(): string {
    return this.filePicker.defaultFolder();
  }

  /** Live `'<permission>|<writable>'` state of `<Documents>/DBX`. */
  documentsStatus(): string {
    return this.filePicker.documentsStatus();
  }

  /** Ask for the Documents directory permission ('granted' | 'denied' | 'error'). */
  requestDocumentsPermission(requestId: string): void {
    this.filePicker.requestDocumentsPermission(requestId);
  }

  /** Forget an authorized folder ('ok' | 'notfound'). */
  revokeGrantedFolder(path: string): string {
    return this.filePicker.revokeGrantedFolder(path);
  }

  /** Newline-separated list of authorized folders ('' when none). */
  grantedFolders(): string {
    return this.filePicker.grantedFolders();
  }

  /** Re-arm remembered folder grants; call on launch and on foreground. */
  activateGrantedFolders(): void {
    this.filePicker.activateGrantedFolders();
  }
}

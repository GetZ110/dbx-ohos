import { uiAppearance, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { ThemePrefs } from './ThemePrefs';

const DOMAIN = 0xDB8;
const TAG = 'DBX_WINDOW';

/**
 * Effective light/dark appearance of the DBX UI.
 *
 * The shell needs this (not the raw saved mode) to color the OS chrome/dock,
 * because in `system` mode the effective appearance is whatever the system
 * reports and only the web layer knows it for sure.
 */
type DbxAppearance = 'light' | 'dark';

/**
 * Native window-control bridge exposed to the Web page as `window.dbxNativeWindow`.
 *
 * The HarmonyOS 2-in-1 immersive layout hides the system title bar/decor, and
 * the DBX web toolbar takes over as the application title bar. This bridge
 * provides the window actions used by the small left-side control buttons
 * injected into the web toolbar: minimize, maximize/restore, close and drag.
 */
export class WindowBridge {
  private static mainWindow: window.Window | null = null;
  private static closeHandler: (() => void) | null = null;
  private static appContext: common.UIAbilityContext | null = null;
  private static maximized: boolean = false;
  private static statusListenerBound: boolean = false;
  private static avoidListenerBound: boolean = false;
  // Bottom navigation/side three-button avoid area height in px (0 when absent).
  private static bottomNavHeight: number = 0;
  // Right-side space to reserve in the web toolbar so native window buttons do
  // not overlap toolbar actions. Updated from getTitleButtonRect().
  private static titleButtonReserveWidth: number = 8;
  private static lastDarkMode: boolean | null = null;
  // Last appearance applied to the window's system bar strip, so the periodic
  // sync does not re-issue setWindowSystemBarProperties every second.
  private static lastSystemBarDark: boolean | null = null;
  private static themeMode: string = '';
  // TRUE system dark-mode state, read from uiAppearance.getDarkMode().
  //
  // This is the native source of truth for the 'system' app theme. It is read:
  //   - on demand whenever the user switches the app theme to 'system',
  //   - on every system configuration change (dark mode switched on/off),
  //   - from the Web page's periodic sync (cheap safety net).
  //
  // It must NOT be derived from window.matchMedia / prefers-color-scheme: ArkWeb
  // follows the application color mode we set, so feeding that back would make
  // 'system' echo the last explicit mode instead of the real system state.
  private static systemDark: boolean = false;
  private static systemDarkKnown: boolean = false;
  // Last effective appearance pushed into the OS color mode. The system dock
  // follows the *application* color mode, so this must always track the theme
  // the app is actually rendering — including in 'system' mode.
  private static lastAppliedColorMode: number = -1;

  /**
   * Called from EntryAbility once the main window is available.
   */
  static init(mainWindow: window.Window, closeHandler: () => void, appContext?: common.UIAbilityContext): void {
    WindowBridge.mainWindow = mainWindow;
    WindowBridge.closeHandler = closeHandler;
    WindowBridge.appContext = appContext ?? null;
    WindowBridge.maximized = false;
    WindowBridge.lastDarkMode = null;
    WindowBridge.lastSystemBarDark = null;
    WindowBridge.refreshBottomNavHeight(mainWindow);
    WindowBridge.registerAvoidListener(mainWindow);
    // Re-assert the theme even if the mode string is unchanged: a recreated
    // window stage needs the chrome applied to the new window.
    if (WindowBridge.themeMode.length === 0) {
      WindowBridge.applyThemeForMode(ThemePrefs.getPref('dbx-theme'));
    } else {
      WindowBridge.applyEffectiveAppearance();
    }
    hilog.info(DOMAIN, TAG, 'WindowBridge initialized');

    if (!WindowBridge.statusListenerBound) {
      try {
        mainWindow.on('windowStatusChange', (status: window.WindowStatusType) => {
          WindowBridge.maximized = status === window.WindowStatusType.MAXIMIZE ||
            status === window.WindowStatusType.FULL_SCREEN;
          hilog.info(DOMAIN, TAG, 'window status changed: %{public}d, maximized=%{public}s', status,
            WindowBridge.maximized ? 'true' : 'false');
          if (WindowBridge.maximized) {
            // The dock/system strip becomes visible together with the maximized
            // window, so re-assert the appearance resolved from the native
            // system state (and explicitly, the system bar colors).
            WindowBridge.applyEffectiveAppearance();
          }
        });
        WindowBridge.statusListenerBound = true;
      } catch (err) {
        const e = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'windowStatusChange listener registration failed: %{public}s', e.message);
      }
    }
  }

  /**
   * Read the bottom navigation/three-button avoid area height (px) so the web
   * UI can pad its bottom edge and keep interactive controls clear of the
   * system navigation area. Falls back to keeping the previous value.
   */
  private static refreshBottomNavHeight(win: window.Window): void {
    try {
      const area = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const h = area !== null && area !== undefined ? area.bottomRect.height : 0;
      if (WindowBridge.bottomNavHeight !== h) {
        WindowBridge.bottomNavHeight = h;
        hilog.info(DOMAIN, TAG, 'bottom nav avoid height updated: %{public}d px', h);
      }
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'getWindowAvoidArea failed: %{public}s', e.message);
    }
  }

  /**
   * Keep the stored avoid height in sync when the system navigation area
   * changes (window mode/rotation/fold switches, system bar toggles, etc.).
   */
  private static registerAvoidListener(win: window.Window): void {
    if (WindowBridge.avoidListenerBound) {
      return;
    }
    try {
      win.on('avoidAreaChange', (option) => {
        if (option.type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
          const h = option.area !== null && option.area !== undefined ? option.area.bottomRect.height : 0;
          if (WindowBridge.bottomNavHeight !== h) {
            WindowBridge.bottomNavHeight = h;
            hilog.info(DOMAIN, TAG, 'bottom nav avoid height changed: %{public}d px', h);
          }
        }
      });
      WindowBridge.avoidListenerBound = true;
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'avoidAreaChange listener registration failed: %{public}s', e.message);
    }
  }

  /**
   * Color the window's status/navigation bar area to match the effective app
   * appearance. This is the strip the OS draws adjacent to the app window on a
   * 2-in-1 (and which reads as the dock area when the window is maximized), so
   * it must follow the resolved appearance — including in 'system' mode, where
   * the old code naively treated anything other than an explicit 'dark' as light.
   */
  private static applySystemBarColor(): void {
    const win = WindowBridge.mainWindow;
    if (!win) {
      return;
    }
    const dark: boolean = WindowBridge.resolveAppearance() === 'dark';
    if (WindowBridge.lastSystemBarDark === dark) {
      return;
    }
    // Mark before the async call so a concurrent re-apply does not issue a
    // duplicate request; roll back if it fails.
    WindowBridge.lastSystemBarDark = dark;
    const barColor = dark ? '#1c1c1e' : '#ffffff';
    const contentColor = dark ? '#ffffff' : '#000000';
    win.setWindowSystemBarProperties({
      statusBarColor: barColor,
      navigationBarColor: barColor,
      statusBarContentColor: contentColor,
      navigationBarContentColor: contentColor,
      isStatusBarLightIcon: dark,
      isNavigationBarLightIcon: dark
    }).then(() => {
      hilog.info(DOMAIN, TAG, 'system bar color applied (dark=%{public}s)', dark ? 'true' : 'false');
    }).catch((err: BusinessError) => {
      WindowBridge.lastSystemBarDark = null;
      hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', err.message);
    });
  }

  /**
   * Minimize the main window.
   */
  minimize(): void {
    const win = WindowBridge.mainWindow;
    if (!win) {
      return;
    }
    win.minimize().catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'minimize failed: %{public}s', err.message);
    });
  }

  /**
   * Toggle maximize / restore.
   */
  toggleMaximize(): void {
    const win = WindowBridge.mainWindow;
    if (!win) {
      return;
    }
    hilog.info(DOMAIN, TAG, 'toggleMaximize called, maximized=%{public}s', WindowBridge.maximized ? 'true' : 'false');
    if (WindowBridge.maximized) {
      win.recover().then(() => {
        hilog.info(DOMAIN, TAG, 'recover succeeded');
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'restore failed: %{public}s', err.message);
      });
    } else {
      win.maximize(window.MaximizePresentation.EXIT_IMMERSIVE).then(() => {
        hilog.info(DOMAIN, TAG, 'maximize succeeded');
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'maximize failed: %{public}s', err.message);
      });
    }
  }

  /**
   * Close the app through the same path used by the window close button.
   */
  close(): void {
    const handler = WindowBridge.closeHandler;
    if (handler) {
      handler();
    }
  }

  /**
   * Start a native window drag. The Web UI calls this from a mousedown on the
   * app toolbar (the custom title bar area).
   */
  startMove(): void {
    const win = WindowBridge.mainWindow;
    if (!win) {
      return;
    }
    win.startMoving().catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'startMoving failed: %{public}s', err.message);
    });
  }

  /**
   * Open an external URL in the system default browser. HarmonyOS HAP cannot
   * install/custom-install downloads from inside the WebView, so links that must
   * leave the app are handed to the OS browser.
   */
  openExternal(url: string): void {
    const context = WindowBridge.appContext;
    if (!context) {
      hilog.warn(DOMAIN, TAG, 'openExternal ignored: app context unavailable');
      return;
    }
    try {
      context.openLink(url).then(() => {
        hilog.info(DOMAIN, TAG, 'openExternal succeeded: %{public}s', url);
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'openExternal failed: %{public}s', JSON.stringify(err));
      });
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'openExternal threw: %{public}s', e.message);
    }
  }

  /**
   * Called from the Web page when the actual light/dark appearance changes.
   * This only updates the native window-button color. It intentionally does NOT
   * change the saved theme mode, so a 'system' theme stays 'system' even while
   * the buttons follow the current system appearance.
   */
  setDarkMode(dark: boolean): void {
    if (WindowBridge.lastDarkMode === dark) {
      return;
    }
    WindowBridge.applyDecorButtonStyle(dark);
  }

  /**
   * Called from the Web page to sync the actual UI theme mode into the native
   * layer. Unlike setDarkMode, this updates the saved mode and AppStorage so a
   * stale 'dark'/'light' preference is corrected when the UI is on 'system'.
   */
  setThemeModeFromWeb(mode: string): void {
    WindowBridge.setThemeMode(mode);
  }

  /**
   * Called from the Web page with the appearance it is actually rendering
   * ('light'/'dark'). This only keeps the native window buttons in sync; the
   * application color mode is resolved from the native system state instead.
   */
  setAppearanceFromWeb(appearance: string): void {
    const dark: boolean = appearance === 'dark';
    if (WindowBridge.lastDarkMode === dark) {
      return;
    }
    WindowBridge.applyDecorButtonStyle(dark);
  }

  /**
   * Bridge sync for the Web page's periodic tick.
   *
   * Re-reads the native system dark mode (so a system dark-mode toggle is picked
   * up even if the configuration callback is missed) and, when the app theme
   * follows the system, re-applies the resolved appearance. Returns the
   * effective appearance as 'dark'/'light' so the page can align its own state.
   */
  syncSystemAppearance(): string {
    WindowBridge.refreshSystemDark();
    WindowBridge.applyEffectiveAppearance();
    const appearance: DbxAppearance | null = WindowBridge.resolveAppearance();
    return appearance === null ? 'system' : appearance;
  }

  /**
   * Effective appearance ('light'/'dark') for the Web page to consume.
   */
  getEffectiveAppearance(): string {
    const appearance: DbxAppearance | null = WindowBridge.resolveAppearance();
    return appearance === null ? 'system' : appearance;
  }

  /**
   * Called by WebPrefsBridge whenever the Web UI persists a new theme mode.
   * Delegates to applyThemeForMode using the app context captured by init().
   */
  static setThemeMode(mode: string): void {
    WindowBridge.applyThemeForMode(mode);
  }

  /**
   * Record a theme mode and immediately apply the matching native chrome.
   *
   * Switching to 'system' re-reads the native dark-mode state right away, so the
   * app never inherits a stale explicit mode.
   *
   * `context` is only needed before init() has captured the app context (i.e.
   * the early onCreate() call), so the dock can be colored before the window
   * stage exists.
   */
  static applyThemeForMode(mode: string, context?: common.UIAbilityContext): void {
    const unchanged: boolean = WindowBridge.themeMode === mode;
    WindowBridge.themeMode = mode;
    AppStorage.setOrCreate('dbx_theme_mode', mode);
    if (unchanged) {
      return;
    }
    // Keep native Preferences in sync with the live Web theme mode so a cold
    // start can show the loading page in the correct app theme immediately.
    ThemePrefs.savePref('dbx-theme', mode);
    // 'system' (or unset) must consult the current native system state; explicit
    // themes resolve directly from the mode.
    if (mode !== 'dark' && mode !== 'light') {
      WindowBridge.refreshSystemDark();
    }
    WindowBridge.applyEffectiveAppearance(context);
  }

  /**
   * Read the true system dark-mode state from the native UI-appearance state.
   *
   * `fallbackMode` (a resourceManager/Configuration ColorMode: 0 dark, 1 light)
   * is only used when uiAppearance is unavailable, so the shell still works on
   * builds without that API.
   */
  static refreshSystemDark(fallbackMode?: number): boolean {
    let dark: boolean | null = null;
    try {
      dark = uiAppearance.getDarkMode() === uiAppearance.DarkMode.ALWAYS_DARK;
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'uiAppearance.getDarkMode failed: %{public}s', e.message);
    }
    if (dark === null && fallbackMode !== undefined) {
      if (fallbackMode === 0) {
        dark = true;
      } else if (fallbackMode === 1) {
        dark = false;
      }
    }
    if (dark === null) {
      return WindowBridge.systemDark;
    }
    const changed: boolean = !WindowBridge.systemDarkKnown || WindowBridge.systemDark !== dark;
    WindowBridge.systemDark = dark;
    WindowBridge.systemDarkKnown = true;
    // Publish only on change: the Web page calls this every second, and an
    // unconditional set would wake the AppStorage @Watch on every tick.
    if (changed) {
      AppStorage.setOrCreate('dbx_system_dark', dark);
      hilog.info(DOMAIN, TAG, 'system dark mode updated: %{public}s', dark ? 'true' : 'false');
    }
    return dark;
  }

  /**
   * Called by EntryAbility when the system configuration reports a color-mode
   * change: the user switched the system dark mode on or off. Re-read the native
   * state and, when the app theme follows the system, re-apply it.
   */
  static setSystemColorMode(mode: number): void {
    const dark: boolean = WindowBridge.refreshSystemDark(mode);
    if (WindowBridge.themeMode === 'dark' || WindowBridge.themeMode === 'light') {
      // An explicit app theme wins; the system change only refreshes the cached
      // system state so a later switch to 'system' resolves against it.
      return;
    }
    WindowBridge.applyEffectiveAppearance();
    hilog.info(DOMAIN, TAG, 'system color mode changed, applied dark=%{public}s', dark ? 'true' : 'false');
  }

  static getSystemDarkMode(): boolean | null {
    if (!WindowBridge.systemDarkKnown) {
      return null;
    }
    return WindowBridge.systemDark;
  }

  /**
   * Effective light/dark appearance the app should render.
   *
   * An explicit 'dark'/'light' app theme decides directly. Otherwise the app
   * follows the true system dark mode. Returns null only before the system state
   * is known.
   */
  static resolveAppearance(): DbxAppearance | null {
    if (WindowBridge.themeMode === 'dark') {
      return 'dark';
    }
    if (WindowBridge.themeMode === 'light') {
      return 'light';
    }
    if (!WindowBridge.systemDarkKnown) {
      return null;
    }
    return WindowBridge.systemDark ? 'dark' : 'light';
  }

  /**
   * Re-resolve and apply every piece of native chrome for the current mode.
   *
   * Called whenever the effective appearance may have changed: theme mode
   * switched, system dark mode toggled, window (re)created or maximized.
   */
  static applyEffectiveAppearance(context?: common.UIAbilityContext): void {
    const appearance: DbxAppearance | null = WindowBridge.resolveAppearance();
    if (appearance === null) {
      return;
    }
    const dark: boolean = appearance === 'dark';
    WindowBridge.applyColorMode(
      dark ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT,
      context);
    WindowBridge.applyDecorButtonStyle(dark);
    WindowBridge.applySystemBarColor();
  }

  /**
   * Apply an application color mode.
   *
   * The last-applied guard is updated BEFORE the native call: setColorMode() can
   * synchronously re-enter onConfigurationUpdate() before returning, and without
   * the guard that re-entrant path would recurse into setColorMode() forever
   * (RangeError: Stack overflow, which the runtime treats as a fatal JS error).
   * On failure the guard is reset so a later retry can still apply.
   */
  static applyColorMode(mode: number, context?: common.UIAbilityContext): void {
    const ctx: common.UIAbilityContext | null = context !== undefined ? context : WindowBridge.appContext;
    if (ctx === null) {
      return;
    }
    if (mode === WindowBridge.lastAppliedColorMode) {
      return;
    }
    WindowBridge.lastAppliedColorMode = mode;
    try {
      ctx.setColorMode(mode);
      ctx.getApplicationContext().setColorMode(mode);
      hilog.info(DOMAIN, TAG, 'app color mode applied, mode=%{public}d', mode);
    } catch (err) {
      WindowBridge.lastAppliedColorMode = -1;
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'setColorMode failed: %{public}s', e.message);
    }
  }

  private static applyDecorButtonStyle(dark: boolean): void {
    const win = WindowBridge.mainWindow;
    if (!win) {
      return;
    }
    if (WindowBridge.lastDarkMode === dark) {
      return;
    }
    try {
      const colorMode = dark
        ? ConfigurationConstant.ColorMode.COLOR_MODE_DARK
        : ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
      win.setDecorButtonStyle({ colorMode: colorMode });
      WindowBridge.lastDarkMode = dark;
      hilog.info(DOMAIN, TAG, 'decor button style applied, dark=%{public}s', dark ? 'true' : 'false');
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'setDecorButtonStyle failed: %{public}s', e.message);
    }
  }

  /**
   * Right-side toolbar padding (px) to keep native window buttons clear of the
   * web toolbar actions. The returned value is the measured title button strip
   * width plus a small gap matching the toolbar's button spacing.
   */
  getTitleButtonReserveWidth(): number {
    const win = WindowBridge.mainWindow;
    if (!win) {
      return WindowBridge.titleButtonReserveWidth;
    }
    try {
      const rect = win.getTitleButtonRect();
      if (rect) {
        // TitleButtonRect is relative to the upper-right corner: width is the
        // button strip width and right is any extra offset from the right edge.
        const gap = 4;
        const reserve = Math.ceil((rect.width > 0 ? rect.width : 0) + (rect.right > 0 ? rect.right : 0) + gap);
        if (reserve > 0) {
          WindowBridge.titleButtonReserveWidth = reserve;
        }
      }
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'getTitleButtonRect failed: %{public}s', e.message);
    }
    return WindowBridge.titleButtonReserveWidth;
  }

  /**
   * Lets the injected UI show the correct maximize/restore icon.
   */
  isMaximized(): boolean {
    return WindowBridge.maximized;
  }

  /**
   * Bottom navigation/three-button avoid area height in px, exposed to the
   * Web page via the `dbxNativeWindow` JS bridge. The injected script pads the
   * page bottom so content is not overlapped by the system navigation area.
   */
  getBottomNavHeight(): number {
    return WindowBridge.bottomNavHeight;
  }
}
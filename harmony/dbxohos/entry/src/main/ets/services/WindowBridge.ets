import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { ConfigurationConstant } from '@kit.AbilityKit';
import { ThemePrefs } from './ThemePrefs';

const DOMAIN = 0xDB8;
const TAG = 'DBX_WINDOW';

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
  private static maximized: boolean = false;
  private static statusListenerBound: boolean = false;
  private static avoidListenerBound: boolean = false;
  // Bottom navigation/side three-button avoid area height in px (0 when absent).
  private static bottomNavHeight: number = 0;
  // Right-side space to reserve in the web toolbar so native window buttons do
  // not overlap toolbar actions. Updated from getTitleButtonRect().
  private static titleButtonReserveWidth: number = 8;
  private static lastDarkMode: boolean | null = null;
  private static themeMode: string = '';
  // Numeric value from resourceManager.ColorMode / ConfigurationConstant.ColorMode:
  // -1 means unset, 0 dark, 1 light.
  private static systemColorMode: number = -1;

  /**
   * Called from EntryAbility once the main window is available.
   */
  static init(mainWindow: window.Window, closeHandler: () => void): void {
    WindowBridge.mainWindow = mainWindow;
    WindowBridge.closeHandler = closeHandler;
    WindowBridge.maximized = false;
    WindowBridge.lastDarkMode = null;
    WindowBridge.refreshBottomNavHeight(mainWindow);
    WindowBridge.registerAvoidListener(mainWindow);
    WindowBridge.setThemeMode(ThemePrefs.getPref('dbx-theme'));
    hilog.info(DOMAIN, TAG, 'WindowBridge initialized');

    if (!WindowBridge.statusListenerBound) {
      try {
        mainWindow.on('windowStatusChange', (status: window.WindowStatusType) => {
          WindowBridge.maximized = status === window.WindowStatusType.MAXIMIZE ||
            status === window.WindowStatusType.FULL_SCREEN;
          hilog.info(DOMAIN, TAG, 'window status changed: %{public}d, maximized=%{public}s', status,
            WindowBridge.maximized ? 'true' : 'false');
          if (WindowBridge.maximized) {
            WindowBridge.applySystemBarColor(mainWindow);
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
   * Color the window's status/navigation bar area to match the saved theme.
   * Called when the window enters maximized/full-screen so the system Dock area
   * can follow the app theme like other apps.
   */
  private static applySystemBarColor(win: window.Window): void {
    const dark: boolean = ThemePrefs.getPref('dbx-theme') === 'dark';
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
   * Called by WebPrefsBridge whenever the Web UI persists a new theme mode.
   * 'dark'/'light' explicitly set the native title-button style; 'system' lets
   * the OS keep control and resets the cached override.
   */
  static setThemeMode(mode: string): void {
    WindowBridge.themeMode = mode;
    AppStorage.setOrCreate('dbx_theme_mode', mode);
    // Keep native Preferences in sync with the live Web theme mode so a cold
    // start can show the loading page in the correct app theme immediately.
    ThemePrefs.savePref('dbx-theme', mode);
    let dark: boolean | null = null;
    if (mode === 'dark') {
      dark = true;
    } else if (mode === 'light') {
      dark = false;
    } else {
      dark = WindowBridge.getSystemDark();
      if (dark !== null) {
        AppStorage.setOrCreate('dbx_system_dark', dark);
      }
    }
    if (dark === null) {
      WindowBridge.lastDarkMode = null;
      return;
    }
    if (WindowBridge.lastDarkMode === dark) {
      return;
    }
    WindowBridge.applyDecorButtonStyle(dark);
  }

  /**
   * Called by EntryAbility when the system/app configuration reports a new
   * color mode. Used when the Web theme is set to 'system'.
   */
  static setSystemColorMode(mode: number): void {
    WindowBridge.systemColorMode = mode;
    if (WindowBridge.themeMode === 'system' && (mode === 0 || mode === 1)) {
      AppStorage.setOrCreate('dbx_system_dark', mode === 0);
    }
    if (WindowBridge.themeMode !== 'system') {
      return;
    }
    const dark: boolean | null = WindowBridge.getSystemDark();
    if (dark === null) {
      WindowBridge.lastDarkMode = null;
      return;
    }
    if (WindowBridge.lastDarkMode === dark) {
      return;
    }
    WindowBridge.applyDecorButtonStyle(dark);
  }

  static getSystemDarkMode(): boolean | null {
    return WindowBridge.getSystemDark();
  }

  private static getSystemDark(): boolean | null {
    if (WindowBridge.systemColorMode === 0) {
      return true;
    }
    if (WindowBridge.systemColorMode === 1) {
      return false;
    }
    return null;
  }

  private static applyDecorButtonStyle(dark: boolean): void {
    const win = WindowBridge.mainWindow;
    if (!win) {
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
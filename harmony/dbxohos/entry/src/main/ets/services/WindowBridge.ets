import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';
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

  /**
   * Called from EntryAbility once the main window is available.
   */
  static init(mainWindow: window.Window, closeHandler: () => void): void {
    WindowBridge.mainWindow = mainWindow;
    WindowBridge.closeHandler = closeHandler;
    WindowBridge.maximized = false;
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
   * Lets the injected UI show the correct maximize/restore icon.
   */
  isMaximized(): boolean {
    return WindowBridge.maximized;
  }
}
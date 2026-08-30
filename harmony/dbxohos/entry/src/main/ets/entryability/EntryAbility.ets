import { AbilityConstant, ConfigurationConstant, UIAbility, Want, common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppConstants } from '../common/Constants';
import { RawFileCopier } from '../services/RawFileCopier';
import { HttpServer } from '../services/HttpServer';
import { ServerHealthChecker } from '../services/ServerHealthChecker';
import { ThemePrefs } from '../services/ThemePrefs';
import { WindowBridge } from '../services/WindowBridge';
import { NativeBridge } from '../native/NativeBridge';

const DOMAIN = 0xDB3;
const TAG = 'DBX_ABILITY';

export default class EntryAbility extends UIAbility {
  private windowStage: window.WindowStage | null = null;
  private mainWindow: window.Window | null = null;
  private serviceActive: boolean = false;
  private serviceStarting: boolean = false;
  private reloadToken: number = 0;
  private closeListenerBound: boolean = false;
  private closing: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      const context = this.context as common.UIAbilityContext;
      ThemePrefs.init(context);
      const savedTheme: string = ThemePrefs.getPref('dbx-theme');
      // Make the app (and the system chrome/dock around the window) follow the
      // saved light/dark theme instead of leaving it unset (which can show a
      // white app bar even in dark mode).
      let mode: number = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      if (savedTheme === 'dark') {
        mode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      } else if (savedTheme === 'light') {
        mode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
      }
      // Set on the UIAbilityContext (and the application context) so the system
      // chrome/dock can follow the app theme like other apps do when foreground.
      context.setColorMode(mode);
      context.getApplicationContext().setColorMode(mode);
      hilog.info(DOMAIN, TAG, 'Ability onCreate, colorMode=%{public}d, savedTheme=%{public}s',
        mode, savedTheme.length > 0 ? savedTheme : '(unset)');
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  onDestroy(): void {
    if (!this.closing) {
      this.stopLocalService();
    }
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageCreate');
    this.windowStage = windowStage;
    this.registerWindowCloseListener();

    try {
      const mainWindow = windowStage.getMainWindowSync();
      this.mainWindow = mainWindow;
      WindowBridge.init(mainWindow, () => {
        this.handleWindowClose();
      });
      this.applyImmersiveWindow(mainWindow);
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'WindowBridge/immersive setup failed: %{public}s', e.message);
    }

    this.startLocalService(true).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'startLocalService before loadContent failed: %{public}s', JSON.stringify(err));
      this.loadMainPage();
    });
  }

  onWindowStageDestroy(): void {
    this.unregisterWindowCloseListener();
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onWindowStageDestroy');
    if (!this.closing) {
      // Some devices/versions deliver window destruction without the
      // windowStageClose event. Treat an unexpected window-stage destroy as
      // an explicit close so the DBX process does not stay alive.
      this.handleWindowClose();
    }
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onForeground');
    if (this.windowStage && !this.serviceActive) {
      this.startLocalService(false).catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'resume service failed: %{public}s', JSON.stringify(err));
        this.reloadMainPage();
      });
    }
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, '%{public}s', 'Ability onBackground');
    if (this.closing) {
      return;
    }
    // Keep the local service and Web page alive in the background so returning
    // to the app does not silently discard open tabs / unsaved SQL / query
    // results. If the system later reaps the process, onWindowStageCreate will
    // start a fresh cold-boot path.
  }

  private async startLocalService(loadPage: boolean): Promise<void> {
    // onWindowStageCreate and onForeground can race during cold start.
    // Keep a single in-flight startup so the native server and loadContent
    // are not started twice (duplicate Web instances also break IndexedDB /
    // localStorage persistence, e.g. the light/dark theme choice).
    if (this.serviceActive || this.serviceStarting) {
      return;
    }
    this.serviceStarting = true;
    try {
      const context = this.context as common.UIAbilityContext;
      ThemePrefs.init(context);
      const filesDir: string = context.filesDir;
      const distDir: string = `${filesDir}/${AppConstants.DIST_DIR_NAME}`;
      const dataDir: string = `${filesDir}/dbx-data`;
      await RawFileCopier.copyRawDir(context, AppConstants.RAW_DIST_PATH, distDir);
      if (this.closing) {
        return;
      }

      let nativeStarted: boolean = false;
      if (NativeBridge.isAvailable()) {
        try {
          NativeBridge.startServer({
            port: AppConstants.WEB_PORT,
            staticDir: distDir,
            dataDir: dataDir,
            disablePassword: true
          });
          nativeStarted = true;
          hilog.info(DOMAIN, TAG, 'Native dbx-web server started on port %{public}d', AppConstants.WEB_PORT);
        } catch (err) {
          const e = err as BusinessError;
          hilog.warn(DOMAIN, TAG, 'Native server start failed, falling back to ArkTS: %{public}s', JSON.stringify(e));
        }
      }

      if (!nativeStarted) {
        // Fallback mode: ArkTS server provides both web UI and MCP stub.
        await HttpServer.getInstance().start(AppConstants.WEB_PORT, distDir);
        await HttpServer.getInstance().start(AppConstants.MCP_PORT, distDir);
      } else {
        hilog.info(DOMAIN, TAG, 'Native MCP available at http://127.0.0.1:%{public}d/mcp', AppConstants.WEB_PORT);
      }

      // Wait until the server is really listening before loading the Web page.
      const ready: boolean = await ServerHealthChecker.waitUntilReady(AppConstants.WEB_PORT, 10000);
      if (!ready) {
        hilog.warn(DOMAIN, TAG, 'Server health check timed out; Web may need manual retry.');
      }
      if (this.closing) {
        return;
      }

      this.serviceActive = true;
      if (loadPage) {
        this.loadMainPage();
      } else {
        // Resume: the page/Web component already exists, so only ask it to
        // reload instead of calling loadContent again (which would create a
        // second Web instance and can break localStorage persistence).
        this.reloadMainPage();
      }
    } finally {
      this.serviceStarting = false;
    }
  }

  private applyImmersiveWindow(mainWindow: window.Window): void {
    try {
      // Use the system title bar and native window controls. Repeated attempts
      // to fuse ArkUI/web buttons into the toolbar caused extra buttons and
      // theme-sync issues; native system buttons are the stable path.
      mainWindow.setWindowDecorVisible(true);
      mainWindow.setWindowTitleButtonVisible(true, true, true);
      mainWindow.setWindowLayoutFullScreen(false);
      // Try to make the window's system bar/dock area follow the app theme.
      // Note: the OS taskbar/dock (outside the app window) may still follow the
      // global system theme and be beyond per-app control.
      const savedTheme = ThemePrefs.getPref('dbx-theme');
      const darkChrome = savedTheme === 'dark';
      const chromeColor = darkChrome ? '#1c1c1e' : '#ffffff';
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: chromeColor,
        navigationBarColor: chromeColor
      }).then(() => {
        hilog.info(DOMAIN, TAG, 'system bar colors applied (dark=%{public}s)', darkChrome ? 'true' : 'false');
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', err.message);
      });
      hilog.info(DOMAIN, TAG, '%{public}s', 'Native window title bar mode applied');
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'applyImmersiveWindow partial failure: %{public}s', e.message);
    }
  }

  private stopLocalService(): void {
    HttpServer.getInstance().stop();
    NativeBridge.stopServer();
    NativeBridge.stopMcpServer();
    this.serviceActive = false;
    hilog.info(DOMAIN, TAG, '%{public}s', 'Local service stopped');
  }

  private registerWindowCloseListener(): void {
    const stage = this.windowStage;
    if (!stage || this.closeListenerBound) {
      return;
    }
    try {
      stage.on('windowStageClose', () => {
        this.handleWindowClose();
      });
      this.closeListenerBound = true;
      hilog.info(DOMAIN, TAG, '%{public}s', 'Window close listener registered');
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'Register windowStageClose listener failed: %{public}s', JSON.stringify(e));
    }
  }

  private unregisterWindowCloseListener(): void {
    if (this.closeListenerBound && this.windowStage) {
      try {
        this.windowStage.off('windowStageClose');
      } catch (err) {
        const e = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'Unregister windowStageClose listener failed: %{public}s', JSON.stringify(e));
      }
      this.closeListenerBound = false;
    }
    this.windowStage = null;
  }

  private handleWindowClose(): void {
    if (this.closing) {
      return;
    }
    this.closing = true;
    hilog.info(DOMAIN, TAG, '%{public}s', 'Window close requested; scheduling process exit');

    // Do NOT stop the local server synchronously here. NativeBridge.stopServer()
    // cancels the Tokio/Axum graceful shutdown and then joins the server thread;
    // active WebSocket/SSE connections can keep that join blocked and freeze the
    // UI thread. The process is about to be killed anyway, so force-exit directly.
    setTimeout(() => {
      this.forceExit();
    }, 50);
  }

  private forceExit(): void {
    try {
      const appContext = this.context.getApplicationContext();
      appContext.killAllProcesses(true).then(() => {
        hilog.info(DOMAIN, TAG, '%{public}s', 'killAllProcesses called');
      }).catch((err: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'killAllProcesses failed: %{public}s', JSON.stringify(err));
        const context = this.context as common.UIAbilityContext;
        context.terminateSelf().catch((e: BusinessError) => {
          hilog.error(DOMAIN, TAG, 'terminateSelf fallback failed: %{public}s', JSON.stringify(e));
        });
      });
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'killAllProcesses threw: %{public}s', JSON.stringify(e));
      const context = this.context as common.UIAbilityContext;
      context.terminateSelf().catch((e2: BusinessError) => {
        hilog.error(DOMAIN, TAG, 'terminateSelf fallback failed: %{public}s', JSON.stringify(e2));
      });
    }
  }

  private reloadMainPage(): void {
    this.reloadToken += 1;
    AppStorage.setOrCreate('dbx_reload_token', this.reloadToken);
    hilog.info(DOMAIN, TAG, 'Requesting Web reload, token=%{public}d', this.reloadToken);
  }

  private loadMainPage(): void {
    const stage = this.windowStage;
    if (!stage) {
      return;
    }
    stage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading the content.');
      // Re-apply immersive settings once content is actually loaded; some devices
      // only honor decor visibility changes after the window has content.
      if (this.mainWindow) {
        this.applyImmersiveWindow(this.mainWindow);
      }
    });
  }
}

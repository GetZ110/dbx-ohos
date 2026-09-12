// `libdbx_ohos.so` is a ~46MB shared library. A plain import would dlopen it
// while the ability's module graph is evaluated, i.e. before `onCreate` runs and
// before the launch window exists; `import lazy` defers that to the first actual
// call (`isAvailable()`/`startServer()` during `onWindowStageCreate`), so the
// window can be brought up without paying for the mapping and relocations.
import lazy dbxNative from 'libdbx_ohos.so';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@kit.BasicServicesKit';

const DOMAIN = 0xDB5;
const TAG = 'DBX_NATIVE';

interface NativeServerOptions {
  port: number;
  staticDir: string;
  dataDir: string;
  disablePassword: boolean;
}

/**
 * Bridge to the Rust dbx-ohos NAPI module.
 *
 * The native module is expected at entry/libs/arm64-v8a/libdbx_ohos.so and
 * exports startServer/stopServer/startMcpServer/stopMcpServer.
 */
export class NativeBridge {
  static isAvailable(): boolean {
    try {
      // Any reference to the lazily imported binding triggers the dlopen here,
      // so a broken/missing .so must be reported as "unavailable" instead of
      // escaping and aborting the whole startup path.
      return typeof dbxNative !== 'undefined' && typeof dbxNative.startServer === 'function';
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'native module unavailable: %{public}s', JSON.stringify(err));
      return false;
    }
  }

  static startServer(options: NativeServerOptions): number {
    const port: number = dbxNative.startServer(options);
    hilog.info(DOMAIN, TAG, 'native server started on port %{public}d', port);
    return port;
  }

  static stopServer(): void {
    try {
      dbxNative.stopServer();
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'stopServer failed: %{public}s', JSON.stringify(e));
    }
  }

  static startMcpServer(port: number): number {
    const p: number = dbxNative.startMcpServer(port);
    hilog.info(DOMAIN, TAG, 'native MCP server started on port %{public}d', p);
    return p;
  }

  static stopMcpServer(): void {
    try {
      dbxNative.stopMcpServer();
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'stopMcpServer failed: %{public}s', JSON.stringify(e));
    }
  }
}

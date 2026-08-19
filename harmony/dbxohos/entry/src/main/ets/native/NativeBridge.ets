import dbxNative from 'libdbx_ohos.so';
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
    return typeof dbxNative !== 'undefined' && typeof dbxNative.startServer === 'function';
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

import http from '@ohos.net.http';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0xDB6;
const TAG = 'DBX_HEALTH';

/**
 * Polls the local dbx-web /api/health endpoint until the server is ready.
 */
export class ServerHealthChecker {
  static async waitUntilReady(port: number, timeoutMs: number = 10000): Promise<boolean> {
    const url: string = `http://127.0.0.1:${port}/api/health`;
    const deadline: number = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const ok: boolean = await ServerHealthChecker.check(url);
      if (ok) {
        hilog.info(DOMAIN, TAG, 'server ready: %{public}s', url);
        return true;
      }
      await ServerHealthChecker.sleep(300);
    }
    hilog.warn(DOMAIN, TAG, 'server not ready within %{public}d ms', timeoutMs);
    return false;
  }

  private static check(url: string): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      const request = http.createHttp();
      request.request(
        url,
        {
          method: http.RequestMethod.GET,
          connectTimeout: 1000,
          readTimeout: 1000
        },
        (err: BusinessError, data: http.HttpResponse) => {
          request.destroy();
          if (!err && data.responseCode === 200) {
            resolve(true);
          } else {
            resolve(false);
          }
        }
      );
    });
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }
}

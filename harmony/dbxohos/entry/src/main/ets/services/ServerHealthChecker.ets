import http from '@ohos.net.http';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0xDB6;
const TAG = 'DBX_HEALTH';

/**
 * Polls the local dbx-web /api/health endpoint until the server is ready.
 */
export class ServerHealthChecker {
  /**
   * The native server is usually listening within a few milliseconds of
   * `startServer()` returning, so polling at a fixed 300ms cadence added up to
   * 300ms of pure waiting to every cold start. Retry quickly at first and only
   * back off for a server that is genuinely slow to come up.
   */
  private static readonly RETRY_DELAYS_MS: Array<number> = [10, 15, 20, 30, 50, 80, 120, 200, 300];

  static async waitUntilReady(port: number, timeoutMs: number = 10000): Promise<boolean> {
    const url: string = `http://127.0.0.1:${port}/api/health`;
    const deadline: number = Date.now() + timeoutMs;
    let attempt: number = 0;
    while (Date.now() < deadline) {
      const ok: boolean = await ServerHealthChecker.check(url);
      if (ok) {
        hilog.info(DOMAIN, TAG, 'server ready: %{public}s (attempt %{public}d)', url, attempt + 1);
        return true;
      }
      const delays: Array<number> = ServerHealthChecker.RETRY_DELAYS_MS;
      const delay: number = delays[attempt < delays.length ? attempt : delays.length - 1];
      attempt++;
      await ServerHealthChecker.sleep(delay);
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

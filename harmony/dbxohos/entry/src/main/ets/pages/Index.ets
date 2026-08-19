import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppConstants } from '../common/Constants';
import { WebPrefsBridge } from '../services/WebPrefsBridge';

const DOMAIN = 0xDB2;
const TAG = 'DBX_PAGE';

interface WebErrorInfo {
  getErrorCode(): number;
  getErrorInfo(): string;
}

interface WebResourceRequestLike {
  isMainFrame(): boolean;
  getRequestUrl(): string;
}

interface WebErrorReceiveEvent {
  request: WebResourceRequestLike;
  error: WebErrorInfo;
}

@Entry
@Component
struct Index {
  @State webSrc: string = AppConstants.SERVER_URL;
  @State loading: boolean = true;
  @State errorText: string = '';
  @StorageProp('dbx_reload_token') @Watch('onReloadTokenChanged') reloadToken: number = 0;
  private controller: webview.WebviewController = new webview.WebviewController();
  private prefsBridge: WebPrefsBridge = new WebPrefsBridge();
  private prefsRestoreScript: string =
    '(function(){' +
    'try{' +
    'var b=window.dbxNativePrefs;' +
    'if(!b)return;' +
    'var keys=["dbx-theme","dbx-theme-palette","dbx-corner-style"];' +
    'for(var i=0;i<keys.length;i++){' +
    'var k=keys[i];' +
    'var v=b.getPref(k);' +
    'if(v)localStorage.setItem(k,v);' +
    '}' +
    'var orig=Storage.prototype.setItem;' +
    'Storage.prototype.setItem=function(k,v){' +
    'try{orig.call(this,k,v);}catch(e){}' +
    'try{if(k&&k.indexOf("dbx-")===0&&b.savePref)b.savePref(String(k),String(v));}catch(e){}' +
    '};' +
    '}catch(e){}' +
    '})();';

  aboutToAppear(): void {
    hilog.info(DOMAIN, TAG, 'Index about to appear, webSrc=%{public}s', this.webSrc);
  }

  onReloadTokenChanged(): void {
    if (this.reloadToken > 0) {
      hilog.info(DOMAIN, TAG, 'Reloading Web after service resume, token=%{public}d', this.reloadToken);
      this.controller.loadUrl(AppConstants.SERVER_URL);
    }
  }

  build() {
    Stack() {
      // Full-screen Web component: adapts to PC and tablet automatically.
      Web({ src: this.webSrc, controller: this.controller })
        .width('100%')
        .height('100%')
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .databaseAccess(true)
        .javaScriptProxy({
          object: this.prefsBridge,
          name: 'dbxNativePrefs',
          methodList: ['getPref', 'savePref'],
          controller: this.controller
        })
        .javaScriptOnDocumentStart([{
          script: this.prefsRestoreScript,
          scriptRules: ['*']
        }])
        .onlineImageAccess(true)
        .fileAccess(true)
        .zoomAccess(false)
        .onPageBegin(() => {
          this.loading = true;
          this.errorText = '';
        })
        .onPageEnd(() => {
          this.loading = false;
          this.errorText = '';
        })
        .onErrorReceive((event: WebErrorReceiveEvent) => {
          if (!event.request.isMainFrame()) {
            // Sub-resource failures (dialogs, driver manager, WebSocket, etc.)
            // should not trigger the full-screen error overlay.
            hilog.warn(DOMAIN, TAG, 'Sub-resource load error ignored: %{public}s', event.request.getRequestUrl());
            return;
          }
          this.loading = false;
          this.errorText = `加载失败 (${event.error.getErrorCode()}) ${event.error.getErrorInfo()}`;
          hilog.error(DOMAIN, TAG, 'Main frame load error: %{public}s', JSON.stringify(event));
        })
        .onConsole((event) => {
          hilog.info(DOMAIN, TAG, 'console: %{public}s', event.message);
          return false;
        });

      // Loading indicator overlay
      if (this.loading) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color('#0A59F7')
          Text('正在启动 DBX 本地服务…')
            .fontSize(14)
            .fontColor('#666666')
            .margin({ top: 12 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#F5F6F8')
      }

      // Error overlay with retry
      if (!this.loading && this.errorText.length > 0) {
        Column() {
          Text(this.errorText)
            .fontSize(18)
            .fontColor('#333333')
          Button('重新加载')
            .margin({ top: 16 })
            .onClick(() => {
              this.errorText = '';
              this.loading = true;
              this.controller.loadUrl(AppConstants.SERVER_URL);
            })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor('#F5F6F8')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F6F8')
  }
}

import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppConstants } from '../common/Constants';
import { WebPrefsBridge } from '../services/WebPrefsBridge';
import { ThemePrefs } from '../services/ThemePrefs';
import { WindowBridge } from '../services/WindowBridge';

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
  @State darkLoading: boolean = false;
  @StorageProp('dbx_reload_token') @Watch('onReloadTokenChanged') reloadToken: number = 0;
  private controller: webview.WebviewController = new webview.WebviewController();
  private prefsBridge: WebPrefsBridge = new WebPrefsBridge();
  private windowBridge: WindowBridge = new WindowBridge();
private windowInjectionScript: string =
    '(function(){' +
    'function addStyle(){' +
    'if(!document.getElementById("dbx-win-style")&&document.head){' +
    'var s=document.createElement("style");s.id="dbx-win-style";' +
    's.textContent=' +
    '".dbx-window-controls{display:inline-flex;align-items:center;height:100%;margin-left:2px;user-select:none;-webkit-user-select:none;flex-shrink:0;}"+' +
    '".dbx-window-controls button{width:32px;height:32px;display:inline-flex;align-items:center;justify-content:center;border:none;background:transparent;color:currentColor;border-radius:6px;cursor:default;font-size:14px;line-height:1;padding:0;margin:0 1px;}"+' +
    '".dbx-window-controls button:hover{background:rgba(128,128,128,0.15);}"+' +
    '".dbx-window-controls button:active{background:rgba(128,128,128,0.25);}"+' +
    '".dbx-window-controls .dbx-win-close:hover{background:rgba(224,49,49,0.1);color:#e5484d;}";' +
    'document.head.appendChild(s);' +
    '}' +
    '}' +
    'function inject(){' +
    'try{' +
    'addStyle();' +
    'var bar=document.querySelector(".app-toolbar");' +
    'if(!bar||document.getElementById("dbx-window-controls"))return;' +
    'var wrap=document.createElement("div");' +
    'wrap.id="dbx-window-controls";' +
    'wrap.className="dbx-window-controls";' +
    'var dbxWin=window.dbxNativeWindow||{};' +
    'function svgIcon(inner){return \'<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">\'+inner+\'</svg>\';}' +
    'var maxIcon=svgIcon(\'<rect x="3" y="3" width="18" height="18" rx="1"/>\');' +
    'var restoreIcon=svgIcon(\'<rect width="14" height="14" x="8" y="8" rx="1" ry="1"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>\');' +
    'var minIcon=svgIcon(\'<line x1="5" y1="12" x2="19" y2="12"/>\');' +
    'var closeIcon=svgIcon(\'<path d="M18 6 6 18"/><path d="m6 6 12 12"/>\');' +
    'var lastMaxToggle=0;' +
    'var dragStartX=0,dragStartY=0,dragMoved=false;' +
    'var showMaxIcon=(dbxWin.isMaximized&&dbxWin.isMaximized())?restoreIcon:maxIcon;' +
    'wrap.innerHTML=\'<button data-win="max" title="最大化/还原">\'+showMaxIcon+\'</button>\'+\'<button data-win="min" title="最小化">\'+minIcon+\'</button>\'+\'<button data-win="close" class="dbx-win-close" title="关闭">\'+closeIcon+\'</button>\';' +
    'bar.appendChild(wrap);' +
    'if(console&&console.log)console.log("[DBX] custom window controls injected");' +
    'wrap.addEventListener("click",function(e){' +
    'var t=e.target.closest("button");if(!t)return;' +
    'var act=t.getAttribute("data-win");var w=window.dbxNativeWindow;if(!w)return;' +
    'if(act==="min")w.minimize();else if(act==="max"){var now=Date.now();if(now-lastMaxToggle<300)return;lastMaxToggle=now;w.toggleMaximize();var mb=wrap.querySelector("button[data-win=\\"max\\"]");if(mb)mb.innerHTML=(w.isMaximized&&w.isMaximized())?restoreIcon:maxIcon;}else if(act==="close")w.close();' +
    '});' +
    'bar.addEventListener("mousedown",function(e){' +
    'if(e.button!==0)return;var t=e.target;' +
    'if(t.closest&&t.closest(".dbx-window-controls,button,a,input,select,textarea,[contenteditable=\\"true\\"],[role=\\"button\\"]"))return;' +
    'dragStartX=e.clientX;dragStartY=e.clientY;dragMoved=false;' +
    '});' +
    'bar.addEventListener("mousemove",function(e){' +
    'if(dragStartX===0&&dragStartY===0)return;' +
    'var dx=e.clientX-dragStartX,dy=e.clientY-dragStartY;' +
    'if(!dragMoved&&Math.abs(dx)+Math.abs(dy)>=4){dragMoved=true;var w=window.dbxNativeWindow;if(w&&w.startMove)w.startMove();}' +
    '});' +
    'document.addEventListener("mouseup",function(){dragStartX=0;dragStartY=0;dragMoved=false;});' +
    '}catch(e){}' +
    '}' +
    'if(document.readyState==="loading")document.addEventListener("DOMContentLoaded",inject);else inject();' +
    'if(window.MutationObserver){var mo=new MutationObserver(inject);mo.observe(document.documentElement,{childList:true,subtree:true});}' +
    '})();'
  // Injects bottom safe-area padding so interactive web content is not covered
  // by the system navigation/three-button area. Reads the avoid height from the
  // native bridge and re-applies it periodically (avoidAreaChange has no JS
  // callback, so a lightweight poll keeps the padding in sync).
  private windowSafeAreaScript: string =
    '(function(){' +
    'function ensureStyle(){' +
    'if(document.getElementById("dbx-safe-style")||!document.head)return;' +
    'var s=document.createElement("style");s.id="dbx-safe-style";' +
    's.textContent="html,body{--dbx-safe-bottom:0px;}";' +
    'document.head.appendChild(s);' +
    '}' +
    'function apply(){' +
    'try{' +
    'ensureStyle();' +
    'var w=window.dbxNativeWindow;' +
    'var h=(w&&w.getBottomNavHeight)?(w.getBottomNavHeight()||0):0;' +
    'var px=Math.ceil(h)+"px";' +
    'var root=document.documentElement;' +
    'if(root){root.style.setProperty("--dbx-safe-bottom",px);}' +
    'if(document.body){document.body.style.paddingBottom=px;}' +
    '}catch(e){}' +
    '}' +
    'if(document.readyState==="loading"){document.addEventListener("DOMContentLoaded",apply);}else{apply();}' +
    'apply();' +
    'setInterval(apply,500);' +
    '})();'
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
    const savedTheme: string = ThemePrefs.getPref('dbx-theme');
    this.darkLoading = savedTheme === 'dark';
    hilog.info(DOMAIN, TAG, 'Index about to appear, webSrc=%{public}s, savedTheme=%{public}s',
      this.webSrc, savedTheme.length > 0 ? savedTheme : '(unset)');
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
        .javaScriptProxy({
          object: this.windowBridge,
          name: 'dbxNativeWindow',
          methodList: ['minimize', 'toggleMaximize', 'close', 'startMove', 'isMaximized', 'getBottomNavHeight'],
          controller: this.controller
        })
        .javaScriptOnDocumentStart([{
          script: this.prefsRestoreScript,
          scriptRules: ['*']
        }, {
          script: this.windowInjectionScript,
          scriptRules: ['*']
        }, {
          script: this.windowSafeAreaScript,
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
            .color(this.darkLoading ? '#3B82F6' : '#0A59F7')
          Text('正在启动 DBX 本地服务…')
            .fontSize(14)
            .fontColor(this.darkLoading ? '#c8c8cc' : '#666666')
            .margin({ top: 12 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.darkLoading ? '#131416' : '#F5F6F8')
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

/**
 * Injected "authorized folders" manager for HarmonyOS.
 *
 * Adds one toolbar button (between 驱动管理 and 更多, sampling the neighbouring
 * button's class so it is pixel-identical to the app's own actions) that opens a
 * panel listing:
 *
 *   - `<Documents>/DBX`, the app's own drop folder, with its **live** state:
 *     it depends on the user_grant permission
 *     `READ_WRITE_DOCUMENTS_DIRECTORY`, which the user can deny or revoke in
 *     system settings at any time, so the panel re-reads `documentsStatus()`
 *     (`'<permission>|<writable>'`) on every refresh and offers a "go grant"
 *     button when it is missing;
 *   - every folder the user authorized through the system folder picker, each
 *     with a two-step "撤销" button.
 *
 * It deliberately does *not* list the database files inside those folders: the
 * platform cannot enumerate persisted grants anyway (fileShare only answers
 * questions about a URI the app already holds), and a per-folder file list
 * turned out to be noise. `fs.listFileSync()` on a granted folder does work, so
 * it can come back cheaply if it is ever wanted.
 *
 * Same constraints as FilePickerWebScript: this is an ArkTS template literal, so
 * a JS `'\n'` would be unescaped by the compiler before reaching the page. The
 * script therefore uses `String.fromCharCode(10)` and avoids backslashes
 * entirely instead of relying on `\\n`.
 *
 * Diagnostics are logged as `[DBX-FOLDERMGR] ...` and forwarded to hilog by
 * `onConsole`.
 */
export const FOLDER_MANAGER_INJECTION_SCRIPT: string =
  `(function(){
  if(window.__dbxFolderManager)return;
  window.__dbxFolderManager=true;
  var NL=String.fromCharCode(10);
  var TIMES=String.fromCharCode(215);
  function log(m){try{console.log('[DBX-FOLDERMGR] '+m);}catch(e){}}

  var EN={
    button:'Authorize folders',title:'Authorized folders',
    empty:'No folder is authorized yet. Pick "Authorize folder..." below and choose a folder once - every database file inside becomes usable.',
    revoke:'Revoke',confirm:'Confirm revoke',revoked:'Authorization revoked: ',
    added:'Folder authorized: ',pending:'Waiting for the folder picker...',
    cancelled:'Folder picker closed without authorizing anything',
    fail:'Operation failed',close:'Close',add:'Authorize folder...',
    tip:'Revoking only removes the authorization of this app; the files themselves are untouched.',
    permGranted:'Documents directory permission granted',
    permDenied:'Documents directory permission NOT granted',
    permUnknown:'Documents directory permission state unknown',
    writable:'read/write',notWritable:'not writable',
    permTip:'Documents/DBX is governed by the system Documents-directory permission; revoke or restore it in system settings.',
    grantNow:'Grant...',granting:'Asking for the Documents permission...',
    grantDenied:'The Documents directory permission was not granted, so Documents/DBX cannot be used.',
    grantGranted:'Documents directory permission: '};

  // Locale is taken from the app's own toolbar wording (ground truth for what
  // the user sees), then from the system language as a fallback.
  var LOCALES=[
    {match:['新建连接'],button:'授权目录管理',title:'授权目录管理',
     empty:'还没有授权任何目录。点下面的「新增授权目录」选一个文件夹（只需一次），之后里面的数据库文件就能直接使用。',
     revoke:'撤销',confirm:'确认撤销',revoked:'已撤销授权：',
     added:'已授权：',pending:'正在等待文件夹选择器…',cancelled:'文件夹选择器已关闭，未授权任何目录',
     fail:'操作失败',close:'关闭',add:'新增授权目录…',
     tip:'撤销只是收回本应用的访问授权，文件本身不会被改动。',
     permGranted:'已授予系统「文档」目录权限',
     permDenied:'未授予系统「文档」目录权限',
     permUnknown:'系统「文档」目录权限状态未知',
     writable:'可读写',notWritable:'不可写',
     permTip:'「文档 / DBX」由系统「文档」目录权限控制，此处显示实时状态；要撤销请到系统设置里改。',
     grantNow:'去授权…',granting:'正在请求「文档」目录权限…',
     grantDenied:'未获得系统「文档」目录权限，「文档 / DBX」暂时不可用。',
     grantGranted:'当前「文档」目录权限：'},
    {match:['新增連接','新建連接','新增連線'],button:'授權目錄管理',title:'授權目錄管理',
     empty:'還沒有授權任何目錄。點下面的「新增授權目錄」選一個資料夾（只需一次），之後裡面的資料庫檔案就能直接使用。',
     revoke:'撤銷',confirm:'確認撤銷',revoked:'已撤銷授權：',
     added:'已授權：',pending:'正在等待資料夾選擇器…',cancelled:'資料夾選擇器已關閉，未授權任何目錄',
     fail:'操作失敗',close:'關閉',add:'新增授權目錄…',
     tip:'撤銷只是收回本應用程式的存取授權，檔案本身不會被更動。'},
    {match:['New Connection','New connection'],button:EN.button,title:EN.title,empty:EN.empty,files:EN.files,none:EN.none,revoke:EN.revoke,confirm:EN.confirm,revoked:EN.revoked,added:EN.added,
     pending:EN.pending,cancelled:EN.cancelled,fail:EN.fail,close:EN.close,add:EN.add,tip:EN.tip,
     permGranted:EN.permGranted,permDenied:EN.permDenied,permUnknown:EN.permUnknown,
     writable:EN.writable,notWritable:EN.notWritable,permTip:EN.permTip,grantNow:EN.grantNow,
     granting:EN.granting,grantDenied:EN.grantDenied,grantGranted:EN.grantGranted}
  ];

  function pick(list,key,fallback){return list[key]?list[key]:fallback;}

  function detect(){
    var text='';
    try{var tb=document.querySelector('.app-toolbar');text=tb?(tb.textContent||''):'';}catch(e){}
    var i,j;
    for(i=0;i<LOCALES.length;i++){
      for(j=0;j<LOCALES[i].match.length;j++){
        if(text.indexOf(LOCALES[i].match[j])>=0){
          var hit=LOCALES[i],base=EN,txt={};
          for(var k in base){txt[k]=pick(hit,k,base[k]);}
          return txt;
        }
      }
    }
    var lang='';
    try{lang=(navigator.language||'').toLowerCase();}catch(e){}
    var idx=2;
    if(lang.indexOf('zh')===0){idx=(lang.indexOf('tw')>=0||lang.indexOf('hk')>=0)?1:0;}
    var chosen=LOCALES[idx],fallbackBase=EN,out={};
    for(var k2 in fallbackBase){out[k2]=pick(chosen,k2,fallbackBase[k2]);}
    return out;
  }

  var S=detect();
  // The toolbar is zoomed by the UI-scale injection; keep a CSS variable with the
  // current factor so the full-screen overlay can counteract it (100vw/z), the
  // same compensation the app's own shell uses.
  function setZoom(z){
    var n=parseFloat(z);
    if(!isFinite(n)||n<=0)n=1;
    try{document.documentElement.style.setProperty('--dbx-fm-zoom',String(n));}catch(e){}
  }
  try{
    window.addEventListener('dbx:ui-scale-applied',function(ev){
      setZoom(ev&&ev.detail?ev.detail.scale:1);
    });
  }catch(e){}

  var BTN='border:1px solid var(--border);background:var(--background);color:var(--foreground);'+
    'border-radius:6px;height:28px;padding:0 10px;font-size:12.5px;cursor:pointer;';
  var DANGER=BTN+'color:var(--destructive);';
  var MUTED='color:var(--muted-foreground);font-size:12px;';
  var ICON='<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" '+
    'stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">'+
    '<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>'+
    '<path d="M9 13h6"/><path d="M12 10v6"/></svg>';

  function el(tag,style,text){
    var node=document.createElement(tag);
    if(style)node.style.cssText=style;
    if(text!=null)node.textContent=text;
    return node;
  }

  var overlay=null,body=null,msgBox=null,busy=false,msgTimer=null;

  function say(text,kind){
    if(!msgBox)return;
    if(msgTimer){clearTimeout(msgTimer);msgTimer=null;}
    if(!text){msgBox.style.display='none';msgBox.textContent='';return;}
    msgBox.textContent=text;
    msgBox.style.display='';
    msgBox.style.color=kind==='error'?'var(--destructive)':'var(--muted-foreground)';
    if(kind==='ok'||kind==='error'){
      msgTimer=setTimeout(function(){if(msgBox){msgBox.style.display='none';msgBox.textContent='';}},6000);
    }
  }

  function close(){
    if(overlay&&overlay.parentNode)overlay.parentNode.removeChild(overlay);
    overlay=null;body=null;msgBox=null;
  }

  function refreshPickerHint(){
    try{
      if(window.__dbxFilePickerRefreshHint)window.__dbxFilePickerRefreshHint();
    }catch(e){}
  }

  // One folder-picker / permission round trip. The result comes back through the
  // shared delivery global owned by the file-picker script; wrap it for the
  // duration of the call (restoring on reply) so the manager works regardless of
  // which injection ran first.
  var seq=0;
  function callNative(method,arg){
    return new Promise(function(resolve){
      var host=window.dbxNativeWindow;
      if(!host||!host[method]){resolve({status:'unavailable'});return;}
      var id='fm'+(++seq);
      var prev=window.__dbxFilePickerDeliver;
      var settled=false;
      var timer=setTimeout(function(){
        if(settled)return;
        settled=true;
        if(window.__dbxFilePickerDeliver===wrapped)window.__dbxFilePickerDeliver=prev;
        resolve({status:'timeout'});
      },180000);
      var wrapped=function(rid,status,path,message){
        if(rid===id){
          settled=true;clearTimeout(timer);
          window.__dbxFilePickerDeliver=prev;
          resolve({status:String(status||''),path:String(path||''),message:String(message||'')});
          return;
        }
        if(typeof prev==='function')prev(rid,status,path,message);
      };
      window.__dbxFilePickerDeliver=wrapped;
      try{
        if(arg===undefined)host[method](id);
        else host[method](id,arg);
      }catch(e){
        settled=true;clearTimeout(timer);
        window.__dbxFilePickerDeliver=prev;
        resolve({status:'error',message:String(e)});
      }
    });
  }

  function onAdd(){
    if(busy)return;
    busy=true;
    say(S.pending,'busy');
    callNative('pickDatabaseFolder').then(function(reply){
      busy=false;
      if(reply.status==='granted'){
        log('granted '+reply.path);
        refresh();
        refreshPickerHint();
        say(S.added+reply.path,'ok');
        return;
      }
      if(reply.status==='cancelled'){say(S.cancelled,'info');return;}
      say(S.fail+(reply.message?': '+reply.message:''),'error');
    });
  }

  function onGrantDocuments(){
    if(busy)return;
    busy=true;
    say(S.granting,'busy');
    callNative('requestDocumentsPermission').then(function(reply){
      busy=false;
      refresh();
      refreshPickerHint();
      if(reply.status==='granted'){say(S.grantGranted+S.writable,'ok');return;}
      if(reply.status==='denied'){say(S.grantDenied,'error');return;}
      say(S.fail+(reply.message?': '+reply.message:''),'error');
    });
  }

  // Documents/DBX: live permission + writability, never revocable from here
  // (it is a user_grant permission, not a picker grant).
  function documentsRow(){
    var host=window.dbxNativeWindow;
    var box=el('div','border:1px solid var(--border);border-radius:8px;padding:8px 10px;margin-bottom:8px;');
    box.setAttribute('data-dbx-fm-row','documents');
    var path='';
    var status='unknown|no';
    try{if(host&&host.defaultFolder)path=String(host.defaultFolder()||'');}catch(e){}
    try{if(host&&host.documentsStatus)status=String(host.documentsStatus()||'unknown|no');}catch(e){}
    var parts=status.split('|');
    var permission=parts[0]||'unknown';
    var writable=parts[1]==='yes';
    box.setAttribute('data-dbx-fm-status',status);
    var top=el('div','display:flex;align-items:center;gap:8px;');
    top.appendChild(el('div','flex:1;min-width:0;word-break:break-all;font-size:12.5px;',
      path||'Documents/DBX'));
    var label=permission==='granted'?S.permGranted:(permission==='denied'?S.permDenied:S.permUnknown);
    var badgeText=label+(permission==='granted'?(' / '+(writable?S.writable:S.notWritable)):'');
    var badge=el('span',MUTED+(permission==='granted'?'':'color:var(--destructive);'),badgeText);
    badge.setAttribute('data-dbx-fm-perm',permission);
    top.appendChild(badge);
    if(!(permission==='granted'&&writable)){
      var gb=el('button',DANGER,S.grantNow);
      gb.type='button';
      gb.setAttribute('data-dbx-fm-grant','1');
      gb.addEventListener('click',onGrantDocuments);
      top.appendChild(gb);
    }
    box.appendChild(top);
    box.appendChild(el('div','margin-top:6px;'+MUTED,S.permTip));
    if(body)body.appendChild(box);
  }

  function grantedRow(path){
    var host=window.dbxNativeWindow;
    var box=el('div','border:1px solid var(--border);border-radius:8px;padding:8px 10px;margin-bottom:8px;');
    box.setAttribute('data-dbx-fm-row',path);
    var top=el('div','display:flex;align-items:center;gap:8px;');
    top.appendChild(el('div','flex:1;min-width:0;word-break:break-all;font-size:12.5px;',path));
    var rb=el('button',DANGER,S.revoke);
    rb.type='button';
    rb.setAttribute('data-dbx-fm-revoke','1');
    var armed=false,timer=null;
    rb.addEventListener('click',function(){
      if(!armed){
        armed=true;rb.textContent=S.confirm;
        timer=setTimeout(function(){armed=false;rb.textContent=S.revoke;},3000);
        return;
      }
      clearTimeout(timer);
      if(!host||!host.revokeGrantedFolder){say(S.fail,'error');return;}
      var result='';
      try{result=String(host.revokeGrantedFolder(path)||'');}catch(e){result='error';}
      log('revoke '+path+' -> '+result);
      if(result==='ok'){
        refresh();
        refreshPickerHint();
        say(S.revoked+path,'ok');
      }else{
        say(S.fail+' ('+result+')','error');
      }
    });
    top.appendChild(rb);
    box.appendChild(top);
    if(body)body.appendChild(box);
  }

  function refresh(){
    if(!body)return;
    body.textContent='';
    var host=window.dbxNativeWindow;
    if(!host){body.appendChild(el('p',MUTED,S.fail));return;}
    var granted=[];
    try{granted=String(host.grantedFolders()||'').split(NL).filter(function(v){return !!v;});}catch(e){}
    documentsRow();
    if(granted.length===0){
      body.appendChild(el('p','margin:8px 0 4px;'+MUTED,S.empty));
    }
    for(var i=0;i<granted.length;i++)grantedRow(granted[i]);
  }

  function build(){
    overlay=el('div','position:fixed;left:0;top:0;'+
      'width:calc(100vw / var(--dbx-fm-zoom,1));height:calc(100vh / var(--dbx-fm-zoom,1));'+
      'display:flex;align-items:center;justify-content:center;background:rgba(0,0,0,0.35);z-index:2147483000;');
    overlay.setAttribute('data-dbx-fm-overlay','1');
    var card=el('div','display:flex;flex-direction:column;'+
      'width:min(620px,calc(100% - 32px));max-height:calc(100% - 32px);'+
      'background:var(--background);color:var(--foreground);border:1px solid var(--border);'+
      'border-radius:10px;box-shadow:0 12px 32px rgba(0,0,0,0.28);overflow:hidden;font-size:13px;');
    var head=el('div','display:flex;align-items:center;gap:8px;padding:12px 14px;border-bottom:1px solid var(--border);');
    head.appendChild(el('div','flex:1;font-weight:600;',S.title));
    var x=el('button','border:0;background:transparent;color:var(--muted-foreground);cursor:pointer;'+
      'font-size:18px;line-height:1;padding:2px 6px;',TIMES);
    x.type='button';
    x.setAttribute('aria-label',S.close);
    x.addEventListener('click',close);
    head.appendChild(x);
    card.appendChild(head);
    msgBox=el('div','display:none;padding:8px 14px;font-size:12px;'+MUTED);
    msgBox.setAttribute('data-dbx-fm-message','1');
    card.appendChild(msgBox);
    body=el('div','overflow:auto;padding:10px 14px;');
    body.setAttribute('data-dbx-fm-body','1');
    card.appendChild(body);
    var foot=el('div','display:flex;align-items:center;gap:8px;padding:10px 14px;border-top:1px solid var(--border);');
    foot.appendChild(el('div','flex:1;'+MUTED,S.tip));
    var addBtn=el('button',BTN,S.add);
    addBtn.type='button';
    addBtn.setAttribute('data-dbx-fm-add','1');
    addBtn.addEventListener('click',onAdd);
    foot.appendChild(addBtn);
    var closeBtn=el('button',BTN,S.close);
    closeBtn.type='button';
    closeBtn.addEventListener('click',close);
    foot.appendChild(closeBtn);
    card.appendChild(foot);
    overlay.appendChild(card);
    overlay.addEventListener('click',function(e){if(e.target===overlay)close();});
    document.body.appendChild(overlay);
  }

  function toggle(){
    if(overlay){close();return;}
    build();
    refresh();
    log('panel opened');
  }

  // --- toolbar entry -------------------------------------------------------
  function injectButton(){
    var tb=document.querySelector('.app-toolbar');
    if(!tb)return false;
    var existing=tb.querySelector('[data-dbx-folder-manager]');
    if(existing){
      var span=existing.querySelector('span');
      if(span&&span.textContent!==S.button)span.textContent=S.button;
      return true;
    }
    // Structural anchors: the flex-1 spacer separates the left action group from
    // the right-hand window controls, and 「更多」/More is its last left sibling.
    var spacer=tb.querySelector('div.flex-1');
    var last=spacer?spacer.previousElementSibling:null;
    var sample=last&&last.previousElementSibling?last.previousElementSibling:last;
    if(!sample||sample.tagName!=='BUTTON')sample=tb.querySelector('button');
    var btn=document.createElement('button');
    btn.type='button';
    btn.setAttribute('data-dbx-folder-manager','1');
    btn.setAttribute('data-slot','button');
    btn.className=sample?sample.className:'';
    btn.title=S.title;
    btn.setAttribute('aria-label',S.title);
    btn.innerHTML=ICON+'<span></span>';
    var label=btn.querySelector('span');
    if(label)label.textContent=S.button;
    btn.addEventListener('click',function(e){
      e.preventDefault();
      e.stopPropagation();
      toggle();
    });
    if(last&&last.parentNode===tb){tb.insertBefore(btn,last);}
    else if(spacer&&spacer.parentNode===tb){tb.insertBefore(btn,spacer);}
    else{tb.appendChild(btn);}
    log('toolbar button injected');
    return true;
  }

  var scheduled=false;
  function schedule(){
    if(scheduled)return;
    scheduled=true;
    setTimeout(function(){scheduled=false;injectButton();},150);
  }
  try{
    var observer=new MutationObserver(schedule);
    observer.observe(document.documentElement,{childList:true,subtree:true});
  }catch(e){log('observer unavailable: '+e);}
  if(document.readyState==='loading'){
    document.addEventListener('DOMContentLoaded',schedule);
  }else{
    schedule();
  }
})();`;

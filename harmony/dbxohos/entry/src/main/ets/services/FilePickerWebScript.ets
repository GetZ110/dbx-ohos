/**
 * Web-page injection for the local-database file-path row.
 *
 * Injected with `javaScriptOnDocumentStart` (see Index.ets) and pairs with
 * `FilePickerBridge`:
 *
 * 1. Finds the connection dialog row labelled with `connection.filePath`
 *    (the only place that i18n key is rendered);
 * 2. Makes its input read-only, because arbitrary typed paths cannot be opened
 *    on HarmonyOS anyway;
 * 3. Appends "select file" / "create database file" buttons that go through
 *    `window.dbxNativeWindow.pickDatabaseFile` (ArkWeb exposes only one
 *    JavaSciptProxy object), plus a "use in-memory database" button whose
 *    row still advertises `:memory:`;
 * 4. Hides itself for SSH connections, where the path is a remote path that a
 *    local picker must not touch.
 *
 * The upstream dialog already renders exactly these buttons on desktop, but
 * behind `v-if="isDesktop"` (which is `isTauriRuntime()`, false here) and wired
 * to `@tauri-apps/plugin-dialog`. Rebuilding the frontend bundle requires fork
 * CI, so — like the UI-scale and grid-header patches — the HarmonyOS variant
 * lives in a native injection script. Fold this into ConnectionDialog.vue the
 * next time the dist is rebuilt from source.
 *
 * Diagnostics are logged as `[DBX-FILEPICK] ...`, which `onConsole` forwards to
 * hilog.
 */
export const FILE_PICKER_INJECTION_SCRIPT: string =
  `(function(){
  if(window.__dbxDbFilePicker)return;
  window.__dbxDbFilePicker=true;

  function log(message){try{console.log('[DBX-FILEPICK] '+message);}catch(e){}}

  // Label text of connection.filePath per locale: the only stable, language
  // aware way to find the row from outside Vue. Button labels are translated
  // for zh-CN / zh-TW / en and fall back to English for the other locales.
  var EN={
    select:'Select File',
    create:'Create Database File',
    memory:'Use In-Memory Database',
    busy:'Opening...',
    copyHint:'Copied to {path} - this is a copy, edits are not written back to the original file',
    fail:'Cannot use the selected file',
    unavailable:'The system file picker is unavailable in this build',
    grant:'Authorize Folder',
    granted:'Folder authorized: ',
    dirHint:'Local database files live in Documents/DBX (or authorize a folder first)',
    outside:'That folder is not authorized, so the database cannot be edited in place. Tap the folder button on the right and pick that folder once, then choose the file again. Selected: '
  };
  var LOCALES=[
    {path:'文件路径',remote:'请填写最后一跳 SSH 主机上的绝对路径。',
     select:'选择文件',create:'新建数据库文件',memory:'使用内存数据库',busy:'正在打开...',
     copyHint:'已复制到 {path}（是副本，改动不会写回原文件）',fail:'无法使用所选文件',
     unavailable:'当前版本不支持系统文件选择',
     grant:'授权文件夹',
     granted:'已授权文件夹：',
     dirHint:'本地数据库文件请放在「文档 / DBX」目录下，或先授权一个文件夹',
     outside:'该目录未授权，无法就地读写数据库。请点右侧「授权文件夹」选中这个目录（只需一次），再重新选择文件。所选文件：'},
    {path:'檔案路徑',remote:'請填寫最後一跳 SSH 主機上的絕對路徑。',
     select:'選擇檔案',create:'新建資料庫檔案',memory:'使用記憶體資料庫',busy:'正在開啟...',
     copyHint:'已複製到 {path}（為副本，變更不會寫回原檔案）',fail:'無法使用所選檔案',
     unavailable:'目前版本不支援系統檔案選擇',
     grant:'授權資料夾',
     granted:'已授權資料夾：',
     dirHint:'本機資料庫檔案請放在「文件 / DBX」目錄下，或先授權一個資料夾',
     outside:'該目錄未授權，無法就地讀寫資料庫。請點右側「授權資料夾」選中這個目錄（只需一次），再重新選擇檔案。所選檔案：'},
    {path:'File Path',remote:'Enter an absolute path on the final SSH hop.',
     select:EN.select,create:EN.create,memory:EN.memory,busy:EN.busy,
     copyHint:EN.copyHint,fail:EN.fail,unavailable:EN.unavailable},
    {path:'Ruta del archivo',remote:'Introduce una ruta absoluta en el último salto SSH.'},
    {path:'Percorso File',remote:"Inserisci un percorso assoluto sull'ultimo salto SSH."},
    {path:'ファイルパス',remote:'最終 SSH ホップ上の絶対パスを入力してください。'},
    {path:'파일 경로',remote:'마지막 SSH 홉의 절대 경로를 입력하세요.'},
    {path:'Caminho do Arquivo',remote:'Informe um caminho absoluto no último salto SSH.'},
    {path:'Dosya Yolu',remote:'Son SSH atlamasındaki mutlak bir yol girin.'},
    {path:'Faylın yolu',remote:'Son SSH keçidində mütləq yol daxil edin.'}
  ];

  var ICON_SELECT='<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m6 14 1.45-2.9A2 2 0 0 1 9.24 10H20a2 2 0 0 1 1.94 2.5l-1.55 6a2 2 0 0 1-1.94 1.5H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h3.93a2 2 0 0 1 1.66.9l.82 1.2a2 2 0 0 0 1.66.9H18a2 2 0 0 1 2 2v2"/></svg>';
  var ICON_CREATE='<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/><path d="M9 15h6"/><path d="M12 12v6"/></svg>';
  var ICON_GRANT='<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/><path d="M12 10v6"/><path d="M9 13h6"/></svg>';
  var ICON_MEMORY='<svg xmlns="http://www.w3.org/2000/svg" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M6 19v-3"/><path d="M10 19v-3"/><path d="M14 19v-3"/><path d="M18 19v-3"/><path d="M8 11V9"/><path d="M16 11V9"/><path d="M12 11V9"/><path d="M2 15h20"/><path d="M2 7a1 1 0 0 1 1-1h18a1 1 0 0 1 1 1v5a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1z"/></svg>';
  // Used only when no outline button can be sampled; the sampled class keeps
  // the injected buttons pixel-identical to the app's own buttons.
  var FALLBACK_BUTTON_CLASS='inline-flex shrink-0 items-center justify-center gap-1 whitespace-nowrap rounded-md border h-7 px-2.5 text-xs font-medium transition-colors outline-none select-none';

  var strings=function(entry){
    var out={},key;
    for(key in EN){out[key]=entry&&entry[key]?entry[key]:EN[key];}
    return out;
  };

  var matchLocale=function(text){
    for(var i=0;i<LOCALES.length;i++){if(LOCALES[i].path===text)return LOCALES[i];}
    return null;
  };

  var isRemote=function(row,entry){
    if(!entry.remote)return false;
    var ps=row.querySelectorAll('p');
    for(var i=0;i<ps.length;i++){
      if((ps[i].textContent||'').trim()===entry.remote)return true;
    }
    return false;
  };

  var findTarget=function(){
    var labels=[],i,j;
    var scopes=document.querySelectorAll('[data-slot="dialog-content"]');
    for(i=0;i<scopes.length;i++){
      var inner=scopes[i].querySelectorAll('[data-slot="label"]');
      for(j=0;j<inner.length;j++)labels.push(inner[j]);
    }
    if(labels.length===0){
      var all=document.querySelectorAll('[data-slot="label"]');
      for(i=0;i<all.length;i++)labels.push(all[i]);
    }
    for(i=0;i<labels.length;i++){
      var entry=matchLocale((labels[i].textContent||'').trim());
      if(!entry)continue;
      var row=labels[i].closest('.grid');
      if(!row)continue;
      var input=row.querySelector('input[data-slot="input"]');
      if(!input)continue;
      if(isRemote(row,entry)){log('skipped: remote (SSH) file path row');continue;}
      return {row:row,input:input,entry:entry};
    }
    return null;
  };

  var outlineButtonClass=function(scope){
    var btn=(scope?scope.querySelector('[data-slot="button"][data-variant="outline"]'):null)
      ||document.querySelector('[data-slot="button"][data-variant="outline"]');
    if(btn&&btn.className)return btn.className;
    return FALLBACK_BUTTON_CLASS;
  };

  var makeButton=function(kind,text,title,icon,cls,sampled,fallbackStyle){
    var btn=document.createElement('button');
    btn.type='button';
    btn.setAttribute('data-slot','button');
    btn.setAttribute('data-variant','outline');
    btn.setAttribute('data-dbx-file-action',kind);
    btn.className=cls;
    btn.title=title;
    btn.setAttribute('aria-label',title);
    if(!sampled){
      btn.style.border='1px solid var(--border)';
      btn.style.background='var(--background)';
      btn.style.color='var(--foreground)';
      btn.style.borderRadius='6px';
      btn.style.height='28px';
      btn.style.padding='0 10px';
      btn.style.fontSize='12.5px';
      btn.style.cursor='pointer';
    }
    if(fallbackStyle){
      btn.style.padding=fallbackStyle.padding;
      btn.style.width=fallbackStyle.width;
    }
    btn.innerHTML=icon+(text?'<span>'+text+'</span>':'');
    return btn;
  };

  var setPath=function(state,value){
    var input=state.input;
    input.value=value;
    input.title=value;
    input.dispatchEvent(new Event('input',{bubbles:true}));
    input.dispatchEvent(new Event('change',{bubbles:true}));
  };

  function refreshHint(state){
    var hint=state.hint;
    if(!hint)return;
    var extra='';
    try{
      var w=window.dbxNativeWindow;
      if(w&&w.grantedFolders){
        var granted=w.grantedFolders();
        if(granted)extra='  |  '+granted.split('\\n').join(' , ');
      }
    }catch(e){}
    hint.textContent=state.strings.dirHint+extra;
  }

  // Used by the folder-manager panel after it grants or revokes a folder.
  window.__dbxFilePickerRefreshHint=function(){if(current)refreshHint(current);};

  var messageTimer=null;
  // 'error' and 'notice' stay until the next action (a check failed / the value
  // points at a copy); 'info' is transient.
  var showMessage=function(state,text,kind){
    var msg=state.msg;
    if(messageTimer){clearTimeout(messageTimer);messageTimer=null;}
    if(!text){msg.style.display='none';msg.textContent='';return;}
    msg.textContent=text;
    msg.style.display='';
    msg.style.color=kind==='error'?'var(--destructive)':'';
    if(kind==='info'){
      messageTimer=setTimeout(function(){msg.style.display='none';msg.textContent='';},6000);
    }
  };

  var setBusy=function(state,busy){
    state.selectBtn.disabled=busy;
    state.createBtn.disabled=busy;
    if(state.memoryBtn)state.memoryBtn.disabled=busy;
    var label=state.selectBtn.querySelector('span');
    if(label)label.textContent=busy?state.strings.busy:state.strings.select;
  };

  // Native results arrive through __dbxFilePickerDeliver (FilePickerBridge).
  var pending={},seq=0;
  window.__dbxFilePickerDeliver=function(id,status,path,message){
    var cb=pending[id];
    if(!cb)return;
    delete pending[id];
    cb(String(status||''),String(path||''),String(message||''));
  };
  var requestPick=function(mode,arg){
    return new Promise(function(resolve){
      // ArkWeb exposes only one JavaSciptProxy object per page, so the picker
      // rides on the shell bridge (dbxNativeWindow).
      var host=window.dbxNativeWindow||window.dbxNativeFilePicker;
      if(!host){
        resolve({status:'unavailable',path:'',message:''});
        return;
      }
      var call=null;
      if(mode==='grant'&&host.pickDatabaseFolder){
        call=function(id){host.pickDatabaseFolder(id);};
      }else if(host.pickDatabaseFile){
        call=function(id){host.pickDatabaseFile(id,mode);};
      }
      if(!call){
        resolve({status:'unavailable',path:'',message:''});
        return;
      }
      var id='dbxfp'+(++seq);
      pending[id]=function(status,path,message){
        resolve({status:status,path:path,message:message});
      };
      try{call(id);}
      catch(e){delete pending[id];resolve({status:'error',path:'',message:String(e)});}
    });
  };

  var runPick=function(state,mode){
    setBusy(state,true);
    requestPick(mode).then(function(reply){
      setBusy(state,false);
      if(reply.status==='ok'||reply.status==='copied'){
        setPath(state,reply.path);
        log('picked '+reply.status+' -> '+reply.path);
        if(reply.status==='copied'){
          showMessage(state,String(state.strings.copyHint).split('{path}').join(reply.path),'notice');
        }else{
          showMessage(state,'','info');
        }
        return;
      }
      if(reply.status==='granted'){
        log('folder granted: '+reply.path);
        showMessage(state,state.strings.granted+reply.path,'notice');
        refreshHint(state);
        return;
      }
      if(reply.status==='cancelled'){log('picker cancelled');return;}
      if(reply.status==='outside'){
        // Only a folder the system picker handed out can be persisted, so the
        // app cannot authorize anything on its own - point at the button.
        log('outside the allowed roots: '+reply.path);
        showMessage(state,state.strings.outside+reply.path,'error');
        return;
      }
      if(reply.status==='unavailable'){showMessage(state,state.strings.unavailable,'error');return;}
      if(reply.status==='error'){
        log('pick failed: '+reply.message);
        showMessage(state,state.strings.fail+(reply.message?': '+reply.message:''),'error');
      }
    });
  };

  var buildTools=function(found){
    var input=found.input,row=input.parentNode;
    if(!row)return null;
    var S=strings(found.entry);
    var cls=outlineButtonClass(found.row);
    var sampled=cls!==FALLBACK_BUTTON_CLASS;

    row.style.flexWrap='wrap';
    input.style.flex='1 1 10rem';
    input.style.minWidth='7rem';
    input.readOnly=true;
    input.setAttribute('aria-readonly','true');
    input.classList.add('cursor-default');
    input.style.backgroundColor='var(--muted)';
    input.title=input.value||'';

    var group=document.createElement('span');
    group.setAttribute('data-dbx-file-actions','1');
    group.style.display='inline-flex';
    group.style.alignItems='center';
    group.style.gap='4px';
    group.style.flexShrink='0';

    var selectBtn=makeButton('select',S.select,S.select,ICON_SELECT,cls,sampled,null);
    var createBtn=makeButton('create','',S.create,ICON_CREATE,cls,sampled,{padding:'0',width:'28px'});
    group.appendChild(selectBtn);
    group.appendChild(createBtn);
    var memoryBtn=null;
    if((input.placeholder||'').indexOf(':memory:')>=0){
      memoryBtn=makeButton('memory','',S.memory,ICON_MEMORY,cls,sampled,{padding:'0',width:'28px'});
      group.appendChild(memoryBtn);
    }
    var grantBtn=makeButton('grant','',S.grant,ICON_GRANT,cls,sampled,{padding:'0',width:'28px'});
    group.appendChild(grantBtn);
    row.appendChild(group);

    var container=found.row.querySelector('.col-span-3')||row.parentNode;
    var hint=document.createElement('p');
    hint.setAttribute('data-dbx-file-hint','1');
    hint.className='text-xs text-muted-foreground';
    hint.textContent=S.dirHint;
    if(container)container.appendChild(hint);
    var msg=document.createElement('p');
    msg.setAttribute('data-dbx-file-message','1');
    msg.className='text-xs text-muted-foreground';
    msg.style.display='none';
    msg.setAttribute('aria-live','polite');
    if(container)container.appendChild(msg);

    var state={row:found.row,input:input,entry:found.entry,group:group,msg:msg,hint:hint,
      selectBtn:selectBtn,createBtn:createBtn,memoryBtn:memoryBtn,grantBtn:grantBtn,strings:S};
    selectBtn.addEventListener('click',function(){runPick(state,'open');});
    createBtn.addEventListener('click',function(){runPick(state,'create');});
    grantBtn.addEventListener('click',function(){runPick(state,'grant');});
    if(memoryBtn){
      memoryBtn.addEventListener('click',function(){
        setPath(state,':memory:');
        log('path set to :memory:');
      });
    }
    refreshHint(state);
    log('tools injected (read-only path box + select/create/memory/folder-grant)');
    return state;
  };

  var current=null;
  var apply=function(){
    var found=findTarget();
    if(!found){
      if(current)log('file path row left the DOM');
      current=null;
      return;
    }
    if(current&&current.row===found.row&&current.input===found.input){
      if(!found.input.readOnly)found.input.readOnly=true;
      if(!current.group.isConnected){current=null;current=buildTools(found);}
      return;
    }
    current=null;
    current=buildTools(found);
  };

  var scheduled=false;
  var schedule=function(){
    if(scheduled)return;
    scheduled=true;
    setTimeout(function(){scheduled=false;apply();},120);
  };
  try{
    var observer=new MutationObserver(schedule);
    observer.observe(document.documentElement,{childList:true,subtree:true});
  }catch(e){log('observer unavailable: '+e);}
  if(document.readyState==='loading'){
    document.addEventListener('DOMContentLoaded',apply);
  }else{
    apply();
  }
})();`;

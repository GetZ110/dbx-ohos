const __vite__mapDeps=(i,m=__vite__mapDeps,d=(m.f||(m.f=["./core-B3Q2RYB7.js","./rolldown-runtime-Dd_uD5pT.js","./bash-BiGZg9Om.js","./shellscript-CqHdAlCp.js","./css-CdtkT07m.js","./css-LbU1hoFO.js","./html-DDNsd9lV.js","./html-BcACZWSP.js","./javascript-BzbQS41l.js","./java-DxlWrXwe.js","./java-BtIQNnN0.js","./javascript-Yelw-5ZN.js","./json-CaljABEy.js","./json-B88Oqtu5.js","./php-CQT4wx5i.js","./xml-WY0zc4PG.js","./sql-CP0rg-5b.js","./shellscript-BiGZg9Om.js","./sql-0Qcw9ht3.js","./typescript-Utq2Cl8c.js","./typescript-j_1H8WHN.js","./vue-DsZfPFPA.js","./xml-CoDIzWF0.js","./dom-to-image-more.min-DSYjtYx-.js","./dist-js-CmmC70Ma.js","./core-bZKCCQDm.js","./image-eYwOAAAa.js","./dist-js-D0bf773G.js","./dist-js-CQg21qYZ.js","./path-C8v8aBvK.js"])))=>i.map(i=>d[i]);
import{i as e}from"./rolldown-runtime-Dd_uD5pT.js";import{t}from"./preload-helper-HclGiUj8.js";import"./index-C4_pfvaR.js";import{t as n}from"./createLucideIcon-DTGCHDGZ.js";import{r}from"./tauriRuntime-DRoOMtSE.js";import{Sp as i,cm as a,lm as o,yp as s}from"./api-M0x-yeuT.js";var c=n(`camera`,[[`path`,{d:`M13.997 4a2 2 0 0 1 1.76 1.05l.486.9A2 2 0 0 0 18.003 7H20a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2h1.997a2 2 0 0 0 1.759-1.048l.489-.904A2 2 0 0 1 10.004 4z`,key:`18u6gg`}],[`circle`,{cx:`12`,cy:`13`,r:`3`,key:`1vg3eu`}]]),l=new Set([`mysql`,`clickhouse`,`hive`,`kyuubi`,`impala`,`spark`,`databricks`,`databend`,`tdengine`,`access`,`doris`,`starrocks`,`goldendb`]),u=new Set([`postgres`,`gaussdb`,`opengauss`]),d=new Set([`sqlserver`]);function f(e,t){return e&&l.has(e)?a(t)?`\`${t.replace(/`/g,"``")}\``:t:e&&u.has(e)?o(t)?`"${t.replace(/"/g,`""`)}"`:t:e&&d.has(e)?o(t)?`[${t.replace(/\]/g,`]]`)}]`:t:a(t)?i(e,t):t}var p=`application/x-dbx-table-reference`,m=`dbx-table-reference-drop`,h=`dbx-table-reference-hover`,g=`dbx-table-reference-drag-end`;function _(e){return Array.isArray(e)?e.map(e=>typeof e==`string`?e.trim():``).filter(e=>e.length>0):[]}function v(e,t){typeof t.schema==`string`&&t.schema&&(e.schema=t.schema),t.databaseType&&(e.databaseType=t.databaseType),typeof t.driverProfile==`string`&&t.driverProfile&&(e.driverProfile=t.driverProfile)}var y=null;function b(e){if(!e.connectionId||e.database==null)return null;let t=e.referenceType??(e.columnName?`column`:`table`);if(t!==`database`&&!e.tableName)return null;let n={kind:`dbx-table-reference`,connectionId:e.connectionId,database:e.database};return t===`database`?n.referenceType=`database`:n.tableName=e.tableName,t===`column`&&e.columnName&&(n.columnName=e.columnName,n.referenceType=`column`),v(n,e),n}function x(e){let t=_(e.columnNames);if(!e.connectionId||e.database==null||t.length===0)return null;let n={kind:`dbx-table-reference`,connectionId:e.connectionId,database:e.database,referenceType:`column`,columnNames:t};return v(n,e),n}function S(e){if(!e)return null;try{let t=JSON.parse(e);if(t.kind!==`dbx-table-reference`||typeof t.connectionId!=`string`||typeof t.database!=`string`||!t.connectionId)return null;if(t.referenceType===`database`){let e={kind:`dbx-table-reference`,connectionId:t.connectionId,database:t.database,referenceType:`database`};return t.databaseType&&(e.databaseType=t.databaseType),typeof t.driverProfile==`string`&&t.driverProfile&&(e.driverProfile=t.driverProfile),e}if(typeof t.tableName!=`string`||!t.tableName){let e=_(t.columnNames);if(e.length===0)return null;let n={kind:`dbx-table-reference`,connectionId:t.connectionId,database:t.database,referenceType:`column`,columnNames:e};return v(n,t),n}let n=typeof t.columnName==`string`&&t.columnName?t.columnName:void 0,r=t.referenceType===`column`||n?`column`:`table`;if(r===`column`&&!n)return null;let i={kind:`dbx-table-reference`,connectionId:t.connectionId,database:t.database,tableName:t.tableName};return r===`column`&&n&&(i.columnName=n,i.referenceType=`column`),v(i,t),i}catch{return null}}function C(e){if(!e)return!1;for(let t of e)if(t===`application/x-dbx-table-reference`)return!0;return!1}function ee(e){y=e}function w(){return y}function T(e){(!e||y===e)&&(y=null)}function E(e){return new CustomEvent(m,{detail:e})}function D(e){return new CustomEvent(h,{detail:e})}function O(){return new Event(g)}function k(e,t){let n=e.databaseType??t;if(e.referenceType===`database`)return i(n,e.database);let r=e.columnNames?.length?e.columnNames:e.columnName?[e.columnName]:[];if(e.referenceType===`column`&&r.length>0)return r.map(e=>f(n,e)).join(`,
`);let a=e.tableName||e.database;return s({databaseType:n,driverProfile:e.driverProfile,schema:e.schema,tableName:a})}var A={dark:`github-dark`,light:`github-light`},j={BASH:`bash`,CLICKHOUSE:`sql`,CSS:`css`,GO:`go`,HTML:`html`,JAVA:`java`,JAVASCRIPT:`javascript`,JS:`javascript`,JSON:`json`,MARKDOWN:`markdown`,MYSQL:`sql`,PHP:`php`,POSTGRESQL:`sql`,PYTHON:`python`,RUST:`rust`,SHELL:`shellscript`,SH:`shellscript`,SQL:`sql`,SQLITE:`sql`,TS:`typescript`,TSQL:`sql`,TSX:`tsx`,TYPESCRIPT:`typescript`,VUE:`vue`,XML:`xml`,YAML:`yaml`,YML:`yaml`,ZSH:`shellscript`},M;async function te(e){let t=await F();return(n,r,i=e.appearance())=>t.codeToHtml(n,{lang:L(r),structure:`inline`,theme:A[i]})}async function N(e){let t=await F();return(n,r,i=e.appearance())=>P(t.codeToHtml(n,{lang:L(r),structure:`classic`,theme:A[i]}))}function P(e){let t=/<code[^>]*>([\s\S]*)<\/code>/.exec(e);return(t?t[1]:e).replace(/<\/span>\n/g,`</span>`)}function F(){return M??=I(),M}async function I(){let[{createHighlighterCore:e},{createJavaScriptRegexEngine:n},r,i,a,o,s,c,l,u,d,f,p,m,h,g,_,v,y,b,x,S]=await Promise.all([t(()=>import(`./core-B3Q2RYB7.js`),__vite__mapDeps([0,1]),import.meta.url),t(()=>import(`./engine-javascript-vHStYFkU.js`),[],import.meta.url),t(()=>import(`./github-dark-C-LZuMrd.js`),[],import.meta.url),t(()=>import(`./github-light-EUqPIrTm.js`),[],import.meta.url),t(()=>import(`./bash-BiGZg9Om.js`),__vite__mapDeps([2,3]),import.meta.url),t(()=>import(`./css-CdtkT07m.js`),__vite__mapDeps([4,5]),import.meta.url),t(()=>import(`./go-rLFTqkRN.js`),[],import.meta.url),t(()=>import(`./html-DDNsd9lV.js`),__vite__mapDeps([6,7,5,8]),import.meta.url),t(()=>import(`./java-DxlWrXwe.js`),__vite__mapDeps([9,10]),import.meta.url),t(()=>import(`./javascript-Yelw-5ZN.js`),__vite__mapDeps([11,8]),import.meta.url),t(()=>import(`./json-CaljABEy.js`),__vite__mapDeps([12,13]),import.meta.url),t(()=>import(`./markdown-BYOwaDjH.js`),[],import.meta.url),t(()=>import(`./php-CQT4wx5i.js`),__vite__mapDeps([14,5,8,7,13,15,10,16]),import.meta.url),t(()=>import(`./python-gzcpVVnB.js`),[],import.meta.url),t(()=>import(`./rust-Cfkwpbl8.js`),[],import.meta.url),t(()=>import(`./shellscript-BiGZg9Om.js`),__vite__mapDeps([17,3]),import.meta.url),t(()=>import(`./sql-0Qcw9ht3.js`),__vite__mapDeps([18,16]),import.meta.url),t(()=>import(`./tsx-udAQXfEw.js`),[],import.meta.url),t(()=>import(`./typescript-Utq2Cl8c.js`),__vite__mapDeps([19,20]),import.meta.url),t(()=>import(`./vue-DsZfPFPA.js`),__vite__mapDeps([21,5,8,7,13,20]),import.meta.url),t(()=>import(`./xml-CoDIzWF0.js`),__vite__mapDeps([22,15,10]),import.meta.url),t(()=>import(`./yaml-rwi0_p6S.js`),[],import.meta.url)]);return e({engine:n(),langs:[a.default,o.default,s.default,c.default,l.default,u.default,d.default,f.default,p.default,m.default,h.default,g.default,_.default,v.default,y.default,b.default,x.default,S.default],themes:[r.default,i.default]})}function L(e){return j[e.toUpperCase()]??`text`}var R={light:`#ffffff`,dark:`#0d1117`},z={light:`#f6f8fa`,dark:`#161b22`},B={light:`#57606a`,dark:`#8b949e`},V={light:`#d0d7de`,dark:`#484f58`},H={light:`#24292f`,dark:`#e1e4e8`},U=[`#ff5f57`,`#febc2e`,`#28c840`],W=2,G=16384,K=67108864,q=`
.dbx-code-snapshot,
.dbx-code-snapshot * {
  border: 0;
  outline: 0;
}
.dbx-code-snapshot {
  border-radius: 8px;
  overflow: hidden;
  font-family: "SF Mono", "Cascadia Code", "JetBrains Mono", Consolas, "Courier New", monospace;
  text-align: left;
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.35);
}
.dbx-code-snapshot__bar {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 10px 14px;
}
.dbx-code-snapshot__dot {
  width: 12px;
  height: 12px;
  border-radius: 50%;
  flex: none;
}
.dbx-code-snapshot__title {
  margin-left: 4px;
  font-size: 12px;
  font-weight: 500;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.dbx-code-snapshot__pre {
  margin: 0;
  overflow: hidden;
  line-height: 1.6;
  tab-size: 4;
}
.dbx-code-snapshot__pre code {
  font-family: inherit;
  font-size: inherit;
  background: transparent;
}
.dbx-code-snapshot__pre .line {
  display: block;
  min-height: 1.6em;
}
.dbx-code-snapshot__line-number {
  display: inline-block;
  min-width: 2.2em;
  margin-right: 1.4em;
  text-align: right;
  color: var(--dbx-snapshot-line-number, #8b949e);
  font-variant-numeric: tabular-nums;
  user-select: none;
  -webkit-user-select: none;
}
.dbx-code-snapshot__pre--numbered {
  counter-reset: dbx-snapshot-line;
}
.dbx-code-snapshot__pre--numbered .line {
  counter-increment: dbx-snapshot-line;
}
.dbx-code-snapshot__pre--numbered .line::before {
  content: counter(dbx-snapshot-line);
  display: inline-block;
  min-width: 2.2em;
  margin-right: 1.4em;
  text-align: right;
  color: var(--dbx-snapshot-line-number, #8b949e);
  font-variant-numeric: tabular-nums;
  user-select: none;
  -webkit-user-select: none;
}
`,J;function Y(){return J??=N({appearance:()=>`dark`}).catch(e=>{throw J=void 0,e}),J}function X(e){return e.replaceAll(`&`,`&amp;`).replaceAll(`<`,`&lt;`).replaceAll(`>`,`&gt;`).replaceAll(`"`,`&quot;`).replaceAll(`'`,`&#39;`)}function Z(e){return`<span class="line">${X(e).replace(/\r\n|\r|\n/g,`</span><span class="line">`)}</span>`}function ne(e,t,n){let r=n?U.map(e=>`<span class="dbx-code-snapshot__dot" style="background:${e}"></span>`).join(``):``,i=e?`<span class="dbx-code-snapshot__title" style="color:${B[t]}">${X(e)}</span>`:``;return`<div class="dbx-code-snapshot__bar" style="background:${z[t]};color:${B[t]}">${r}${i}</div>`}function re(e){return e instanceof Element&&e.classList.contains(`line`)&&e.closest(`.dbx-code-snapshot__pre--numbered`)!==null}function ie(e){return Array.from(e.children).some(e=>e.classList.contains(`dbx-code-snapshot__line-number`))}function ae(){return typeof document<`u`&&document.documentElement.classList.contains(`dbx-legacy-webview`)}function oe(e){for(let t of Array.from(e.querySelectorAll(`.dbx-code-snapshot__pre--numbered`))){t.classList.remove(`dbx-code-snapshot__pre--numbered`);let e=t.style.getPropertyValue(`--dbx-snapshot-line-number`).trim()||V.dark,n=Array.from(t.querySelectorAll(`code > .line`));for(let[r,i]of n.entries()){if(ie(i))continue;let n=t.ownerDocument.createElement(`span`);n.className=`dbx-code-snapshot__line-number`,n.setAttribute(`aria-hidden`,`true`),n.textContent=String(r+1),n.style.cssText=[`display:inline-block`,`min-width:2.2em`,`margin-right:1.4em`,`text-align:right`,`color:${e}`,`font-variant-numeric:tabular-nums`,`user-select:none`,`-webkit-user-select:none`].join(`;`);let a=t.ownerDocument.createElement(`span`);for(a.className=`dbx-code-snapshot__line-content`,a.style.display=`inline`;i.firstChild;)a.append(i.firstChild);i.append(n,a)}}}async function se(e,t){let n;try{n=(await Y())(e.code,e.lang,t.appearance)}catch{n=Z(e.code)}let r=t.appearance,i=t.showTrafficLights!==!1||!!e.title,a=t.showLineNumbers!==!1,o=t.padding??16,s=t.fontSize??13,c=i?ne(e.title,r,t.showTrafficLights!==!1):``,l=`dbx-code-snapshot__pre${a?` dbx-code-snapshot__pre--numbered`:``}`,u=V[r];return`<style>${q}</style><div class="dbx-code-snapshot" data-snapshot-appearance="${r}" style="background:${R[r]};font-size:${s}px">`+c+`<pre class="${l}" style="--dbx-snapshot-line-number:${u};color:${H[r]};padding:0 ${o}px ${o}px"><code>${n}</code></pre></div>`}async function Q(n){let r=(await t(async()=>{let{default:t}=await import(`./dom-to-image-more.min-DSYjtYx-.js`).then(t=>e(t.default,1));return{default:t}},__vite__mapDeps([23,1]),import.meta.url)).default,i=Math.max(n.offsetWidth,n.scrollWidth),a=Math.max(n.offsetHeight,n.scrollHeight),o=i*a;if(i>G||a>G||o>K)throw Error(`Snapshot is too large to export safely (${i} × ${a}px). Reduce the code size and try again.`);let s=Math.min(W,Math.max(1,typeof window>`u`?1:window.devicePixelRatio||1)),c=Math.min(s,G/i,G/a,Math.sqrt(K/o)),l=ae();return r.toPng(n,{quality:1,width:i,height:a,scale:c,adjustPseudoElement:l?(e,t)=>{if(t===`:before`&&re(e))return!1}:void 0,onclone:l?e=>{typeof e.querySelectorAll==`function`&&oe(e)}:void 0,style:{width:`${i}px`,height:`${a}px`}})}async function $(e){return await(await fetch(e)).blob()}async function ce(e){let n=await $(e);if(r()){let{writeImage:e}=await t(async()=>{let{writeImage:e}=await import(`./dist-js-CmmC70Ma.js`);return{writeImage:e}},__vite__mapDeps([24,25,1,26]),import.meta.url);await e(new Uint8Array(await n.arrayBuffer()));return}if(typeof ClipboardItem<`u`&&navigator.clipboard?.write){await navigator.clipboard.write([new ClipboardItem({"image/png":n})]);return}throw Error(`Clipboard image write is not supported in this environment`)}async function le(e,n){let i=await $(e);if(r()){let{save:e}=await t(async()=>{let{save:e}=await import(`./dist-js-D0bf773G.js`);return{save:e}},__vite__mapDeps([27,25,1]),import.meta.url),{writeFile:r}=await t(async()=>{let{writeFile:e}=await import(`./dist-js-CQg21qYZ.js`);return{writeFile:e}},__vite__mapDeps([28,25,1,29]),import.meta.url),a=await e({defaultPath:n,filters:[{name:`PNG`,extensions:[`png`]}]});return a?(await r(a,new Uint8Array(await i.arrayBuffer())),!0):!1}let a=URL.createObjectURL(i);try{let e=document.createElement(`a`);e.href=a,e.download=n,e.click()}finally{URL.revokeObjectURL(a)}return!0}export{C as _,te as a,k as b,h as c,T as d,x as f,b as g,D as h,Q as i,p as l,E as m,se as n,g as o,O as p,le as r,m as s,ce as t,w as u,S as v,c as x,ee as y};
import{n as e}from"./rolldown-runtime-Dd_uD5pT.js";import{Yf as t,z as n}from"./api-B30rMKAw.js";var r=e({formatCsv:()=>i,formatSqlInsert:()=>o,formatTsv:()=>a});function i(e,n,r=`all`){return`${e.map(e=>t(e,r)).join(`,`)}\n${n.map(e=>e.map(e=>e===null?``:t(String(e),r)).join(`,`)).join(`
`)}`}function a(e,t){let n=e=>{let t=e===null?``:String(e);return t.includes(`	`)||t.includes(`
`)||t.includes(`\r`)||t.includes(`"`)?`"${t.replace(/"/g,`""`)}"`:t};return`${e.map(n).join(`	`)}\n${t.map(e=>e.map(n).join(`	`)).join(`
`)}`}function o(e){return n({...e,batchSize:1})}export{o as n,a as r,r as t};
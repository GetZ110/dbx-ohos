import{p as e}from"./jdbcDialect-BXk_Dihw.js";var t=`SELECT VERSION() AS VERSION FROM DUAL;`,n=`SELECT
  NODE_ID,
  RACK_NO,
  NODE_IP,
  NODE_PORT,
  NODE_TYPE,
  NODE_STATE,
  CPU_LOAD,
  BOOT_TIME,
  STORE_NUM,
  MAJOR_NUM
FROM SYS_CLUSTERS
ORDER BY NODE_ID;`,r=`SELECT
  NODEID,
  ACT_TRANS_NUM,
  DISK_R_N,
  DISK_R_BYTES,
  DISK_W_N,
  DISK_W_BYTES,
  MAX_TRANS_ID,
  MIN_TRANS_ID,
  XLOG_WPOS,
  XLOG_CKPT,
  FREE_STO_N
FROM SYS_ALL_RUN_INFO
ORDER BY NODEID;`,i=`SELECT NODEID AS NODE_ID,
       COUNT(*) AS SESSIONS,
       SUM(MEM_SIZE) AS MEMORY_BYTES
FROM SYS_ALL_SESSIONS
GROUP BY NODEID
ORDER BY NODEID;`,a=`SELECT T.NODEID AS NODE_ID,
       COUNT(*) AS ACTIVE_SESSIONS,
       MIN(S.CMD_START_T) AS OLDEST_STATEMENT
FROM SYS_ALL_THD_SESSION T
JOIN SYS_ALL_SESSIONS S
  ON T.NODEID = S.NODEID AND T.SESSION_ID = S.SESSION_ID
GROUP BY T.NODEID
ORDER BY T.NODEID;`,o=`SELECT NODEID AS NODE_ID,
       COUNT(*) AS ACTIVE_TRANSACTIONS,
       MIN(START_T) AS OLDEST_TRANSACTION
FROM SYS_ALL_TRANS
GROUP BY NODEID
ORDER BY NODEID;`,s=`SELECT
  (SELECT COUNT(*) FROM SYS_ALL_LWAITERS) AS LOCK_WAITS,
  (SELECT COUNT(*) FROM SYS_ALL_LOWNERS) AS LOCK_OWNERS
FROM DUAL;`,c=`SELECT NODEID AS NODE_ID,
       LOCK_LEVEL AS LOCK_MODE,
       COUNT(*) AS LOCKS
FROM SYS_ALL_LOWNERS
GROUP BY NODEID, LOCK_LEVEL
ORDER BY NODEID, LOCK_LEVEL;`,l=`SELECT NODEID AS NODE_ID,
       STATUS,
       COUNT(*) AS SESSIONS
FROM SYS_ALL_SESSIONS
GROUP BY NODEID, STATUS
ORDER BY NODEID, STATUS;`,u=`SELECT
  NODEID,
  BUFF_SIZE * TOTAL_BUFF_NUM AS BUFFER_TOTAL_BYTES,
  BUFF_SIZE * FREE_BUFF_NUM AS BUFFER_FREE_BYTES,
  BUFF_SIZE * DIRTY_BUFF_NUM AS BUFFER_DIRTY_BYTES,
  BUFF_SIZE * LRU_BUFF_NUM AS BUFFER_LRU_BYTES,
  SGA_BLK_SIZE * TOTAL_SGA_MEM AS SGA_TOTAL_BYTES,
  SGA_BLK_SIZE * FREE_SGA_MEM AS SGA_FREE_BYTES,
  SGA_BLK_SIZE * PEAK_SGA_MEM AS SGA_PEAK_BYTES,
  SWAP_BLK_SIZE * TOTAL_SWAP_MEM AS SWAP_TOTAL_BYTES,
  SWAP_BLK_SIZE * FREE_SWAP_MEM AS SWAP_FREE_BYTES
FROM SYS_ALL_MEM_STATUS
ORDER BY NODEID;`,d=`SELECT
  T.NODEID AS NODE_ID,
  T.SPACE_NAME,
  T.SPACE_TYPE,
  T.DATAFILE_NUM AS DATAFILES,
  T.MEDIA_ERROR,
  T.TOTAL_CHUNK_NUM * C.CHUNK_SIZE AS TOTAL_BYTES,
  T.FREE_CHUNK_NUM * C.CHUNK_SIZE AS FREE_BYTES
FROM SYS_ALL_TABLESPACES T, SYS_CTL_VARS C
ORDER BY T.NODEID, T.SPACE_NAME;`;function f(t){return!!t&&e(t)===`xugu`}function p(e){switch(Number(e)){case 1:return`joining`;case 2:return`running`;case 3:return`error`;case 4:return`offline`;default:return`unknown`}}function m(e){let t=Number(e);return!Number.isFinite(t)||t<=0?[]:[[1,`master`],[2,`standby`],[4,`storage`],[8,`query`],[16,`worker`],[32,`change`]].filter(([e])=>(t&e)===e).map(([,e])=>e)}function h(e){return e.rows.map(t=>({nodeId:T(e,t,`NODE_ID`),rackNo:T(e,t,`RACK_NO`),host:T(e,t,`NODE_IP`),port:T(e,t,`NODE_PORT`),nodeType:T(e,t,`NODE_TYPE`),state:T(e,t,`NODE_STATE`),cpuLoad:T(e,t,`CPU_LOAD`),bootTime:T(e,t,`BOOT_TIME`),storeCount:T(e,t,`STORE_NUM`),majorCount:T(e,t,`MAJOR_NUM`)}))}function g(e){return e.rows.map(t=>({nodeId:T(e,t,`NODEID`),activeTransactions:T(e,t,`ACT_TRANS_NUM`),diskReadCount:T(e,t,`DISK_R_N`),diskReadBytes:T(e,t,`DISK_R_BYTES`),diskWriteCount:T(e,t,`DISK_W_N`),diskWriteBytes:T(e,t,`DISK_W_BYTES`),maxTransactionId:T(e,t,`MAX_TRANS_ID`),minTransactionId:T(e,t,`MIN_TRANS_ID`),xlogWritePosition:T(e,t,`XLOG_WPOS`),xlogCheckpointPosition:T(e,t,`XLOG_CKPT`),freeStores:T(e,t,`FREE_STO_N`)}))}function _(e){return e.rows.map(t=>({nodeId:T(e,t,`NODE_ID`),sessions:T(e,t,`SESSIONS`),activeSessions:T(e,t,`ACTIVE_SESSIONS`),memoryBytes:T(e,t,`MEMORY_BYTES`),oldestStatement:T(e,t,`OLDEST_STATEMENT`)}))}function v(e){return e.rows.map(t=>({nodeId:T(e,t,`NODE_ID`),activeTransactions:T(e,t,`ACTIVE_TRANSACTIONS`),oldestTransaction:T(e,t,`OLDEST_TRANSACTION`)}))}function y(e){return e.rows.map(t=>({nodeId:T(e,t,`NODEID`),bufferTotalBytes:T(e,t,`BUFFER_TOTAL_BYTES`),bufferFreeBytes:T(e,t,`BUFFER_FREE_BYTES`),bufferDirtyBytes:T(e,t,`BUFFER_DIRTY_BYTES`),bufferLruBytes:T(e,t,`BUFFER_LRU_BYTES`),sgaTotalBytes:T(e,t,`SGA_TOTAL_BYTES`),sgaFreeBytes:T(e,t,`SGA_FREE_BYTES`),sgaPeakBytes:T(e,t,`SGA_PEAK_BYTES`),swapTotalBytes:T(e,t,`SWAP_TOTAL_BYTES`),swapFreeBytes:T(e,t,`SWAP_FREE_BYTES`)}))}function b(e){return e.rows.map(t=>({nodeId:T(e,t,`NODE_ID`),status:T(e,t,`STATUS`),sessions:T(e,t,`SESSIONS`)}))}function x(e){return e.rows.map(t=>({nodeId:T(e,t,`NODE_ID`),lockMode:T(e,t,`LOCK_MODE`),locks:T(e,t,`LOCKS`)}))}function S(e){return e.rows.map(t=>({nodeId:T(e,t,`NODE_ID`),spaceName:T(e,t,`SPACE_NAME`),spaceType:T(e,t,`SPACE_TYPE`),datafiles:T(e,t,`DATAFILES`),mediaError:T(e,t,`MEDIA_ERROR`),totalBytes:T(e,t,`TOTAL_BYTES`),freeBytes:T(e,t,`FREE_BYTES`)}))}function C(e,t){return e.rows.length>0?T(e,e.rows[0],t):``}function w(e){return C(e,`VERSION`)}function T(e,t,n){let r=e.columns.findIndex(e=>e.toUpperCase()===n.toUpperCase());return r<0||t[r]==null?``:String(t[r])}export{v as C,S,y as _,u as a,b,i as c,t as d,f,x as g,h,s as i,d as l,m,n,r as o,p,c as r,l as s,a as t,o as u,g as v,w,_ as x,C as y};
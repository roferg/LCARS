#!/usr/bin/env node
function arg(n,d){const i=process.argv.indexOf("--"+n);return i>=0&&process.argv[i+1]?process.argv[i+1]:d;}
const PORT=arg("devtools-port"),URL_=arg("url");
(async()=>{
 const l=await fetch("http://127.0.0.1:"+PORT+"/json/list").then(r=>r.json());
 const p=l.find(t=>t.type==="page"&&t.webSocketDebuggerUrl);
 const ws=new WebSocket(p.webSocketDebuggerUrl);let id=0;const w=new Map();
 const send=(m,q)=>new Promise(r=>{const i=++id;w.set(i,r);ws.send(JSON.stringify({id:i,method:m,params:q||{}}));});
 ws.addEventListener("message",e=>{const m=JSON.parse(e.data);if(m.id&&w.has(m.id)){w.get(m.id)(m);w.delete(m.id);}});
 await new Promise(r=>ws.addEventListener("open",r,{once:true}));
 const ev=async e=>{const r=await send("Runtime.evaluate",{expression:e,returnByValue:true,awaitPromise:true,timeout:180000});
   return JSON.stringify((r.result&&r.result.result&&r.result.result.value)||(r.result&&r.result.exceptionDetails)||r.result);};
 await send("Page.enable");await send("Runtime.enable");await send("Page.navigate",{url:URL_});
 for(let i=0;i<200;i++){if(/true/.test(await ev(`(function(){var f=document.getElementById("frontDoor");return !!f&&!f.hidden;})()`)))break;await new Promise(r=>setTimeout(r,200));}
 await new Promise(r=>setTimeout(r,800));
 console.log("SSE readyState: "+await ev(`(function(){try{return String(window.ES&&window.ES.readyState)}catch(e){return "n/a"}})()`));
 console.log("CONTROL /api/mission: "+await ev(`new Promise(function(res){var t=Date.now();
   postWrite("/api/mission",{idea:"control"},function(){res("onResult "+(Date.now()-t)+"ms");},function(m){res("onError "+(Date.now()-t)+"ms: "+m.slice(0,60));});
   setTimeout(function(){res("NEITHER after 20s");},20000);})`));
 console.log("RAW FETCH /api/vision/file: "+await ev(`new Promise(function(res){var t=Date.now();var stage="start";
   fetch("/api/vision/file",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({idea:"i",stack:"Vite + React + Vitest",slice:"importing a CSV row and showing it",deferred:["Budgets"],reasons:["r"]})})
    .then(function(r){stage="headers status="+r.status+" clen="+r.headers.get("content-length")+" enc="+r.headers.get("transfer-encoding")+" at "+(Date.now()-t)+"ms";
      return r.text();})
    .then(function(b){res(stage+" | body "+b.length+" bytes at "+(Date.now()-t)+"ms");})
    .catch(function(e){res(stage+" | REJECTED "+e.message+" at "+(Date.now()-t)+"ms");});
   setTimeout(function(){res("STUCK at ["+stage+"] after 90s");},90000);})`));
 process.exit(0);
})().catch(e=>{console.error("SKIP 77 "+e.message);process.exit(77);});

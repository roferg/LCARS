#!/usr/bin/env node
/* Why is frontDoorState left busy/stale after a successful file? Capture the
 * console + the exact postWrite outcome around the real ✓ Accept click. */
const fs=require("fs");
function arg(n,d){const i=process.argv.indexOf("--"+n);return i>=0&&process.argv[i+1]?process.argv[i+1]:d;}
const PORT=arg("devtools-port"),URL_=arg("url"),OUT=arg("out",".");
const REC=`(function(){frontDoorState.idea="a website that does personal finance stuff";
 frontDoorTurn({sessionId:"abc123",recommendation:{stack:"Vite + React + Vitest",
 reasons:["r1","r2"],slice:"importing a CSV row and showing it",deferred:["Budgets"]}});
 return frontDoorState.screen;})()`;
(async()=>{
 const l=await fetch("http://127.0.0.1:"+PORT+"/json/list").then(r=>r.json());
 const p=l.find(t=>t.type==="page"&&t.webSocketDebuggerUrl);
 const ws=new WebSocket(p.webSocketDebuggerUrl);let id=0;const w=new Map();const logs=[];
 const send=(m,q)=>new Promise(r=>{const i=++id;w.set(i,r);ws.send(JSON.stringify({id:i,method:m,params:q||{}}));});
 ws.addEventListener("message",e=>{const m=JSON.parse(e.data);
  if(m.method==="Runtime.consoleAPICalled"||m.method==="Runtime.exceptionThrown")logs.push(JSON.stringify(m.params).slice(0,600));
  if(m.id&&w.has(m.id)){w.get(m.id)(m);w.delete(m.id);}});
 await new Promise(r=>ws.addEventListener("open",r,{once:true}));
 const ev=async e=>{const r=await send("Runtime.evaluate",{expression:e,returnByValue:true,awaitPromise:true});
   return r.result&&r.result.result&&r.result.result.value;};
 await send("Page.enable");await send("Runtime.enable");await send("Page.navigate",{url:URL_});
 for(let i=0;i<200;i++){if(await ev(`(function(){var f=document.getElementById("frontDoor");return !!f&&!f.hidden;})()`))break;await new Promise(r=>setTimeout(r,200));}
 await new Promise(r=>setTimeout(r,800));
 console.log("stub rec -> "+await ev(REC));
 await new Promise(r=>setTimeout(r,400));
 // instrument: wrap the success callback path
 console.log("patch: "+await ev(`(function(){window.__fdReset=0;var of=frontDoorFile;
   window.__origPostWrite=postWrite;postWrite=function(p,pl,ok,er){return window.__origPostWrite(p,pl,
     function(s){window.__fdReset++;window.__fdOkPath=p;return ok&&ok(s);},
     function(m,d){window.__fdErr=(m||"")+" | "+JSON.stringify(d||{});return er&&er(m,d);});};return "wrapped";})()`));
 console.log("click: "+await ev(`(function(){var b=[].slice.call(document.querySelectorAll("#frontDoor button")).filter(function(x){return /Accept & file/.test(x.textContent||"");})[0];if(!b)return "NO BTN";b.click();return "clicked";})()`));
 await new Promise(r=>setTimeout(r,110000));
 console.log("RESULT: "+await ev(`JSON.stringify({okCallbacks:window.__fdReset,okPath:window.__fdOkPath,err:window.__fdErr||null,
   screen:frontDoorState.screen,busy:frontDoorState.busy,error:frontDoorState.error,
   hidden:!!document.getElementById("frontDoor").hidden,cards:document.querySelectorAll(".card").length})`));
 fs.writeFileSync(OUT+"/console.log",logs.join("\n"));
 process.exit(0);
})().catch(e=>{console.error("SKIP 77 "+e.message);process.exit(77);});

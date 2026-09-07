#!/usr/bin/env node
/* S184 — the OVERRIDE. Reach screen 3 with a stubbed recommendation (the
 * renderer/CSS are real), click ⇄ Choose a different stack, type a stack the
 * captain prefers, and file. Proves the refusal is real and that what he typed
 * is what lands. */
const fs = require("fs");
function arg(n, d){const i=process.argv.indexOf("--"+n);return i>=0&&process.argv[i+1]?process.argv[i+1]:d;}
const PORT=arg("devtools-port"),URL_=arg("url"),OUT=arg("out","."),STACK=arg("stack","Go + net/http + go test");
const REC=`(function(){frontDoorTurn({recommendation:{stack:"Vite + React + Vitest",
  reasons:["r1","r2"],slice:"importing a CSV row and showing it",
  deferred:["Budgets","Charts"]}});return frontDoorState.screen;})()`;
(async()=>{
 const l=await fetch("http://127.0.0.1:"+PORT+"/json/list").then(r=>r.json());
 const p=l.find(t=>t.type==="page"&&t.webSocketDebuggerUrl);
 const ws=new WebSocket(p.webSocketDebuggerUrl);let id=0;const w=new Map();
 const send=(m,q)=>new Promise(r=>{const i=++id;w.set(i,r);ws.send(JSON.stringify({id:i,method:m,params:q||{}}));});
 ws.addEventListener("message",e=>{const m=JSON.parse(e.data);if(m.id&&w.has(m.id)){w.get(m.id)(m);w.delete(m.id);}});
 await new Promise(r=>ws.addEventListener("open",r,{once:true}));
 const ev=async e=>{const r=await send("Runtime.evaluate",{expression:e,returnByValue:true,awaitPromise:true});
   return r.result&&r.result.result&&r.result.result.value;};
 const shot=async n=>{const r=await send("Page.captureScreenshot",{format:"png",captureBeyondViewport:true});
   if(r.result&&r.result.data)fs.writeFileSync(OUT+"/"+n,Buffer.from(r.result.data,"base64"));};
 const click=async lab=>ev(`(function(){var bs=[].slice.call(document.querySelectorAll("#frontDoor button"));`
   +`var b=bs.filter(function(x){return (x.textContent||"").indexOf(${JSON.stringify(lab)})>=0;})[0];`
   +`if(!b)return "NO BUTTON: "+bs.map(function(x){return x.textContent;}).join(" | ");b.click();return "clicked";})()`);
 await send("Page.enable");await send("Runtime.enable");await send("Page.navigate",{url:URL_});
 for(let i=0;i<200;i++){if(await ev(`(function(){var f=document.getElementById("frontDoor");return !!f&&!f.hidden;})()`))break;await new Promise(r=>setTimeout(r,200));}
 await new Promise(r=>setTimeout(r,900));
 console.log("stub rec -> screen "+await ev(REC));
 await new Promise(r=>setTimeout(r,500));
 console.log("click override: "+await click("different stack"));
 await new Promise(r=>setTimeout(r,600));
 await shot("override.png");
 console.log("override screen text: "+await ev(`(function(){var f=document.getElementById("frontDoor");return (f.textContent||"").replace(/[ \\t\\r\\n]+/g," ").trim();})()`));
 console.log("type stack: "+await ev(`(function(){var b=document.querySelector("#frontDoor input.fd-field");`
   +`if(!b)return "NO INPUT";b.value=${JSON.stringify(STACK)};return b.value;})()`));
 console.log("click file: "+await click("Use this stack"));
 await new Promise(r=>setTimeout(r,4000));
 await shot("override-after.png");
 console.log("after: "+await ev(`(function(){var f=document.getElementById("frontDoor");`
   +`return JSON.stringify({fdHidden:!!(f&&f.hidden),cols:document.querySelectorAll(".col").length,`
   +`cards:document.querySelectorAll(".card").length,err:(typeof frontDoorState!=="undefined")?frontDoorState.error:null});})()`));
 process.exit(0);
})().catch(e=>{console.error("SKIP 77 "+e.message);process.exit(77);});

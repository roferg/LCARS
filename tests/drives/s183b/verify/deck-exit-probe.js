/* S183 verify — on a HEALTHY repo, can you LEAVE the holodeck again?
 * Enters the deck via #holodeckBtn, then clicks the same control (now "Board")
 * and measures that the Kanban board comes back. */
const fs = require("fs"); const http = require("http");
function arg(n,d){const i=process.argv.indexOf("--"+n);return i>-1?process.argv[i+1]:d;}
const PORT=arg("devtools-port"), URL_=arg("url"), OUT=arg("out");
function json(p){return new Promise((res,rej)=>{http.get({host:"127.0.0.1",port:PORT,path:p},r=>{let b="";r.on("data",c=>b+=c);r.on("end",()=>{try{res(JSON.parse(b))}catch(e){rej(e)}})}).on("error",rej)})}
const SNAP=`(function(){
  var b=document.getElementById("holodeckBtn");
  var board=document.getElementById("board");
  return { btnText: b?(b.textContent||"").trim():"<none>",
           btnDisabled: b?!!b.disabled:null,
           boardDisplay: board?getComputedStyle(board).display:"<none>",
           cards: document.querySelectorAll(".card").length,
           holoVisible: !!document.querySelector(".holo,#holodeck,.deck,.holo-wrap,#holodeckView"),
           head: (document.body.innerText||"").replace(/[\\s]+/g," ").trim().slice(0,180) };
})()`;
(async()=>{
  const t=(await json("/json/list")).find(x=>x.type==="page"&&x.webSocketDebuggerUrl);
  if(!t){console.error("no page");process.exit(77);}
  const ws=new WebSocket(t.webSocketDebuggerUrl); let id=0; const w=new Map();
  const send=(m,p)=>new Promise(r=>{const i=++id;w.set(i,r);ws.send(JSON.stringify({id:i,method:m,params:p||{}}))});
  ws.addEventListener("message",e=>{const m=JSON.parse(e.data); if(m.id&&w.has(m.id)){w.get(m.id)(m);w.delete(m.id);}});
  await new Promise(r=>ws.addEventListener("open",r,{once:true}));
  const ev=async x=>{const r=await send("Runtime.evaluate",{expression:x,returnByValue:true,awaitPromise:true});return r.result&&r.result.result&&r.result.result.value;};
  const shot=async n=>{const r=await send("Page.captureScreenshot",{format:"png"});if(r.result&&r.result.data)fs.writeFileSync(OUT+"/"+n,Buffer.from(r.result.data,"base64"));};
  await send("Page.enable"); await send("Runtime.enable");
  await send("Page.navigate",{url:URL_});
  const dl=Date.now()+25000; let ok=false;
  while(Date.now()<dl){ try{ok=await ev(`!!document.getElementById("holodeckBtn")`);}catch(e){ok=false;} if(ok)break; await new Promise(r=>setTimeout(r,200)); }
  if(!ok){console.error("never painted");process.exit(1);}
  await new Promise(r=>setTimeout(r,1500));
  const before=await ev(SNAP);
  await ev(`document.getElementById("holodeckBtn").click()`);
  await new Promise(r=>setTimeout(r,1500));
  const inside=await ev(SNAP); await shot("inside-deck.png");
  await ev(`document.getElementById("holodeckBtn").click()`);
  await new Promise(r=>setTimeout(r,1500));
  const back=await ev(SNAP); await shot("back-on-board.png");
  /* and the ESC / hash route out */
  const hash=await ev(`location.hash`);
  const out={before,inside,back,hash};
  fs.writeFileSync(OUT+"/deck-exit.json",JSON.stringify(out,null,2));
  console.log(JSON.stringify(out,null,2)); process.exit(0);
})().catch(e=>{console.error("PROBE ERROR "+e.message);process.exit(77)});

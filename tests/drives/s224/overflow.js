#!/usr/bin/env node
/* Which element is actually wider than the 400px window? Names the WIDEST
 * offenders, deepest-first, so an overflow is attributed rather than guessed.
 *   node overflow.js --devtools-port N --url URL --mission ID
 */
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
function arg(n, d) { const i = process.argv.indexOf("--" + n); return i > 0 ? process.argv[i + 1] : d; }
const PORT = arg("devtools-port"), URL = arg("url"), MID = arg("mission");
class CDP {
  constructor(ws) { this.ws = ws; this.next = 1; this.pending = new Map();
    ws.addEventListener("message", (ev) => { let m; try { m = JSON.parse(ev.data); } catch (e) { return; }
      if (m.id && this.pending.has(m.id)) { const p = this.pending.get(m.id); this.pending.delete(m.id);
        m.error ? p.reject(new Error(JSON.stringify(m.error))) : p.resolve(m.result); } }); }
  send(method, params, sid) { const id = this.next++; const pl = { id, method, params: params || {} };
    if (sid) pl.sessionId = sid; this.ws.send(JSON.stringify(pl));
    return new Promise((res, rej) => this.pending.set(id, { resolve: res, reject: rej })); } }
const connect = (u) => new Promise((res, rej) => { const ws = new WebSocket(u);
  ws.addEventListener("open", () => res(ws), { once: true });
  ws.addEventListener("error", () => rej(new Error("ws refused")), { once: true }); });
let cdp, sid;
async function ev(e) { const r = await cdp.send("Runtime.evaluate", { expression: e, returnByValue: true, awaitPromise: true }, sid); return r && r.result ? r.result.value : null; }
async function waitFor(e, ms) { const dl = Date.now() + (ms || 20000); while (Date.now() < dl) { try { if (await ev(e)) return true; } catch (x) {} await sleep(120); } return false; }
(async () => {
  let ver = null, dl = Date.now() + 20000;
  while (Date.now() < dl) { try { const r = await fetch("http://127.0.0.1:" + PORT + "/json/version"); if (r.ok) { ver = await r.json(); break; } } catch (e) {} await sleep(120); }
  cdp = new CDP(await connect(ver.webSocketDebuggerUrl));
  const t = await cdp.send("Target.createTarget", { url: "about:blank" });
  sid = (await cdp.send("Target.attachToTarget", { targetId: t.targetId, flatten: true })).sessionId;
  await cdp.send("Page.enable", {}, sid); await cdp.send("Runtime.enable", {}, sid);
  await cdp.send("Emulation.setDeviceMetricsOverride", { width: 400, height: 900, deviceScaleFactor: 1, mobile: true }, sid);
  await cdp.send("Page.navigate", { url: URL }, sid);
  await waitFor(`!!document.querySelector('.card[data-mid=${JSON.stringify(MID)}]')`, 30000);
  await sleep(500);
  if (MID) {
    await ev(`(function(){var c=document.querySelector('.card[data-mid=${JSON.stringify(MID)}]');var b=c&&c.querySelector('.xo-read-report');if(b){b.click();return true}return false})()`);
    await waitFor(`!!document.querySelector('.xo-pane .xo-verdict')`, 20000);
    await sleep(600);
  }
  const res = await ev(`(function(){
    var w=document.documentElement.clientWidth, bad=[];
    var all=document.querySelectorAll('*');
    for (var i=0;i<all.length;i++){
      var e=all[i], b=e.getBoundingClientRect();
      if (b.width<=0 && b.height<=0) continue;
      if (b.right > w + 1) {
        bad.push({sel:(e.tagName.toLowerCase()+'.'+String(e.className||'').split(' ').slice(0,3).join('.')),
                  right:Math.round(b.right), width:Math.round(b.width),
                  inPane: !!e.closest('.xo-pane'), depth: (function(){var d=0,p=e;while(p){d++;p=p.parentElement}return d})()});
      }
    }
    bad.sort(function(a,b){return b.right-a.right});
    return {scrollW:document.documentElement.scrollWidth, clientW:w, n:bad.length, top:bad.slice(0,18)};
  })()`);
  console.log(JSON.stringify(res, null, 1));
  process.exit(0);
})().catch((e) => { console.error(e); process.exit(70); });

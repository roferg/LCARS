#!/usr/bin/env node
/* S196 tester — median painted colour + WCAG contrast between two PNG crops.
 * PNG reader and the luminance maths lifted from tests/drives/s190/owner-paint.js. */
const fs=require("fs"), zlib=require("zlib");
function pngPixels(buf){
  if(buf.length<8||buf.readUInt32BE(0)!==0x89504e47) throw new Error("not a PNG");
  let off=8,w=0,h=0,depth=0,ctype=-1,interlace=0; const idat=[];
  while(off+8<=buf.length){const len=buf.readUInt32BE(off);const type=buf.toString("ascii",off+4,off+8);
    const data=buf.slice(off+8,off+8+len);
    if(type==="IHDR"){w=data.readUInt32BE(0);h=data.readUInt32BE(4);depth=data[8];ctype=data[9];interlace=data[12];}
    else if(type==="IDAT")idat.push(data); else if(type==="IEND")break; off+=12+len;}
  if(depth!==8||interlace!==0||(ctype!==2&&ctype!==6)) throw new Error("unsupported PNG");
  const bpp=ctype===6?4:3, stride=w*bpp;
  const raw=zlib.inflateSync(Buffer.concat(idat)); const out=Buffer.alloc(h*stride);
  for(let y=0;y<h;y++){const ft=raw[y*(stride+1)];const line=raw.slice(y*(stride+1)+1,y*(stride+1)+1+stride);
    const cur=out.slice(y*stride,(y+1)*stride);
    for(let x=0;x<stride;x++){const a=x>=bpp?cur[x-bpp]:0;const b=y>0?out[(y-1)*stride+x]:0;
      const c=(x>=bpp&&y>0)?out[(y-1)*stride+x-bpp]:0;let v=line[x];
      if(ft===1)v+=a;else if(ft===2)v+=b;else if(ft===3)v+=(a+b)>>1;
      else if(ft===4){const p=a+b-c,pa=Math.abs(p-a),pb=Math.abs(p-b),pc=Math.abs(p-c);
        v+=(pa<=pb&&pa<=pc)?a:(pb<=pc?b:c);} else if(ft!==0)throw new Error("filter "+ft);
      cur[x]=v&0xff;}}
  return {w,h,bpp,px:out};
}
const f=(c)=>{c/=255;return c<=0.03928?c/12.92:Math.pow((c+0.055)/1.055,2.4);};
const lum=(r,g,b)=>0.2126*f(r)+0.7152*f(g)+0.0722*f(b);
const contrast=(a,b)=>{const la=lum(...a),lb=lum(...b);return (Math.max(la,lb)+0.05)/(Math.min(la,lb)+0.05);};
function stats(p){const n=p.w*p.h;const rows=[];
  for(let i=0;i<n;i++){const o=i*p.bpp;rows.push([lum(p.px[o],p.px[o+1],p.px[o+2]),p.px[o],p.px[o+1],p.px[o+2]]);}
  rows.sort((a,b)=>a[0]-b[0]);
  const at=(q)=>rows[Math.min(n-1,Math.max(0,Math.floor(q*(n-1))))];
  const m=at(0.5), lo=at(0.04), hi=at(0.96);
  return {median:[m[1],m[2],m[3]], p04:[lo[1],lo[2],lo[3]], p96:[hi[1],hi[2],hi[3]],
          inkPaper:+contrast([lo[1],lo[2],lo[3]],[hi[1],hi[2],hi[3]]).toFixed(2)};
}
const files=process.argv.slice(2);
const out=files.map(fp=>({file:fp, ...stats(pngPixels(fs.readFileSync(fp)))}));
out.forEach(o=>console.log(o.file, "median rgb("+o.median+")", "ink/paper", o.inkPaper));
if(out.length===2) console.log("SEPARATION between the two medians:", contrast(out[0].median,out[1].median).toFixed(2)+":1");

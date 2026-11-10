// node prepara_voce.mjs /percorso/rhubarb-lip-sync-wasm/package audio.wav output.json
// WASM 0.1.8; riconoscimento approssimato, non allineamento fonetico italiano certificato.
import fs from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {spawnSync} from 'node:child_process';
import assert from 'node:assert/strict';

export function normalize(cues) {
  const sorted=cues.map(c=>({...c})).sort((a,b)=>a.start-b.start);
  const out=[];
  for(let i=0;i<sorted.length;i++) {
    const c=sorted[i];
    assert(Number.isFinite(c.start)&&Number.isFinite(c.end)&&c.start>=0&&c.end>c.start);
    assert(/^[A-HX]$/.test(c.value));
    // The WASM recognizer can emit overlapping cues: the later onset wins.
    c.end=Math.min(c.end,sorted[i+1]?.start??c.end);
    if(c.end<=c.start) continue;
    const last=out.at(-1);
    if(last?.value===c.value&&Math.abs(last.end-c.start)<0.001)last.end=c.end;
    else out.push(c);
  }
  return out;
}
if(process.argv.includes('--check')) {
  assert.deepEqual(normalize([{start:0,end:.3,value:'B'},{start:.2,end:.4,value:'B'},{start:.4,end:.5,value:'X'}]),[{start:0,end:.4,value:'B'},{start:.4,end:.5,value:'X'}]);
  assert.throws(()=>normalize([{start:1,end:0,value:'A'}]));
  console.log('Normalizzazione cue: OK');
} else {
  const [pkg,input,output]=process.argv.slice(2);
  assert(pkg&&input&&output,'Passare package WASM, WAV e percorso JSON di uscita.');
  const converted=spawnSync('ffmpeg',['-v','error','-i',input,'-ar','16000','-ac','1','-f','s16le','pipe:1'],{maxBuffer:64*1024*1024});
  assert.equal(converted.status,0,converted.stderr?.toString());
  const {Rhubarb}=await import(pathToFileURL(path.resolve(pkg,'dist/index.js')));
  const raw=await Rhubarb.getLipSync(converted.stdout);
  const result={metadata:{generator:'rhubarb-lip-sync-wasm 0.1.8',duration:converted.stdout.length/32000,method:'PocketSphinx phone recognition; italiano approssimato; sovrapposizioni risolte per onset',rawCueCount:raw.mouthCues.length},mouthCues:normalize(raw.mouthCues)};
  fs.writeFileSync(output,JSON.stringify(result,null,2));
  console.log(`${result.mouthCues.length} cue salvate: ${output}`);
}

import fs from 'node:fs';
import os from 'node:os';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import * as base from '../artifacts/base.js';
import * as head from '../artifacts/head.js';
const root=new URL('../',import.meta.url), path=p=>new URL(p,root);
const hash=value=>createHash('sha256').update(value).digest('hex');
const json=p=>JSON.parse(fs.readFileSync(path(p),'utf8'));
const config=json('config.json'), lock=json('lock.json');
assert.equal(process.version,lock.node);
const lanes={base,head};
const n=config.measuredPairs,warm=config.warmupPairs,size=config.baseScalars,pos=config.insertPosition;
const seed=config.seedAlphabet.repeat(Math.ceil(size/config.seedAlphabet.length)).slice(0,size);
let sink=0;
function read(api,id){const text=api.read(id);let checksum=0;for(let i=0;i<text.length;i++)checksum=(checksum+text.charCodeAt(i))>>>0;sink=(sink^checksum)>>>0;return {text,checksum};}
function apply(api,id,packet){const report=JSON.parse(api.apply(id,packet));assert.equal(report.error,undefined);return report;}
function assertReport(report,count){assert.equal(report.applied,count);assert.equal(report.duplicates,0);assert.equal(report.pending,0);}
function restore(api,writer){const id=api.create(writer);assertReport(apply(api,id,fixture),size);assert.equal(api.pending(id),0);assert.equal(api.can_undo(id),false);assert.equal(api.history(id),fixture);assert.equal(api.version(id),seedVersion);assert.deepEqual(read(api,id),seedRead);return id;}
function stats(samples){const s=[...samples].sort((a,b)=>a-b);return {n:s.length,medianMs:s.length%2?s[s.length>>1]:(s[s.length/2-1]+s[s.length/2])/2,p95Ms:s[Math.ceil(s.length*.95)-1],maxMs:s.at(-1),minMs:s[0],samplesMs:samples};}
function verifyEffects(before,report,expected){if(report.availability!=='exact')return;let chars=Array.from(before);for(const effect of report.effects){if(effect.kind==='insert')chars.splice(effect.pos,0,...Array.from(effect.text));else if(effect.kind==='delete')chars.splice(effect.start,effect.end-effect.start);else assert.fail('Unknown effect');}assert.equal(chars.join(''),expected);}
const startedAt=new Date().toISOString();
const seedDocs=Object.entries(lanes).map(([name,api])=>{const id=api.create(config.seedWriter);assert.equal(api.edit_raw(id,0,0,seed),'ok');return [name,api,id];});
const fixture=base.history(seedDocs[0][2]),seedVersion=base.version(seedDocs[0][2]),seedRead=read(base,seedDocs[0][2]);
assert.equal(JSON.parse(fixture).operations.length,size);assert.equal(seedRead.text,seed);
for(const [name,api,id] of seedDocs){assert.equal(api.history(id),fixture);assert.equal(api.version(id),seedVersion);assert.deepEqual(read(api,id),seedRead);api.release(id);}
fs.mkdirSync(path('results'),{recursive:true});
fs.writeFileSync(path('results/fixture.json'),fixture);
const out={schema:1,startedAt,finishedAt:null,status:'running',config,source:lock.sources,provenance:{runtime:process.version,v8:process.versions.v8,nodeVersions:process.versions,execArgv:process.execArgv,platform:process.platform,arch:process.arch,osRelease:os.release(),cpu:os.cpus()[0]?.model,logicalCpus:os.cpus().length,availableParallelism:os.availableParallelism(),memoryBytes:os.totalmem(),loadavgAtStart:os.loadavg(),hostname:os.hostname()},hashes:{harnessSha256:hash(fs.readFileSync(fileURLToPath(import.meta.url))),configSha256:hash(fs.readFileSync(path('config.json'))),lockSha256:hash(fs.readFileSync(path('lock.json'))),baseBinarySha256:hash(fs.readFileSync(path('artifacts/base.js'))),headBinarySha256:hash(fs.readFileSync(path('artifacts/head.js'))),fixtureSha256:hash(fixture),seedTextSha256:hash(seed)},timing:{clock:'performance.now; one contiguous synchronous interval per operation',included:['JSON decode, whole-packet validation/admission, transition.finish, effect serialization and report parse for receive','UndoManager.undo for Undo','first post-mutation public TextState.text() getter','full UTF-16 checksum on returned text'],excluded:['source builds','fixture generation','fresh receiver create/import, history/Version equality checks and pre-mutation text warming','remote sender edits and delta export','Undo paste and pre-Undo text warming','post-timer exact content/history/Version/effects/count checks','release/cleanup'],notMeasured:['browser/editor/render/paint','mobile','network','IndexedDB','cold projection','wasm/wasm-gc/native','growing history or long-running sessions','real documents','memory/energy'],warmState:'fresh imported 10k-op receiver per lane per pair, pre-read once before target change; post-change text is first read inside timer',pairing:'identical deterministic actor IDs/seed/history/packet and fresh restored receivers; AB/BA alternating; no forced GC; no dropped samples'},rows:[],sink:0};
function save(){out.sink=sink;fs.writeFileSync(path('results/benchmark.json'),JSON.stringify(out,null,2)+'\n');}
for(const count of [...config.remoteCases,'undo']){
  const scenario=count==='undo'?'undo1000-first-full-text':`receive${count}-first-full-text`;
  const isUndo=count==='undo',operationCount=isUndo?config.undoPasteScalars:count;
  const expectedText=isUndo?seed:seed.slice(0,pos)+Array.from({length:count},(_,i)=>String.fromCharCode(65+i%26)).join('')+seed.slice(pos);
  let expectedHistory=null,expectedVersion=null,packet=null;
  if(!isUndo){
    for(const [name,api] of Object.entries(lanes)){
      const id=restore(api,config.senderWriter),before=api.version(id);
      for(let j=0;j<count;j++)assert.equal(api.edit_raw(id,pos+j,pos+j,String.fromCharCode(65+j%26)),'ok');
      const delta=api.delta(id,before),history=api.history(id),version=api.version(id);
      assert.equal(JSON.parse(delta).operations.length,count);assert.equal(JSON.parse(history).operations.length,size+count);assert.equal(read(api,id).text,expectedText);
      if(packet===null){packet=delta;expectedHistory=history;expectedVersion=version;}else{assert.equal(delta,packet);assert.equal(history,expectedHistory);assert.equal(version,expectedVersion);}
      api.release(id);
    }
    fs.writeFileSync(path(`results/packet-${count}.json`),packet);
  }
  const row={scenario,baseScalars:size,seedOperations:size,changedOperations:operationCount,warmupPairs:warm,measuredPairs:n,packetBytes:packet?Buffer.byteLength(packet):null,packetSha256:packet?hash(packet):null,expectedTextSha256:hash(expectedText),samples:{base:[],head:[]},warmup:[],pairs:[],availabilities:{base:{},head:{}},checks:{allPairsExactText:true,allPairsExactHistoryBytes:true,allPairsExactVersionBytes:true,allPairsOperationCount:true,allPairsPendingZero:true,allExactEffectsReconstructText:true,freshReceiverEverySample:true,preMutationTextRead:true,undoSingleLocalGroup:isUndo?true:null}};
  const setupDurations=[];
  for(let i=0;i<warm+n;i++){
    const order=i%2?['head','base']:['base','head'];
    const ids={},setupStart=performance.now();
    for(const name of order){const api=lanes[name],id=restore(api,isUndo?config.undoWriter:config.receiverWriter);ids[name]=id;if(isUndo){assert.equal(api.edit(id,pos,pos,'P'.repeat(operationCount),1),'ok');assert.equal(api.can_undo(id),true);assert.equal(read(api,id).text,seed.slice(0,pos)+'P'.repeat(operationCount)+seed.slice(pos));assert.equal(JSON.parse(api.history(id)).operations.length,size+operationCount);}}
    assert.equal(base.history(ids.base),head.history(ids.head));assert.equal(base.version(ids.base),head.version(ids.head));
    setupDurations.push(performance.now()-setupStart);
    const pair={index:i,phase:i<warm?'warmup':'measured',order,startedAt:new Date().toISOString(),durationMs:{},checks:{}};
    const actual={};
    for(const name of order){const api=lanes[name],id=ids[name];const start=performance.now();const report=isUndo?api.undo(id):apply(api,id,packet);const result=read(api,id);const elapsed=performance.now()-start;pair.durationMs[name]=elapsed;actual[name]={report,result};if(i>=warm)row.samples[name].push(elapsed);}
    for(const name of order){const api=lanes[name],id=ids[name],{report,result}=actual[name];assert.equal(result.text,expectedText);assert.equal(api.length(id),expectedText.length);assert.equal(api.pending(id),0);if(isUndo){assert.equal(report,true);assert.equal(api.can_undo(id),false);}else{assertReport(report,count);verifyEffects(seed,report,expectedText);assert.equal(api.history(id),expectedHistory);assert.equal(api.version(id),expectedVersion);row.availabilities[name][report.availability]=(row.availabilities[name][report.availability]||0)+1;}}
    const history=base.history(ids.base),version=base.version(ids.base),historyCount=JSON.parse(history).operations.length;
    assert.equal(head.history(ids.head),history);assert.equal(head.version(ids.head),version);assert.deepEqual(actual.base.result,actual.head.result);assert.equal(historyCount,size+(isUndo?2*operationCount:operationCount));
    if(isUndo){if(expectedHistory===null){expectedHistory=history;expectedVersion=version;}else{assert.equal(history,expectedHistory);assert.equal(version,expectedVersion);}}
    pair.checks={resultChecksum:actual.base.result.checksum,historySha256:hash(history),versionSha256:hash(version),historyOperations:historyCount,baseAvailability:isUndo?'undo-true':actual.base.report.availability,headAvailability:isUndo?'undo-true':actual.head.report.availability};
    (i<warm?row.warmup:row.pairs).push(pair);
    for(const name of order)lanes[name].release(ids[name]);
  }
  row.base=stats(row.samples.base);row.head=stats(row.samples.head);delete row.samples;
  row.baseToHeadMedianRatio=row.base.medianMs/row.head.medianMs;
  {const s=stats(row.pairs.map(p=>p.durationMs.base/p.durationMs.head));row.pairedRatios={n:s.n,medianRatio:s.medianMs,p95Ratio:s.p95Ms,maxRatio:s.maxMs,minRatio:s.minMs,samplesRatios:s.samplesMs};}
  row.setupPairDurationMs=stats(setupDurations);
  row.expectedHistorySha256=hash(expectedHistory);row.expectedVersionSha256=hash(expectedVersion);
  out.rows.push(row);save();console.log(JSON.stringify({scenario,base:row.base,head:row.head,baseToHeadMedianRatio:row.baseToHeadMedianRatio},(key,value)=>key==='samplesMs'?undefined:value));
}
out.finishedAt=new Date().toISOString();out.status='complete';out.provenance.loadavgAtEnd=os.loadavg();save();
console.log(`All ${out.rows.length*(warm+n)} pairs passed exact checks; sink=${sink}`);

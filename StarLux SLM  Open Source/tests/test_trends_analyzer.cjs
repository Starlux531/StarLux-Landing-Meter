const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const {webcrypto}=require('node:crypto');
const html=fs.readFileSync(path.resolve('LMM_Log/LMM_Trends_Analyzer.html'),'utf8');
const code=html.match(/<script id="trend-core" type="text\/plain">([\s\S]*?)<\/script>/)[1];
const context=vm.createContext({crypto:webcrypto,TextEncoder,TextDecoder});vm.runInContext(code,context);
function fixture({date='2026-09-01 12:00:00',aircraft='A20N',cross=5,zh=false,full=false,gap=false}={}){
  const head=zh?['StarLux 落地率插件 v1.1.8 - 单次落地记录',`落地时间（本地时间）: ${date}`,'最终评价: Stable 稳定扎实落地','触地垂直速度: -120 fpm','最终过载: 1.3 G',`机型（ICAO）: ${aircraft}`,'落地机场: TEST','触地跑道方向: RWY09',`触地点中心线有符号偏差: ${cross} m`,'首次接地 T+秒: 10','100 ft 至触地时间: 10 s','发动机数量: 2']:
  ['StarLux LMM v1.1.8 - Landing Report',`Landing time (local): ${date}`,'Final rating: Stable','Touchdown vertical speed: -120 fpm','Final load: 1.3 G',`Aircraft (ICAO): ${aircraft}`,'Landing airport: TEST','Touchdown runway: RWY09',`Signed touchdown centerline deviation: ${cross} m`,'First touchdown T+s: 10','100 ft to touchdown time: 10 s','Engine count: 2'];
  head.push('Aggregated trajectory table','T+ RA FPM VVI IAS GS Pitch AoA Roll PhysicalFPM G Ground');
  for(let i=0;i<=40;i++){const t=i/4;head.push([t,100-10*t,-100,-150,130,140,3,4,Math.sin(t),-140,1,t===10?1:0].join(' '))}
  head.push('','0.10 s control response table','T+ PitchIn RollIn YawIn Elevator1 Elevator2 Aileron1 Aileron2 Rudder1 Rudder2 Throttle1 Throttle2 N11 N12 N13 N14 Detent1 Detent2 Detent3 Detent4 DetentMode');
  for(let i=0;i<=100;i++){if(gap&&i>=73&&i<79)continue;const t=i/10;head.push([t,.1,Math.sin(t)*.2,0,1,1,1,1,0,0,t>=7?.04:.4,t>=7?.04:.4,45,45,'NA','NA','NA','NA','NA','NA',0].join(' '))}
  head.push('');
  if(full){head[0]='StarLux LMM v1.1.9-beta7 - Landing Report';head.push('LMM_RECORDING_BEGIN\t1','FIELDS\tT\tt\tagl\tvvi\tphysical_fpm\tground\tthrottle1\tthrottle2\troll_input\tpitch_input\tengine_count','META\tstart_time\t100','META\ttouch_time\t110','META\tphase\tCOMPLETE','META\tfront_missing\t1');for(let i=0;i<=120;i++){const t=i/10;head.push(['T',100+t,Math.max(0,100-10*t),-150,-140,t<10?0:1,t>=7?.04:.4,t>=7?.04:.4,Math.sin(t)*.2,.1,2].join('\t'))}head.push('LMM_RECORDING_END\t1\t121')}
  return head.join('\n');
}
async function run(){
  const r=context.parseTrend('LMM_old.txt',fixture().replace(/\n/g,'\r\r\n'));assert.equal(r.aircraft,'A20N');assert.equal(r.samples,41);assert.equal(r.controlSamples,101);assert.equal(r.fpm,-120);assert.equal(r.lowT,-3);assert.equal(r.lowHeight,30);assert.equal(r.lowChannels,2);assert.equal(r.rollChanges,3);assert.equal(r.absCross,5);
  const newer=context.parseTrend('LMM_new.txt',fixture({full:true}));assert(newer.full);assert.equal(newer.samples,121);assert.equal(newer.lowT,-3);assert.equal(newer.lowHeight,30);assert.equal(newer.heightBasis,'terrain');
  const gap=context.parseTrend('LMM_gap.txt',fixture({gap:true}));assert.equal(gap.lowT,null);assert.equal(gap.rollChanges,null);
  const missing=context.parseTrend('LMM_summary.txt','StarLux LMM v1.1.3\nFinal rating: NICE\nTouchdown vertical speed: -80\nFinal load: 1.12\nAircraft (ICAO): A320');assert.equal(missing.lowT,null);assert.equal(missing.absCross,null);assert.equal(missing.rollChanges,null);assert.equal(missing.aircraft,'A320');
  assert.throws(()=>context.parseTrend('LMM_fake.txt','this is not a flight report'));
  const process=async(name,text)=>context.processTrend(name,new TextEncoder().encode(text).buffer);
  const en=await process('LMM_EN.txt',fixture()),cn=await process('LMM_CN.txt',fixture({zh:true})),copy=await process('LMM_renamed.txt',fixture());assert.equal(en.id,cn.id);assert.equal(en.id,copy.id);assert.notEqual(en.id,(await process('LMM_other.txt',fixture({date:'2026-09-02 12:00:00'}))).id);
  assert.equal(context.statistics([-5,5,null]).mean,0);assert.equal(context.statistics([5,5,null]).mean,5);assert.equal(context.statistics([null,undefined]).n,0);assert.equal(context.statistics([null]).mean,null);
  const incomplete=context.parseTrend('LMM_incomplete.txt',fixture({full:true}).replace('LMM_RECORDING_END\t1\t121',''));assert(incomplete.issues.some(x=>x.includes('missing_end')));
  assert.equal(context.atTime([{t:0,v:0},{t:2,v:2}],1,'v'),null);
  const detents=Array.from({length:101},(_,i)=>({t:i/10-10,throttle1:.15,throttle2:.08,detent1:i>=70?'IDLE':'CL',detent2:i>=70?'IDLE':'CL'}));
  detents.expectedChannels=['throttle1','throttle2'];
  const idle=context.lowThrottleEvent(detents,[{t:-3,ra:30}]);assert.equal(idle.method,'detent');assert.equal(idle.t,-3);assert.equal(idle.height,30);
  const broken=detents.map(p=>({...p,detent2:p.t>=-3?'NA':p.detent2}));broken.expectedChannels=detents.expectedChannels;assert.equal(context.lowThrottleEvent(broken,[]).t,undefined);
  assert.equal(r.lowMethod,'ratio');
  assert.equal(context.parseTrend('LMM_zero.txt',fixture().replace('100 ft to touchdown time: 10 s','100 ft to touchdown time: 0 s')).flare100,null);
  console.log('Trends unit checks: legacy CRCRLF, CN/EN equivalence, full records, per-metric missing values, continuity, exact timing, grouping identity, semantic dedup and untrusted text passed.');
}
if(require.main===module)run().catch(e=>{console.error(e);process.exitCode=1});
module.exports={fixture,run};

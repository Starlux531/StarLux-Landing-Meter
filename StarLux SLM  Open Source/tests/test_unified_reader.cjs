const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),path=require('node:path');
const root=path.join(__dirname,'..'),html=fs.readFileSync(path.join(root,'LMM_Report_Reader.html'),'utf8');
function fixture(){
  const fields=['t','lat','lon','agl','msl','gs','ias','pitch','roll','g','ground','pitch_input','roll_input','yaw_input','throttle1','n1_1','physical_fpm','vvi','aoa'];
  const lines=['StarLux LMM v1.1.9 - single landing report','Final rating: STABLE','Touchdown vertical speed: -170 fpm','Final load: 1.16 G','Landing airport: TEST','Aircraft (ICAO): B738','Touchdown runway: RWY09','First touchdown T+s: 20','Runway length: 3023.41 m','Runway width: 45 m','Touchdown distance from runway threshold: 403.12 m','Signed touchdown centerline deviation: 0 m','LMM_RUNWAY\t1\t25\t121\t25\t121.03\t45\t25\t121.004','LMM_RECORDING_BEGIN\t1','FIELDS\tT\t'+fields.join('\t'),'FIELDS\tW\tt\tspeed_kt\tfrom_deg_mag\theadwind_kt\tcrosswind_from_right_kt\tfrom_deg_true','META\tstart_time\t1000','META\ttouch_time\t1180','META\twind_interval_s\t1','META\tphase\tCOMPLETE','META\tend_reason\tlow_speed','META\tfront_missing\t0'];
  for(let i=0;i<=2400;i++){
    const t=i/10,air=t<180,lat=25+(air?Math.sin((t-180)/25)*.0003:Math.sin((t-180)/3)*.000025),lon=air?121.004-(180-t)*.0006:121.004+(t-180)*.00032;
    const values=[1000+t,lat,lon,Math.max(0,(180-t)*13.88),100+Math.max(0,(180-t)*13.88),air?140:Math.max(20,140-(t-180)*2),air?145:Math.max(20,145-(t-180)*2),2+Math.sin(t/20),Math.sin(t/15),i===1800?1.16:1,air?0:1,.2*Math.sin(t/10),.1*Math.sin(t/15),0,air?.6:.1,air?65:30,air?-800:0,air?-810:0,3];
    lines.push('T\t'+values.join('\t'));if(i%10===0)lines.push(`W\t${1000+t}\t${10+5*Math.sin(t/10)}\t${(350+t)%360}\t8\t5\t${(352+t)%360}`);
  }
  lines.push('LMM_RECORDING_END\t1\t2401');return lines.join('\n');
}
function modernFixture(){
  const version=JSON.parse(fs.readFileSync(path.join(root,'development.json'),'utf8')).version;
  return fixture().replace('StarLux LMM v1.1.9 -','StarLux LMM v'+version+' -').split('\n').map(line=>line.startsWith('FIELDS\tT\t')?line+'\theading\ttrue_heading\televator1\televator2\taileron1\taileron2\trudder1\trudder2\tlever1\tdetent1\tdetent_mode\ttrace_fpm\ttrace_fpm_source':line.startsWith('T\t')?line+'\t88\t90\t0\t-1\t3\t-3\t2\t\t0.5\tCL\t0\t-777\tphysical_velocity':line).join('\n');
}
const code=html.slice(html.indexOf('function parseFullRecording('),html.indexOf('function setTimeView('));
const context=vm.createContext({state:{},clamp:(v,a,b)=>Math.max(a,Math.min(b,v))});vm.runInContext(code,context);
const raw=fixture(),rec=context.parseFullRecording(raw);assert(rec.complete);
const report=context.integrateRecording({raw,recording:rec,trajectory:[{t:19.9,fpm:-171}],controlTrace:[{t:19.9,elevator1:2}],firstTouchTime:20,energyType:'N1'});
assert.equal(report.firstTouchTime,180);assert.equal(report.trajectory.length,2401);assert.equal(report.controlTrace.length,2401);
assert.equal(report.trajectory[0].t,0);assert.equal(report.trajectory[1799].fpm,-171);assert.equal(report.trajectory[100].fpm,-800);
assert.equal(report.controlTrace[1799].elevator1,2);assert.equal(report.controlTrace[100].elevator1,null);
assert.equal(report.controlTrace[100].power1,65);assert.equal(report.trajectory[5].windSpeed,10);
const modern=modernFixture(),modernRec=context.parseFullRecording(modern);
assert.equal(modernRec.issues.length,0);assert(modernRec.complete);
const modernReport=context.integrateRecording({raw:modern,recording:modernRec,trajectory:[],controlTrace:[],energyType:'N1'});
for(const p of modernReport.controlTrace){assert.equal(p.elevator1,0);assert.equal(p.elevator2,-1);assert.equal(p.rudder2,null);assert.equal(p.detent1,'CL');assert.equal(p.detentMode,0);assert.equal(p.lever1,.5)}
assert(modernReport.trajectory.every(p=>p.fpm===-777&&p.fpmSource==='physical_velocity'));
assert(Math.abs(report.planPoints[1800].cross)<.001);assert(report.planPoints[1800].along>400);
assert(context.projectRunway(report.runwayGeometry,25.001,121.004).cross>100);
assert.equal(context.longitudeDelta(-359),1);
const prior=context.integrateRecording({raw:'old 1.1.9',recording:{...rec,meta:{...rec.meta,runway_heading_true:'90'},trajectory:[{t:1180,lat:25,lon:121.004,along:403.12,cross:0}]},trajectory:[],controlTrace:[],runwayLengthM:3023.41,runwayWidthM:45,touchdownFromThresholdM:403.12,centerlineSignedM:0});
assert(prior.runwayGeometry.derived);assert(Math.abs(prior.runwayGeometry.lon1-121)<.000001);assert(Math.abs(prior.planPoints[0].cross)<.01);
const noGeometry=context.integrateRecording({raw:'old without true heading',recording:{...rec,meta:{...rec.meta},trajectory:[{t:1180,lat:25,lon:121.004,along:403.12,cross:0}]},trajectory:[],controlTrace:[],runwayLengthM:3023.41,runwayWidthM:45});assert.equal(noGeometry.runwayGeometry,undefined);
const slice=context.timeWindowPoints(report.trajectory,{xmin:120,xmax:121});assert.equal(slice.length,11);assert.equal(slice[0].t,120);
const partial=context.integrateRecording({raw,recording:{...rec,meta:{...rec.meta,touch_time:''}},trajectory:[],controlTrace:[],firstTouchTime:null});assert.equal(partial.firstTouchTime,null);
const huge=Array.from({length:72001},(_,i)=>({t:i*.1,g:i===65000?4:1}));assert(context.recordingEnvelope(huge,'g').some(p=>p.g===4));
assert(!html.includes('id="fullRecording"'));assert(html.includes('id="timePan"'));assert(!html.includes('key:"windFrom"'));assert(html.includes('data-ils-curve'));assert(html.includes('id="profileModeWind"'));
console.log('Unified reader: touchdown alignment, legacy supplements, missing channels, wind timestamps, runway projection, partial records and long-record envelope passed.');
if(require.main===module&&process.argv.includes('--fixture')){fs.mkdirSync(path.join(root,'.tools/dev-119'),{recursive:true});fs.writeFileSync(path.join(root,'.tools/dev-119/unified-fixture.txt'),raw)}
module.exports={fixture,modernFixture};

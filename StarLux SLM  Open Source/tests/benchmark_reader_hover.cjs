// Controlled browser-side JS timing; not a game FPS measurement.
const fs=require('node:fs'),path=require('node:path'),{pathToFileURL}=require('node:url');
const {chromium}=require('playwright'),{modernFixture}=require('./test_unified_reader.cjs');
function longFixture(){
 const lines=modernFixture().split('\n'),head=lines.filter(l=>!l.startsWith('T\t')&&!l.startsWith('W\t')&&!l.startsWith('LMM_RECORDING_END'));
 const samples=lines.filter(l=>l.startsWith('T\t')||l.startsWith('W\t'));
 for(let block=0;block<10;block++)for(const line of samples){const cells=line.split('\t');cells[1]=String(Number(cells[1])+block*240.1);head.push(cells.join('\t'))}
 head.push('LMM_RECORDING_END\t1\t24010');return head.join('\n');
}
(async()=>{
 const browser=await chromium.launch({channel:'msedge',headless:true}),page=await browser.newPage({viewport:{width:1500,height:1100}}),out={label:process.argv[2]||'current',cases:[]};
 try{
  await page.goto(pathToFileURL(path.resolve(process.env.LMM_BENCH_HTML||'LMM_Report_Reader.html')).href);
  for(const [name,raw] of [['2401 samples',modernFixture()],['24010 samples',longFixture()]]){
   await page.evaluate(async raw=>{await importFiles([new File([raw],'LMM_perf.txt')],'main');setChartMode('separated');focusTimeView('full');setPlaybackTime(10)},raw);
   const result=await page.evaluate(()=>{const r=activeRecord().report,max=r.trajectory.at(-1).t;for(let i=0;i<5;i++)setPlaybackTime(max*(i+1)/10);const timings=[];
    for(let i=0;i<60;i++){const start=performance.now();setPlaybackTime(max*(.15+.7*i/60));timings.push(performance.now()-start)}
    timings.sort((a,b)=>a-b);return{samples:r.trajectory.length,meanMs:timings.reduce((a,b)=>a+b)/timings.length,p50Ms:timings[30],p95Ms:timings[57],maxMs:timings.at(-1)}});
   out.cases.push({name,...result});
  }
  fs.mkdirSync('.tools/dev-119',{recursive:true});fs.writeFileSync(`.tools/dev-119/hover-${out.label}.json`,JSON.stringify(out,null,2));console.log(JSON.stringify(out));
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});

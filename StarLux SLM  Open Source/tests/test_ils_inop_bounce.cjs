const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {pathToFileURL}=require('node:url'),{chromium}=require('playwright'),{ilsFixture}=require('./ils_fixture.cjs');
const actual=process.argv[2];
(async()=>{
 const browser=await chromium.launch({channel:'msedge',headless:true}),page=await browser.newPage({viewport:{width:1500,height:1100}}),errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto(pathToFileURL(path.resolve('LMM_Report_Reader.html')).href);
  let baseline;
  for(const mode of ['full','none','locOnly']){
   await page.evaluate(async raw=>{await importFiles([new File([raw],'LMM_ils.txt')],'main');setLanguage('zh');focusTimeView('full');setPlaybackTime(140)},ilsFixture(mode));
   for(const width of [1500,760]){
    await page.setViewportSize({width,height:1100});
    for(const time of [140,190]){
     await page.evaluate(t=>setPlaybackTime(t),time);
     const sizes=await page.evaluate(()=>['inputLoc','inputGs'].map(id=>{const e=$(id),b=e.getBoundingClientRect();return [e.clientWidth,e.clientHeight,b.width>0,b.height>0]}));
     baseline??=sizes;assert.deepEqual(sizes,baseline,'ILS geometry must not change with signal, time or viewport');
     assert.equal(await page.locator('#inputLocInop').getAttribute('visibility'),mode==='none'||time===190?'visible':'hidden');
     assert.equal(await page.locator('#inputGsInop').getAttribute('visibility'),mode!=='full'||time===190?'visible':'hidden');
    }
   }
  }
  const lengths=await page.evaluate(()=>[1,10,20,60].flatMap(speed=>[0,Math.PI/4,Math.PI/2].map(angle=>{
   const d=windArrowPath(50,50,Math.cos(angle),Math.sin(angle),speed),values=d.match(/-?\d+(?:\.\d+)?(?:e[+-]?\d+)?/gi).map(Number);
   return Math.hypot(values[2]-values[0],values[3]-values[1]);
  })));
  for(const length of lengths)assert(Math.abs(length-32)<1e-8);
  // Evidence is computed once on import, never by the pointer-move renderer.
  const fixture=JSON.parse(fs.readFileSync('tests/fixtures/bounce-long-beta6.json','utf8'));
  const result=await page.evaluate(samples=>{
   const trajectory=samples.map(s=>({...s,physical_fpm:s.physical_fpm})),first=trajectory.find(p=>p.ground===1);
   const r={meta:{touch_time:String(first.t)},trajectory};
   const detected=recordedBounceEvidence(r);
   const gap=recordedBounceEvidence({...r,trajectory:trajectory.filter(p=>p.t<219||p.t>222)});
   const jitter=recordedBounceEvidence({meta:{touch_time:'1'},trajectory:[{t:1,ground:1,agl:7},{t:1.1,ground:0,agl:7.1,physical_fpm:1},{t:1.2,ground:1,agl:7}]});
   return {detected,gap,jitter};
  },fixture.samples);
  assert(result.detected.secondTouch-result.detected.touch>6);assert.equal(result.gap,null);assert.equal(result.jitter,null);
  if(actual){
   const raw=fs.readFileSync(actual,'utf8');
   await page.evaluate(async raw=>{await importFiles([new File([raw],'LMM_actual_bounce.txt')],'main');setLanguage('zh');setPlaybackTime(115)},raw);
   assert((await page.locator('#warningInsight').textContent()).includes('完整记录显示弹跳'));
   assert.equal(await page.evaluate(()=>activeRecord().report.bounceText),'未检测到弹跳','retain original report statement');
   await page.locator('#livePanels').screenshot({path:'.tools/dev-119/ils-inop-beta7.png'});
   await page.evaluate(()=>setLanguage('en'));assert((await page.locator('#warningInsight').textContent()).includes('original rating retained'));
  }
  assert.deepEqual(errors,[]);console.log('Fixed LOC/GS dimensions, INOP/valid/ground states, fixed wind arrows and real long-bounce retrospective evidence passed.');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});

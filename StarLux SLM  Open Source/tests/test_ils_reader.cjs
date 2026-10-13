const assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs'),vm=require('node:vm');
const {pathToFileURL}=require('node:url'),{chromium}=require('playwright'),{ilsFixture}=require('./ils_fixture.cjs');
const html=fs.readFileSync('LMM_Report_Reader.html','utf8');
const context=vm.createContext({state:{},clamp:(v,a,b)=>Math.max(a,Math.min(b,v))});
vm.runInContext(html.slice(html.indexOf('function parseFullRecording('),html.indexOf('function setTimeView(')),context);
const reference={lat:0,lon:0,course:0,locDegPerDot:1.25,gsDegPerDot:.35,gs:{lat:0,lon:0,elevation:1800,angle:3}};
const p={lat:-.05,lon:0,msl:(1800+5559.75*Math.tan(3*Math.PI/180))/.3048,ground:0};
const on=context.ilsDeviation(reference,p);assert(on.loc_valid&&on.gs_valid);assert(Math.abs(on.loc_dots)<1e-8);assert(Math.abs(on.gs_dots)<1e-8);
assert(context.ilsDeviation(reference,{...p,lon:-.001}).loc_dots>0,'left of LOC => needle right');
assert(context.ilsDeviation(reference,{...p,lon:.001}).loc_dots<0);
assert(context.ilsDeviation(reference,{...p,msl:p.msl-100}).gs_dots>0,'below GS => needle up');
assert(context.ilsDeviation(reference,{...p,msl:p.msl+100}).gs_dots<0);
for(const point of [{...p,ground:1},{...p,lat:.01},{...p,lat:-1},{...p,lon:null}])assert(!context.ilsDeviation(reference,point).loc_valid);
assert(!context.parseIlsReference({ils_version:'2'}));assert(!context.parseIlsReference({ils_version:'1'}));
const cleared=context.parseFullRecording(ilsFixture().replace('LMM_RECORDING_END','META\tils_loc_lat\t\nMETA\tils_gs_lat\t\nLMM_RECORDING_END'));
assert.equal(context.parseIlsReference(cleared.meta),null,'blank metadata must clear stale references');
(async()=>{
 const browser=await chromium.launch({channel:'msedge',headless:true}),page=await browser.newPage({viewport:{width:1500,height:1100}}),errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto(pathToFileURL(path.resolve('LMM_Report_Reader.html')).href);
  for(const mode of ['full','locOnly','none']){
   await page.evaluate(async({raw,mode})=>{await importFiles([new File([raw],`LMM_ils_${mode}.txt`)],'main');setLanguage('zh');setThemeSeed('#26103C',false);focusTimeView('full');setPlaybackTime(140)},{raw:ilsFixture(mode),mode});
   assert(await page.locator('#inputLoc').isVisible());assert(await page.locator('#inputGs').isVisible());
   assert.equal(await page.locator('#inputLocInop').getAttribute('visibility'),mode==='none'?'visible':'hidden');assert.equal(await page.locator('#inputGsInop').getAttribute('visibility'),mode==='full'?'hidden':'visible');
   assert.equal(await page.locator('#windProfile').isVisible(),true);assert.equal(await page.locator('[data-loc-reference]').count(),mode==='none'?0:1);
   assert.equal(await page.locator('[data-wind-curve]').count(),0);
   if(mode==='full'){
    assert.equal(await page.locator('#inputLoc [data-ils-dot]').count(),4);assert.equal(await page.locator('#inputGs [data-ils-dot]').count(),4);
    assert.equal(await page.locator('[data-ils-zero]').getAttribute('x1'),'140');
    assert(await page.evaluate(()=>$('windProfile')._Y(0)>$('windProfile')._Y(240)));
    assert(await page.evaluate(()=>[...document.querySelectorAll('[data-profile-wind]')].every(n=>{const p=recordingPointAt(activeRecord().report.ilsPoints,Number(n.dataset.windTime));return Math.abs(Number(n.dataset.windX)-$('windProfile')._X(p.loc_aircraft_dots))<1e-8})));
    assert.deepEqual(await page.evaluate(()=>[0,10,10.01,20,20.01].map(windColor)),['#82c99a','#82c99a','#ffe7b8','#ffe7b8','#ef7b82']);
    await page.evaluate(()=>setTimeView(100,50));
    assert(await page.evaluate(()=>[...document.querySelectorAll('[data-profile-wind]')].every(n=>+n.dataset.windTime>=100&&+n.dataset.windTime<=150)));
    const target=await page.evaluate(()=>{const v=activeRecord().report.planDisplay,p=v.points.find(p=>Math.abs(p.t-130)<.01),b=$('approachPlan').querySelector('svg').getBoundingClientRect();return{x:b.left+v.screenX(p)/900*b.width,y:b.top+v.screenY(p)/540*b.height,transform:v.geometry.getAttribute('transform'),span:state.timeView.span}});
    await page.locator('#approachPlan svg').dispatchEvent('mousemove',{clientX:target.x,clientY:target.y});
    await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
    assert(Math.abs(await page.evaluate(()=>state.playback.time)-130)<1,'seek is limited by one screen pixel in the full-flight view');
    assert.equal(await page.evaluate(()=>activeRecord().report.planDisplay.geometry.getAttribute('transform')),target.transform);assert.equal(await page.evaluate(()=>state.timeView.span),target.span);
    assert.equal(await page.locator('[data-plan-time]').getAttribute('visibility'),'visible');
    await page.evaluate(()=>{focusTimeView('full');setPlaybackTime(140)});await page.addStyleTag({content:'.topbar{position:static!important}'});
    await page.locator('#planViews').screenshot({path:'.tools/dev-119/ils-plan-beta3.png'});await page.locator('#livePanels').screenshot({path:'.tools/dev-119/ils-input-beta3.png'});
    await page.evaluate(()=>setLanguage('en'));assert((await page.locator('#windProfileHelp').textContent()).includes('geometric reference'));
    await page.setViewportSize({width:760,height:1000});await page.locator('#livePanels').screenshot({path:'.tools/dev-119/ils-input-narrow-beta3.png'});await page.setViewportSize({width:1500,height:1100});
    await page.evaluate(()=>setPlaybackTime(190));assert(await page.locator('#inputLoc').isVisible());assert(await page.locator('#inputGs').isVisible());assert.equal(await page.locator('#inputLocInop').getAttribute('visibility'),'visible');assert.equal(await page.locator('#inputGsInop').getAttribute('visibility'),'visible');
    const segments=await page.evaluate(()=>{const r=activeRecord().report,points=Array.from({length:36001},(_,i)=>({t:i/10,loc_aircraft_dots:Math.sin(i/1000)}));r.trajectory=points;r.ilsPoints=points;state.timeView=null;$('windProfile')._key=null;renderWindProfile(r,100);const continuous=$('windProfile').querySelector('[data-ils-curve]').getAttribute('d');r.ilsPoints=points.filter(p=>p.t<50||p.t>55);$('windProfile')._key=null;renderWindProfile(r,100);return [(continuous.match(/M/g)||[]).length,($('windProfile').querySelector('[data-ils-curve]').getAttribute('d').match(/M/g)||[]).length]});
    assert.deepEqual(segments,[1,2],'one-hour reduction must preserve continuity and real gaps');
   }
  }
  assert.deepEqual(errors,[]);console.log('ILS geometry and Edge: altitude datum, LOC/GS signs, invalid/backcourse/ground, four-dot instruments, noILS/LOC-only, aircraft-attached wind, thresholds, hover sync, EN/ZH and responsive checks passed.');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});

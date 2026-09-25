const assert=require('node:assert/strict'),path=require('node:path');
const {pathToFileURL}=require('node:url'),{chromium}=require('playwright'),{ilsFixture}=require('./ils_fixture.cjs');
(async()=>{
 const browser=await chromium.launch({channel:'msedge',headless:true});
 const page=await browser.newPage({viewport:{width:2200,height:1200}}),errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto(pathToFileURL(path.resolve('LMM_Report_Reader.html')).href);
  await page.evaluate(async raw=>{await importFiles([new File([raw],'LMM_attitude.txt')],'main');setLanguage('en');focusTimeView('full');setPlaybackTime(160)},ilsFixture());
  const check=()=>page.evaluate(()=>{
   const root=$('timelineAttitude'),t=state.playback.time,p=nearestPoint(activeRecord().report.trajectory,t);
   return {available:root.dataset.available,time:Number(root.dataset.time),t,bank:root._parts.bank.getAttribute('transform'),expectedBank:'rotate('+(-p.roll)+' 100 100)',world:root._parts.world.getAttribute('transform'),expectedWorld:'translate(0 '+p.pitch*2.3+')'};
  });
  let a=await check();assert.equal(a.available,'true');assert.equal(a.time,a.t);assert.equal(a.bank,a.expectedBank);assert.equal(a.world,a.expectedWorld);
  await page.evaluate(()=>{window.attitudeSvg=$('timelineAttitude')._parts.svg;setPlaybackTime(180)});
  a=await check();assert.equal(a.time,180);assert.equal(a.bank,a.expectedBank);assert(await page.evaluate(()=>window.attitudeSvg===$('timelineAttitude')._parts.svg),'reuse SVG on every frame');
  const chart=page.locator('#flareChart'),bounds=await chart.boundingBox();
  await chart.dispatchEvent('mousemove',{clientX:bounds.x+bounds.width*.4,clientY:bounds.y+bounds.height*.4});
  await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
  a=await check();assert.equal(a.time,a.t);assert.equal(a.bank,a.expectedBank);assert.notEqual(a.time,180);
  await page.evaluate(()=>updateTimelineAttitude({trajectory:[{t:0,pitch:10,roll:30}]},0));
  assert.equal(await page.evaluate(()=>$('timelineAttitude')._parts.world.getAttribute('transform')),'translate(0 23)');
  assert.equal(await page.evaluate(()=>$('timelineAttitude')._parts.bank.getAttribute('transform')),'rotate(-30 100 100)');
  await page.evaluate(()=>updateTimelineAttitude({trajectory:[{t:0,pitch:null,roll:null}]},0));
  assert.equal(await page.locator('#timelineAttitude').getAttribute('data-available'),'false');
  assert((await page.locator('#timelineAttitude').innerText()).includes('NO ATTITUDE DATA'));
  await page.evaluate(()=>{setLanguage('zh');setPlaybackTime(140)});
  await page.addStyleTag({content:'.topbar{position:static!important}'});
  for(const width of [2200,1600,760,420]){
   await page.setViewportSize({width,height:1200});
   assert.equal((await page.locator('.xy-pad').boundingBox()).width,200,'existing control pad width');
   const layout=await page.evaluate(()=>{const a=$('timelineAttitude').getBoundingClientRect(),b=document.querySelector('.xy-pad').getBoundingClientRect();return {separate:a.left>=b.right||a.top>=b.bottom,overflow:document.documentElement.scrollWidth>innerWidth+1}});
   assert(layout.separate,'no overlap');if(width>=760)assert(!layout.overflow,'page overflow at '+width);
   const inside=await page.evaluate(()=>{const a=$('timelineAttitude').getBoundingClientRect(),p=$('timelineAttitude').closest('.live-panel').getBoundingClientRect();return {a:[a.left,a.right],p:[p.left,p.right]}});assert(inside.a[0]>=inside.p[0]&&inside.a[1]<=inside.p[1],'attitude stays inside panel '+width+': '+JSON.stringify(inside));
   await page.locator('#livePanels').screenshot({path:'.tools/rc2/attitude-'+width+'.png'});
  }
  assert.deepEqual(errors,[]);console.log('Attitude: recorded pitch/roll, signs, shared hover/time cursor, missing data, DOM reuse, 4 responsive widths passed.');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});

const assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs');
const {pathToFileURL}=require('node:url'),{chromium}=require('playwright'),{ilsFixture}=require('./ils_fixture.cjs');
(async()=>{
 const browser=await chromium.launch({channel:'msedge',headless:true});const page=await browser.newPage({viewport:{width:1600,height:1100}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto(pathToFileURL(path.resolve('LMM_Report_Reader.html')).href);
  await page.evaluate(async raw=>{await importFiles([new File([raw],'LMM_wind.txt')],'main');setLanguage('en');focusTimeView('full');setPlaybackTime(160)},ilsFixture());
  const version=JSON.parse(fs.readFileSync(path.join(__dirname,'../development.json'),'utf8')).version;
  assert.equal(await page.evaluate(()=>activeRecord().report.version),version);
  assert.equal(await page.locator('#analyzerBuild').textContent(),version);
  assert.equal(await page.locator('#metricPicker input[value="windFrom"]').count(),0);
  assert.equal(await page.locator('#metricPicker input[value="headwind"]').count(),0);
  assert.equal(await page.locator('#metricPicker input[value="crosswind"]').count(),0);
  assert.equal(await page.locator('#metricPicker input[value="windSpeed"]').count(),1);
  assert.equal(await page.locator('#inputWindArrow').getAttribute('visibility'),'visible');
  assert((await page.locator('#inputWindValue').textContent()).includes('150°M'));
  assert(await page.locator('#showWindProfile').isChecked());assert(await page.locator('#windProfile svg').count());
  assert.equal(await page.locator('[data-wind-curve]').count(),0);
  assert(await page.evaluate(()=>$('windProfile')._Y(0)>$('windProfile')._Y(240)),'time advances up like approach map');
  assert.equal(await page.locator('[data-ils-zero]').getAttribute('x1'),'140');
  await page.locator('#planZoom').selectOption('16');
  assert(await page.evaluate(()=>activeRecord().report.planDisplay.windBackground.children.length>0));
  assert(await page.evaluate(()=>Number(activeRecord().report.planDisplay.runwayLayer.querySelector('rect').getAttribute('width'))>=14));
  const snapshot=()=>page.evaluate(()=>({view:{...state.timeView},transform:activeRecord().report.planDisplay.geometry.getAttribute('transform'),scales:ui.canvas._plot.scales,profile:$('windProfile')._key}));
  await page.evaluate(()=>setTimeView(140,30));
  const before=await snapshot(),bounds=await page.locator('#flareChart').boundingBox();
  await page.locator('#flareChart').dispatchEvent('mousemove',{clientX:bounds.x+bounds.width-1,clientY:bounds.y+100});
  assert.deepEqual(await snapshot(),before,'hover must not change chart range, map transform, or wind time window');
  await page.evaluate(()=>setPlaybackTime(175));assert.deepEqual(await snapshot(),before);
  const chart=page.locator('#flareChart');await chart.dispatchEvent('wheel',{deltaY:-120});assert.deepEqual(await snapshot(),before);
  await chart.dispatchEvent('wheel',{deltaY:-120,ctrlKey:true});assert((await snapshot()).view.span<before.view.span);
  const zoom=await page.locator('#planZoom').inputValue();
  await page.locator('#approachPlan svg').dispatchEvent('wheel',{deltaY:-120});assert.equal(await page.locator('#planZoom').inputValue(),zoom);
  await page.locator('#approachPlan svg').dispatchEvent('wheel',{deltaY:-120,ctrlKey:true});assert.equal(await page.locator('#planZoom').inputValue(),String(Number(zoom)*2));
  assert(await page.evaluate(()=>activeRecord().report.planDisplay.windBackground.children.length>0));
  await page.evaluate(()=>{setLanguage('zh');setPlaybackTime(185);zoomPlan(4,true);focusTimeView('full')});
  await page.locator('#windProfileLabel').click();assert(await page.locator('#windProfile').isHidden());await page.locator('#windProfileLabel').click();
  const wind=page.locator('#windProfile svg'),rect=await wind.boundingBox();
  await wind.dispatchEvent('mousemove',{clientX:rect.x+rect.width/2,clientY:rect.y+rect.height/2});
  await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
  assert(Math.abs((await page.evaluate(()=>state.playback.time))-116.9)<1);
  assert.equal(await page.evaluate(()=>$('windProfile')._cursor.getAttribute('visibility')),'visible');
  await page.locator('#planWindLabel').click();assert.equal(await page.evaluate(()=>activeRecord().report.planDisplay.windBackground.children.length),0);
  await page.locator('#planWindLabel').click();

  await page.evaluate(()=>{setPlaybackTime(185);zoomPlan(4,true)});
  await page.addStyleTag({content:'.topbar{position:static!important}'});
  await page.locator('#planViews').screenshot({path:'.tools/dev-119/wind-view-zh.png'});
  await page.locator('.plan-tools').screenshot({path:'.tools/dev-119/wind-controls-zh.png'});
  await page.locator('#livePanels').screenshot({path:'.tools/dev-119/wind-input-zh.png'});
  const real=process.argv[2];if(real){await page.locator('#fileInput').setInputFiles(real);await page.waitForFunction(()=>activeRecord()?.report.trajectory.length===1946);await page.evaluate(()=>{setLanguage('zh');setPlaybackTime(125);zoomPlan(8,true);focusTimeView('full')});assert.equal(await page.evaluate(()=>activeRecord().report.trajectory.length),1946);assert(await page.evaluate(()=>activeRecord().report.planDisplay.windBackground.children.length>0));await page.locator('#planViews').screenshot({path:'.tools/dev-119/wind-real-zh.png'})}
  assert.deepEqual(errors,[]);console.log('Wind views: complete channels, XYZ vector/readout, optional vertical plot, shared cursor, persistent zoomed winds, stable hover scales, explicit zoom only, real log compatibility passed.');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});

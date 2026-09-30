const assert=require('node:assert/strict'),path=require('node:path'),{pathToFileURL}=require('node:url');
const {chromium}=require('playwright'),{ilsFixture}=require('./ils_fixture.cjs');
const frame=page=>page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
(async()=>{
 const browser=await chromium.launch({channel:'msedge',headless:true}),page=await browser.newPage({viewport:{width:1500,height:1100}}),errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto(pathToFileURL(path.resolve('LMM_Report_Reader.html')).href);
  await page.evaluate(async raw=>{await importFiles([new File([raw],'LMM_perf.txt')],'main');setLanguage('zh');setThemeSeed('#26103C',false);setChartMode('separated');focusTimeView('full');setPlaybackTime(100)},ilsFixture('none'));
  await page.waitForTimeout(240);await frame(page);
  assert(await page.locator('#windProfile svg').isVisible(),'vertical view remains without ILS');
  assert.equal(await page.evaluate(()=>$('windProfile')._kind),'center');assert(await page.locator('#inputLoc').isVisible());assert.equal(await page.locator('#inputLocInop').getAttribute('visibility'),'visible');
  const full=await page.evaluate(()=>$('windProfile')._extent);await page.evaluate(()=>setTimeView(175,4));
  assert((await page.evaluate(()=>$('windProfile')._extent))<full,'selected interval is magnified laterally');
  await page.click('#profileModeWind');assert.equal(await page.evaluate(()=>$('windProfile')._kind),'wind');assert(await page.locator('[data-wind-curve]').count());
  assert.equal(await page.evaluate(()=>$('windProfile')._extent),90);assert.deepEqual(await page.evaluate(()=>[359,0,1].map(from_deg_true=>Math.round(profileWindAngle({from_deg_true,speed_kt:12},{ux:0,uy:1}))+0)),[1,0,-1]);
  await page.click('#profileZoomIn');assert((await page.evaluate(()=>state.timeView.span))<4);await page.click('#profileZoomOut');
  await page.click('#profileModeLoc');await page.evaluate(()=>setTimeView(90,50));await page.waitForTimeout(240);await frame(page);
  await page.evaluate(()=>{
    window.work={flare:0,control:0,series:0,seek:0};const a=drawFlare,b=drawControlChart,c=buildMetricSeries,d=setPlaybackTime;
    drawFlare=(...args)=>{work.flare++;return a(...args)};drawControlChart=(...args)=>{work.control++;return b(...args)};buildMetricSeries=(...args)=>{work.series++;return c(...args)};setPlaybackTime=(...args)=>{work.seek++;return d(...args)};
    window.staticState={plot:ui.canvas._plot,control:ui.controlCanvas._plot,legend:ui.chartLegend.firstChild,svg:$('windProfile').firstChild,help:$('windProfileHelp').firstChild,extent:$('windProfile')._extent,transform:activeRecord().report.planDisplay.geometry.getAttribute('transform')};
    const r=ui.canvas.getBoundingClientRect(),p=ui.canvas._plot;
    for(let i=0;i<100;i++)ui.canvas.dispatchEvent(new MouseEvent('mousemove',{clientX:r.left+p.p.l+p.pw*(.1+.8*i/99),clientY:r.top+100}));
  });
  await frame(page);
  const warm=await page.evaluate(()=>({work:{...work},time:state.playback.time,plotStable:ui.canvas._plot===staticState.plot,controlStable:ui.controlCanvas._plot===staticState.control,legendStable:ui.chartLegend.firstChild===staticState.legend,svgStable:$('windProfile').firstChild===staticState.svg,helpStable:$('windProfileHelp').firstChild===staticState.help,extent:$('windProfile')._extent,originalExtent:staticState.extent,transformStable:activeRecord().report.planDisplay.geometry.getAttribute('transform')===staticState.transform}));
  assert.equal(warm.work.seek,1,'pointer burst coalesces to latest event');assert.deepEqual([warm.work.flare,warm.work.control,warm.work.series],[0,0,0]);
  assert(warm.plotStable&&warm.controlStable&&warm.legendStable&&warm.svgStable&&warm.helpStable&&warm.transformStable);assert.equal(warm.extent,warm.originalExtent);assert(Math.abs(warm.time-135)<.3);
  // Cursor position must stay aligned under the reader's CSS zoom.
  for(const zoom of [65,100,135]){
    await page.evaluate(zoom=>{applyReaderZoom(zoom,false);setPlaybackTime(120)},zoom);await page.waitForTimeout(220);await frame(page);
    const alignment=await page.evaluate(()=>[ui.canvas,ui.controlCanvas].map(canvas=>{const p=canvas._plot,b=canvas.getBoundingClientRect(),c=canvas._cursorNode.getBoundingClientRect();return {error:Math.abs(c.left-(b.left+p.X(state.playback.time))),visible:!canvas._cursorNode.hidden}}));
    assert(alignment.every(a=>a.visible&&a.error<2),JSON.stringify({zoom,alignment}));
  }
  await page.evaluate(()=>{applyReaderZoom(100,false);setTimeView(175,4)});await page.waitForTimeout(240);await frame(page);
  await page.addStyleTag({content:'.topbar{position:static!important}'});
  await page.locator('#planViews').screenshot({path:'.tools/dev-119/vertical-center-beta4.png'});
  await page.click('#profileModeWind');await page.locator('#planViews').screenshot({path:'.tools/dev-119/vertical-wind-beta4.png'});
  await page.evaluate(()=>setLanguage('en'));assert((await page.locator('#windProfileHelp').textContent()).includes('time interval'));
  // Spatial tree agrees with a full search, including a zoomed viewport.
  assert(await page.evaluate(()=>{const v=activeRecord().report.planDisplay;for(const zoom of [1,4,16]){zoomPlan(zoom,true);for(const [x,y] of [[30,30],[450,270],[700,450]]){let expected=Infinity;for(const p of v.points){const px=v.screenX(p),py=v.screenY(p);if(px<0||px>900||py<0||py>540)continue;expected=Math.min(expected,(px-x)**2+(py-y)**2)}const actual=nearestPlanPoint(v,x,y);if(!actual){if(expected!==Infinity)return false}else if(Math.abs((v.screenX(actual)-x)**2+(v.screenY(actual)-y)**2-expected)>1e-5)return false}}return true}));
  // Real changes must still invalidate the static charts.
  const count=await page.evaluate(()=>work.flare);await page.click('#timeZoomIn');assert((await page.evaluate(()=>work.flare))>count);
  assert(await page.evaluate(()=>{setTimeView(0,10);state.playback.playing=true;setPlaybackTime(20,true,true);state.playback.playing=false;return ui.canvas._plot.xmin<=20&&ui.canvas._plot.xmax>=20&&ui.controlCanvas._plot.xmin===ui.canvas._plot.xmin}),'playback follow must redraw the new time window');
  assert.deepEqual(errors,[]);console.log('Reader performance: retained/fitted vertical detail, LOC fallback + wind switch, coalesced pointer updates, zero static redraws on hover, fixed scales, 65/100/135% cursor alignment, exact spatial lookup and explicit zoom invalidation passed.');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});


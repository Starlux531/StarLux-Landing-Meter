const assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs');
const {pathToFileURL}=require('node:url'),{chromium}=require('playwright'),{ilsFixture}=require('./ils_fixture.cjs');
const frame=p=>p.evaluate(()=>new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r))));
(async()=>{
 fs.mkdirSync('.tools/rc5',{recursive:true});
 const browser=await chromium.launch({channel:'msedge',headless:true}),page=await browser.newPage({viewport:{width:1500,height:1100}}),errors=[],requests=[];
 page.on('pageerror',e=>errors.push(e.message));
 await page.route('https://tiles.openfreemap.org/**',async route=>{requests.push(route.request().url());await route.fulfill({json:{version:8,sources:{},layers:[{id:'background',type:'background',paint:{'background-color':'#243142'}}]}})});
 try{
  await page.goto(pathToFileURL(path.resolve('LMM_Report_Reader.html')).href);
  await page.evaluate(async raw=>{await importFiles([new File([raw],'LMM_RC5.txt')],'main');setLanguage('zh');focusTimeView('full')},ilsFixture());
  assert.equal(requests.length,0,'no map requests before activation'); await page.addStyleTag({content:'.topbar{position:static!important}'});
  assert(await page.locator('#planMapToggle').isChecked());
  assert(await page.locator('#planWind').isChecked());assert(await page.locator('#showWindProfile').isChecked());
  assert.equal(await page.evaluate(()=>state.profileMode),'wind');
  await page.locator('#planModule').scrollIntoViewIfNeeded();
  await page.waitForFunction(()=>planMap.ready,{timeout:15000});await page.waitForTimeout(250);await frame(page);
  assert.equal(requests.length,1,'single lazy style fetch');assert(await page.locator('#geoMap canvas').count()>=3);
  assert(await page.locator('#windProfile').isVisible());assert((await page.locator('#geoMap').textContent()).includes('OpenStreetMap'));
  assert.equal(await page.locator('#planZoom').inputValue(),'0.71');
  await page.click('#planOverview');
  const info=await page.evaluate(()=>({map:planMap.map.getZoom(),points:planMap.data.points.length,staticDraws:planMap.stats.staticDraws}));
  assert(info.points>2000);
  const target=await page.evaluate(()=>{setPlaybackTime(40);const q=planMap.project(recordingPointAt(planMap.data.points,180)),b=planMap.map.getCanvas().getBoundingClientRect();return {x:b.left+q.x*b.width/planMap.map.getContainer().clientWidth,y:b.top+q.y*b.height/planMap.map.getContainer().clientHeight}});
  await page.mouse.move(target.x,target.y);await frame(page);assert(Math.abs((await page.evaluate(()=>state.playback.time))-180)<.3,'real map mouse movement must seek shared timeline');
  await page.evaluate(()=>{window.firstMap=planMap.map;window.cameraBefore=JSON.stringify({c:planMap.map.getCenter(),z:planMap.map.getZoom()});window.drawBefore=planMap.stats.staticDraws;for(let i=0;i<100;i++)setPlaybackTime(50+i*.5,true,false)});await frame(page);
  const hover=await page.evaluate(()=>({same:planMap.map===firstMap,draws:planMap.stats.staticDraws,before:drawBefore,camera:JSON.stringify({c:planMap.map.getCenter(),z:planMap.map.getZoom()})===cameraBefore}));assert(hover.same&&hover.draws===hover.before&&hover.camera,JSON.stringify(hover));
  // Real geometry: runway centre projects onto the recorded touchdown, not a display-only runway-up transform.
  assert(await page.evaluate(()=>{const p=recordingPointAt(planMap.data.points,180),q=planMap.project(p),nearest=planMap.nearest(q.x,q.y);return nearest&&Math.abs(nearest.t-p.t)<.2}));
  const z=await page.evaluate(()=>planMap.map.getZoom());
  await page.locator('#geoMap canvas.maplibregl-canvas').dispatchEvent('wheel',{deltaY:-100,ctrlKey:false});await frame(page);
  assert.equal(await page.evaluate(()=>planMap.map.getZoom()),z,'plain wheel must not zoom');
  await page.locator('#geoMap canvas.maplibregl-canvas').dispatchEvent('dblclick');assert.equal(await page.evaluate(()=>planMap.map.getZoom()),z,'double click must not zoom');
  const box=await page.locator('#geoMap canvas.maplibregl-canvas').boundingBox();await page.locator('#geoMap canvas.maplibregl-canvas').dispatchEvent('wheel',{deltaY:-100,ctrlKey:true,clientX:box.x+box.width/2,clientY:box.y+box.height/2});await frame(page);assert((await page.evaluate(()=>planMap.map.getZoom()))>z);await page.click('#planOverview');
  await page.click('#planZoomIn');assert((await page.evaluate(()=>planMap.map.getZoom()))>z);
  await page.click('#planOverview');assert(Math.abs((await page.evaluate(()=>planMap.map.getZoom()))-z)<.02);
  await page.click('#planExpand');await frame(page);assert(await page.locator('#planDialog').isVisible());
  assert(await page.evaluate(()=>planMap.map===firstMap),'expanded view must reuse the map');
  assert((await page.locator('#planStage').boundingBox()).width>850);
  await page.evaluate(()=>setTimeView(170,20));await frame(page);assert(await page.evaluate(()=>$('windProfile')._kind==='wind'));
  const count=await page.locator('#geoMap canvas').count();await page.evaluate(()=>setLanguage('en'));await frame(page);
  assert.equal(await page.locator('#geoMap canvas').count(),count,'language keeps one map instance');
  await page.locator('#planDialog').screenshot({path:'.tools/rc5/map-layout-fixture.png'});
  await page.keyboard.press('Escape');await frame(page);assert(!await page.locator('#planDialog').isVisible());assert(await page.evaluate(()=>$('planModule').parentNode===$('planHome')));
  // Independent full-size view remains readable on a narrow screen and does not create a second WebGL map.
  await page.setViewportSize({width:600,height:850});await page.click('#planExpand');await frame(page);
  assert(await page.evaluate(()=>$('planDialog').scrollWidth<=$('planDialog').clientWidth+2));assert(await page.evaluate(()=>planMap.map===firstMap));
  await page.locator('#planDialog').screenshot({path:'.tools/rc5/map-narrow-fixture.png'});await page.keyboard.press('Escape');await page.setViewportSize({width:1500,height:1100});
  // Geographic picking remains aligned with CSS page zoom; explicit map pan stays separate from timeline hover.
  for(const zoom of [65,135]){await page.evaluate(z=>applyReaderZoom(z,false),zoom);await page.waitForTimeout(120);assert(await page.evaluate(()=>{const p=recordingPointAt(planMap.data.points,180),q=planMap.project(p);return planMap.nearest(q.x,q.y)?.t===p.t}))}
  await page.evaluate(()=>applyReaderZoom(100,false));
  await page.evaluate(()=>{const original=activeRecord().report;const report={...original,runwayGeometry:null,ilsReference:null,planDisplay:null,planPoints:original.planPoints.map(p=>({...p,lon:longitudeDelta(179.98+(p.t-120)*.0006)}))};activeRecord().report=report;renderApproachPlan(report);updatePlanViews(120)});
  await page.locator('#planStage').scrollIntoViewIfNeeded();await page.waitForFunction(()=>planMap.ready,null,{timeout:6000}).catch(async e=>{console.log(await page.evaluate(()=>({enabled:planMap.enabled,visible:planMap.visible,failed:planMap.failed,map:!!planMap.map,status:$('mapStateText').textContent,error:planMap.lastError,bounds:planMap.data?.bounds,report:!!planMap.report,disabled:$('planMapToggle').disabled})));throw e});await frame(page);
  assert(await page.evaluate(()=>{const b=planMap.data.bounds,p=recordingPointAt(planMap.data.points,180),q=planMap.project(p);return b[1][0]-b[0][0]<1&&planMap.nearest(q.x,q.y)?.t===p.t}),'dateline must remain a local view and a correctly picked track');
  await page.click('#planMapLabel');assert.equal(await page.locator('#geoMap canvas').count(),0);assert(await page.locator('#approachPlan svg').isVisible());
  await page.unroute('https://tiles.openfreemap.org/**');await page.route('https://tiles.openfreemap.org/**',route=>route.abort());
  await page.click('#planMapLabel');await page.waitForFunction(()=>planMap.failed);assert(await page.locator('#mapRetry').isVisible());assert(await page.locator('#approachPlan svg').isVisible());
  await page.evaluate(()=>setPlaybackTime(150));assert(await page.evaluate(()=>state.playback.time===150));
  await page.click('#planMapLabel');
  await page.evaluate(()=>{const MapClass=maplibregl.Map;maplibregl.Map=class{constructor(){throw Error('WebGL unavailable')}};planMap.setEnabled(true);maplibregl.Map=MapClass});assert(await page.locator('#approachPlan svg').isVisible());assert(await page.evaluate(()=>planMap.failed&&!planMap.map));await page.click('#planMapLabel');
  await page.evaluate(async()=>{await importFiles([new File(['StarLux LMM v1.1.8 - single landing report\nFinal rating: STABLE'],'LMM_legacy.txt')],'main')});assert(await page.locator('#planMapToggle').isDisabled());
  await page.evaluate(()=>{planMap.enabled=false;$('planMapToggle').checked=false;$('planWind').checked=false;$('showWindProfile').checked=false;state.profileMode='loc';localStorage.setItem('rc9-map-unrelated-check','keep')});
  await page.reload();
  assert.deepEqual(await page.evaluate(()=>[planMap.enabled,$('planMapToggle').checked,$('planWind').checked,$('showWindProfile').checked,state.profileMode,localStorage.getItem('rc9-map-unrelated-check')]),[true,true,true,true,'wind','keep']);
  assert.deepEqual(errors,[]);fs.writeFileSync('.tools/rc5/map-regression.json',JSON.stringify({passed:true,hover,initialPoints:info.points,realPointer:true,dateline:true,narrow:true,cssZoom:true,offlineFallback:true,webglFallback:true,oldRecord:true},null,2));console.log('RC5 map: lazy renderer, geographic/real-pointer picking, static hover cache, explicit zoom, expanded reuse, narrow view, dateline, record switches, offline/WebGL fallback and legacy records passed.');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});

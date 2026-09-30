// Real browser regression for the standalone, local-file reader. No external services.
const assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs');
const {pathToFileURL}=require('node:url');
const {chromium}=require('playwright');const {fixture}=require('./test_unified_reader.cjs');
(async()=>{
  const browser=await chromium.launch({channel:'msedge',headless:true});const page=await browser.newPage({viewport:{width:1440,height:1000}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
  try{
    await page.goto(pathToFileURL(path.resolve('LMM_Report_Reader.html')).href);
    await page.evaluate(async raw=>{await importFiles([new File([raw],'LMM_test.txt',{type:'text/plain'})],'main')},fixture());
    await page.waitForSelector('#approachPlan svg');
    const result=await page.evaluate(()=>({count:activeRecord().report.trajectory.length,touch:activeRecord().report.firstTouchTime,domain:chartTimeDomain(activeRecord().report),title:document.getElementById('telemetryTitle').textContent}));
    assert.equal(result.count,2401);assert.equal(result.touch,180);assert(result.domain.xmax-result.domain.xmin<30);
    await page.click('#timeFull');let span=await page.evaluate(()=>ui.canvas._plot.xmax-ui.canvas._plot.xmin);assert.equal(span,240);
    await page.click('#timeZoomIn');assert.equal(await page.evaluate(()=>ui.canvas._plot.xmax-ui.canvas._plot.xmin),120);
    await page.locator('#timePan').fill('800');await page.locator('#timePan').dispatchEvent('input');assert((await page.evaluate(()=>ui.canvas._plot.xmin))>90);
    await page.evaluate(()=>{setPlaybackTime(185);document.querySelector('#metricPicker input[value="windSpeed"]').click()});
    assert.equal(await page.evaluate(()=>ui.controlCanvas._plot.xmin),await page.evaluate(()=>ui.canvas._plot.xmin));
    assert((await page.locator('#approachNow').textContent()).includes('185.00'));
    await page.evaluate(()=>setLanguage('en'));assert.equal(await page.locator('#approachTitle').textContent(),'Landing plan view');assert.equal(await page.locator('#timeFull').textContent(),'Full');
    await page.evaluate(()=>{togglePlayback()});await page.waitForTimeout(200);await page.evaluate(()=>pausePlayback());assert((await page.evaluate(()=>state.playback.time))>185);
    await page.evaluate(()=>setChartMode('fused'));assert(await page.locator('#controlSection').isHidden());
    await page.evaluate(()=>{document.querySelector('#metricPicker input[value="windSpeed"]').click()});
    assert(await page.locator('#runwayGraphic path[stroke="#55d3ed"]').count());
    await page.addStyleTag({content:'.topbar{position:static!important}'});
    await page.locator('.telemetry-section').screenshot({path:'.tools/dev-119/unified-timeline-en.png'});
    await page.locator('.runway-section').screenshot({path:'.tools/dev-119/unified-plan-en.png'});
    await page.evaluate(()=>{setLanguage('zh');setLayoutMode('vertical');setChartMode('separated')});
    await page.setViewportSize({width:820,height:1000});await page.locator('#planZoom').selectOption('64');await page.locator('.runway-section').screenshot({path:'.tools/dev-119/unified-plan-zh.png'});
    await page.evaluate(async()=>{await importFiles([new File(['StarLux LMM v1.1.8\nFinal rating: STABLE\nFirst touchdown T+s: 2\nAggregated trajectory table\n0 100 -200\n1 50 -190\n2 0 -180\n\n'],'legacy.txt')],'main')});
    assert.equal(await page.evaluate(()=>activeRecord().report.trajectory.length),3);assert.equal(await page.evaluate(()=>activeRecord().report.recording),null);assert.equal(await page.locator('#approachPlan svg').count(),0);assert.equal(await page.locator('#approachNow').textContent(),'');
    assert.deepEqual(errors,[]);console.log('Edge browser: import, shared cursor, zoom, pan, wind selection, playback, EN/ZH, fused/separate, responsive rendering and legacy 1.1.8 report passed.');
  }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});

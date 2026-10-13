const {chromium}=require('playwright'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {pathToFileURL}=require('node:url'),{fixture}=require('./test_trends_analyzer.cjs');
(async()=>{
  fs.mkdirSync('.tools/trends',{recursive:true});
  const browser=await chromium.launch({channel:'msedge',headless:true}),page=await browser.newPage({viewport:{width:1440,height:1080}}),errors=[],network=[];
  page.on('pageerror',e=>errors.push(e.message));page.on('request',r=>{if(/^https?:/.test(r.url()))network.push(r.url())});
  try{
    await page.goto(pathToFileURL(path.resolve('LMM_Log/LMM_Trends_Analyzer.html')).href);
    await page.waitForFunction(()=>!!window.LMMTrends);
    const files=[...Array.from({length:20},(_,i)=>({name:`LMM_test_${i}.txt`,mimeType:'text/plain',buffer:Buffer.from(fixture({date:`2026-09-${String(i+1).padStart(2,'0')} 12:00:00`,cross:i%2?5:-5,aircraft:i===19?'A320':'A20N'}))})),{name:'LMM_duplicate.txt',mimeType:'text/plain',buffer:Buffer.from(fixture({date:'2026-09-01 12:00:00',cross:-5}))},{name:'LMM_bad.txt',mimeType:'text/plain',buffer:Buffer.from('invalid')},{name:'README.txt',mimeType:'text/plain',buffer:Buffer.from('skip')}];
    await page.locator('#files').setInputFiles(files);await page.waitForFunction(()=>!state.busy&&state.records.length===20);
    assert((await page.locator('#notice').textContent()).includes('重复 1'));assert((await page.locator('#notice').textContent()).includes('失败 1'));assert.equal(await page.locator('#aircraft').inputValue(),'A20N');assert.equal(await page.evaluate(()=>state.cohort.length),19);
    const summary=await page.evaluate(()=>({signed:statistics(state.cohort.map(r=>r.signedCross)),abs:statistics(state.cohort.map(r=>r.absCross))}));assert.equal(summary.abs.mean,5);assert(Math.abs(summary.signed.mean)<1);
    await page.click('[data-tab="overlay"]');await page.waitForTimeout(100);assert.equal(await page.evaluate(()=>plots.get('echo').bins[80].y),-150);
    await page.locator('#overlayMetric').selectOption('throttle1');assert.equal(await page.evaluate(()=>plots.get('echo').bins[80].y),.04);
    const bounds=await page.evaluate(()=>({min:plots.get('echo').min,max:plots.get('echo').max}));await page.locator('#echo').hover();await page.mouse.move(800,700);await page.waitForTimeout(70);assert.deepEqual(await page.evaluate(()=>({min:plots.get('echo').min,max:plots.get('echo').max})),bounds);
    await page.click('[data-tab="behavior"]');await page.locator('#earlyRef').fill('2');await page.locator('#earlyRef').dispatchEvent('change');assert((await page.locator('#behaviorCards').textContent()).includes('19 / 19 次'));
    await page.click('[data-evidence="low"]');assert.equal(await page.locator('#recordRows tr[data-id]').count(),19);await page.locator('#recordRows button').first().click();await page.click('#rawToggle');await page.waitForFunction(()=>document.getElementById('rawText').textContent.includes('StarLux'));
    await page.click('#closeDetail');await page.locator('#aircraft').selectOption('A320');assert.equal(await page.evaluate(()=>state.cohort.length),1);
    const downloadPromise=page.waitForEvent('download');await page.click('#exportCsv');const download=await downloadPromise;await download.saveAs('.tools/trends/test-export.csv');assert(fs.readFileSync('.tools/trends/test-export.csv','utf8').includes('A320'));
    await page.locator('#aircraft').selectOption('A20N');await page.locator('#dateFrom').fill('2026-09-18');await page.locator('#dateFrom').dispatchEvent('change');assert.equal(await page.evaluate(()=>state.cohort.length),2);
    await page.click('#resetFilters');await page.click('[data-tab="overview"]');await page.screenshot({path:'.tools/trends/synthetic-overview.png',fullPage:true});
    await page.setViewportSize({width:390,height:844});await page.waitForTimeout(100);assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));await page.screenshot({path:'.tools/trends/mobile.png',fullPage:true});
    // Optional locally provided flight history: read-only, never packaged into the HTML.
    const root=process.env.LMM_TRENDS_LOG_DIR;
    if(root){
      await page.reload();await page.waitForFunction(()=>!!window.LMMTrends);await page.setViewportSize({width:1440,height:1080});
      const expected=fs.readdirSync(root).filter(f=>/^LMM_.*\.txt$/i.test(f)).length;
      await page.locator('#folder').setInputFiles(root);await page.waitForFunction(()=>!state.busy&&state.records.length>0,{},{timeout:60000});
      const stats=await page.evaluate(()=>({notice:document.getElementById('notice').textContent,total:state.records.length,groups:[...new Set(state.records.map(r=>r.aircraft))],parsed:state.records.filter(r=>r.samples>0).length,controls:state.records.filter(r=>r.controlSamples>0).length,low:state.records.filter(r=>Number.isFinite(r.lowT)).length,detentEvents:state.records.filter(r=>r.lowMethod==='detent'&&Number.isFinite(r.lowT)).length,a20nIdle:state.records.filter(r=>r.aircraft==='A20N'&&Number.isFinite(r.lowT)).length,failures:state.logs.filter(r=>r.kind==='失败')}));
      fs.writeFileSync('.tools/trends/real-log-results.json',JSON.stringify(stats,null,2));assert.equal(stats.failures.length,0);assert.equal(stats.total,expected);console.log('Real logs:',JSON.stringify(stats));
      if(stats.groups.includes('A20N'))await page.locator('#aircraft').selectOption('A20N');await page.screenshot({path:'.tools/trends/real-overview.png',fullPage:true});
      await page.click('[data-tab="overlay"]');await page.screenshot({path:'.tools/trends/real-overlay.png',fullPage:true});await page.click('[data-tab="behavior"]');await page.screenshot({path:'.tools/trends/real-behavior.png',fullPage:true});
    }
    assert.deepEqual(errors,[]);assert.deepEqual(network,[]);console.log('Edge file://: import, dedup, grouping, filters, curves, evidence drilldown, raw text, CSV, mobile overflow and offline checks passed.');
  }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});

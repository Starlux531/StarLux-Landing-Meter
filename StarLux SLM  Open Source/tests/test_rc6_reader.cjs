const assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs');
const {pathToFileURL}=require('node:url'),{chromium}=require('playwright');
const {modernFixture}=require('./test_unified_reader.cjs');
(async()=>{
 const browser=await chromium.launch({channel:'msedge',headless:true}),page=await browser.newPage({viewport:{width:1500,height:1100}}),errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 // Synthetic record, maps disabled. No external service is needed for replay.
 await page.route('https://**',route=>route.abort());
 try{
  await page.goto(pathToFileURL(path.resolve('LMM_Report_Reader.html')).href);
  const raw=['G algorithm: touchdown-rc6-1','Observed touchdown peak G: 1.71','Bounce evidence: geometry_rebound',
   'LMM_TOUCH_EVENT\t1\t1\t1180\t1180.75\t1.6\t1.71\tdelayed\tvalid\t1180.40\t1180.56\t-170\tvelocity_settled',
   'LMM_TOUCH_EVENT\t1\t2\t1182\t1182.30\t1.2\t1.3\tfixed\tvalid\t1182\t1182.16\t-60\tvelocity_settled',modernFixture()].join('\n');
  await page.evaluate(async raw=>{await importFiles([new File([raw],'LMM_RC6.txt')],'main');setLanguage('en');focusTimeView('full')},raw);
  assert.equal(await page.evaluate(()=>activeRecord().report.touchdownEvents.length),2);
  assert.equal(await page.evaluate(()=>activeRecord().report.observedPeakG),1.71);
  assert((await page.locator('#diagnostics').innerText()).includes('Touchdown event 2'));
  const marks=await page.evaluate(()=>{
   const calls=[],ctx={save(){},restore(){},setLineDash(){},beginPath(){},moveTo(){},lineTo(){},stroke(){},fillText(s,x){calls.push([s,x])}};
   drawTouchdownEvents(ctx,activeRecord().report,t=>t,180,183,0,100);return calls;
  });assert.deepEqual(marks,[['TD 2',186]]);
  await page.evaluate(()=>{setTimeView(179,5);setPlaybackTime(182);setLanguage('zh')});
  assert((await page.locator('#diagnostics').innerText()).includes('接地事件 2'));
  assert.equal(await page.evaluate(()=>parseTouchdownEvents('LMM_TOUCH_EVENT\t1\tbad\t10\t9').length),0);
  fs.mkdirSync('.tools/rc6',{recursive:true});await page.locator('#diagnostics').screenshot({path:'.tools/rc6/events.png'});
  await page.evaluate(async raw=>{await importFiles([new File([raw],'LMM_old.txt')],'main')},modernFixture());
  assert.equal(await page.evaluate(()=>activeRecord().report.touchdownEvents.length),0);
  assert.equal(await page.evaluate(()=>activeRecord().report.status),'STABLE');
  assert.deepEqual(errors,[]);console.log('RC6 reader: event/peak metadata, timed contact marks, bilingual diagnostics, invalid rows, legacy rating preservation passed.');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});

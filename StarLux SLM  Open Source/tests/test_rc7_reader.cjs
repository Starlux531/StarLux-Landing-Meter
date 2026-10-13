const assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs');
const {pathToFileURL}=require('node:url'),{chromium}=require('playwright');
const {modernFixture}=require('./test_unified_reader.cjs');
(async()=>{
 const browser=await chromium.launch({channel:'msedge',headless:true}),page=await browser.newPage({viewport:{width:1450,height:1000}}),errors=[];
 page.on('pageerror',e=>errors.push(e.message));await page.route('https://**',r=>r.abort());
 try{
  await page.goto(pathToFileURL(path.resolve('LMM_Report_Reader.html')).href);
  for(const [code,label] of [['PHYSICAL','Physical'],['VVI','VVI'],['AGL','AGL estimate'],['','Source unrecorded']]){
   const raw=(code?'FPM source code: '+code+'\n':'')+modernFixture().replace('Touchdown vertical speed: -170 fpm',`Touchdown vertical speed: ${code?'['+code+'] ':''}-170 fpm`);
   await page.evaluate(async raw=>{await importFiles([new File([raw],'LMM_source.txt')],'main');setLanguage('en')},raw);
   assert.equal(await page.evaluate(()=>activeRecord().report.fpm),-170);
   assert((await page.locator('#fpmCard').innerText()).startsWith(label));
   assert((await page.locator('#fpmMeterValue').innerText()).startsWith(label));
  }
  assert.deepEqual(await page.evaluate(()=>['PHYSICAL','VVI','AGL'].map(fpmSource=>parseTouchdownEvents(`LMM_TOUCH_EVENT\t1\t2\t100\t101\t1.2\t1.3\tfixed\tvalid\t100\t100.16\t-150\tsettled\t${fpmSource}`)[0].fpmSource)),['PHYSICAL','VVI','AGL']);
  assert.equal(await page.evaluate(()=>pointFpmLabel({key:'fpm'},{fpmSource:'physical_velocity'},null)),'Physical FPM');
  await page.evaluate(()=>{setLanguage('zh');setThemeSeed('#26103C',false)});
  for(const width of [600,1450]){
   await page.setViewportSize({width,height:1000});await page.waitForTimeout(100);
   fs.mkdirSync('.tools/rc7',{recursive:true});await page.locator('#fpmCard').screenshot({path:`.tools/rc7/fpm-${width}.png`});
  }
  assert.deepEqual(errors,[]);console.log('RC7 reader: actual source prefixes, unknown legacy source, tagged numeric parsing, event source and timeline channel labels passed.');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});

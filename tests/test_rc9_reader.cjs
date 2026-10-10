const assert=require('node:assert/strict'),path=require('node:path'),fs=require('node:fs');
const {pathToFileURL}=require('node:url'),{chromium}=require('playwright');
const {modernFixture}=require('./test_unified_reader.cjs');
(async()=>{
 const browser=await chromium.launch({channel:'msedge',headless:true}),page=await browser.newPage({viewport:{width:1450,height:1000}}),errors=[];
 page.on('pageerror',e=>errors.push(e.message));await page.route('https://**',r=>r.abort());
 try{
  await page.goto(pathToFileURL(path.resolve('LMM_Report_Reader.html')).href);
  const raw=process.argv[2]?fs.readFileSync(process.argv[2],'utf8'):'Observed touchdown peak G: 1.250121\n'+modernFixture().replace('Final load: 1.16 G','Final load: 1.06 G');
  await page.evaluate(async raw=>{await importFiles([new File([raw],'LMM_RC9_peak.txt')],'main');setLanguage('zh');setThemeSeed('#26103C',false)},raw);
  assert.equal(await page.evaluate(()=>activeRecord().report.g),1.06);
  assert.equal(await page.evaluate(()=>activeRecord().report.observedPeakG),1.250121);
  const card=page.locator('#gCard');assert.match(await card.innerText(),/触地瞬时[\s\S]*1\.06 G[\s\S]*观测峰值[\s\S]*1\.25 G/);
  assert.equal(await page.locator('#flareHelp').innerText(),'数值越小拉平越平顺');
  assert.equal(await page.locator('#gMeterValue').innerText(),'1.06–1.25 G');
  assert(await page.locator('#gPointer').isVisible() && await page.locator('#gPeakPointer').isVisible());
  const range=await page.locator('#gRange').evaluate(el=>({left:parseFloat(el.style.left),width:parseFloat(el.style.width)}));
  assert(Math.abs(range.left-6)<.001 && Math.abs(range.width-19.0121)<.001);
  fs.mkdirSync('.tools/rc9-display',{recursive:true});
  for(const width of [1450,600]){
   await page.setViewportSize({width,height:1000});
   await page.locator('section.grid').screenshot({path:`.tools/rc9-display/cards-${width}.png`});
   await page.locator('#gMeter').locator('xpath=ancestor::section[1]').screenshot({path:`.tools/rc9-display/range-${width}.png`});
   assert(await card.evaluate(el=>el.scrollWidth<=el.clientWidth),'G card overflow');
  }
  await page.evaluate(()=>setLanguage('en'));
  assert.match(await card.innerText(),/Instantaneous touchdown[\s\S]*1\.06 G[\s\S]*Observed peak[\s\S]*1\.25 G/);
  assert.equal(await page.locator('#flareHelp').innerText(),'Lower values indicate a smoother flare');
  const legacy=modernFixture();
  await page.evaluate(async raw=>{await importFiles([new File([raw],'LMM_RC9_compare.txt')],'compare')},legacy);
  assert.match(await page.locator('#gCompareLine').innerText(),/Observed peak --/);
  assert.match(await page.locator('#compareMetrics').innerText(),/Observed peak G/);
  await page.evaluate(async raw=>{await importFiles([new File([raw],'LMM_RC9_legacy.txt')],'main')},legacy);
  assert.equal(await page.evaluate(()=>activeRecord().report.observedPeakG),null);
  assert.match(await card.innerText(),/Observed peak[\s\S]*--/);
  assert(await page.locator('#gPeakPointer').isHidden() && await page.locator('#gRange').isHidden());
  const events='LMM_TOUCH_EVENT\t1\t1\t1180\t1181\t1.16\t1.32\tfixed\tvalid\nLMM_TOUCH_EVENT\t1\t2\t1182\t1183\t1.2\t1.41\tfixed\tvalid\n';
  await page.evaluate(async raw=>{await importFiles([new File([raw],'LMM_RC9_events.txt')],'main')},events+legacy);
  assert.equal(await page.evaluate(()=>activeRecord().report.observedPeakG),1.41);
  assert.equal(await page.evaluate(()=>activeRecord().report.g),1.16);
  assert.deepEqual(await page.evaluate(()=>{
    const results=[];
    for(const [g,observedPeakG] of [[1.5,1.5],[1.6,1.2],[.8,2.4],[null,null]]){
      renderGRange({g,observedPeakG});results.push({left:parseFloat($('gRange').style.left),width:parseFloat($('gRange').style.width),hidden:$('gRange').hidden});
    }
    return results;
  }),[{left:50,width:0,hidden:false},{left:20,width:40,hidden:false},{left:0,width:100,hidden:false},{left:0,width:0,hidden:true}]);
  assert.deepEqual(await page.evaluate(()=>{
    const result=[];for(const text of ['下降率轨迹震荡高','Vertical-speed trend normal','High vertical-speed oscillation','下降率轨迹正常','']){
      colorFlare('flareHint',text);colorFlare('flareInsight',text);result.push($('flareHint').dataset.flareState);
    }return result;
  }),['warning','normal','warning','normal','unknown']);
  assert.deepEqual(errors,[]);
  console.log('RC9 reader: instant/observed G range, equal/reversed/clipped/missing markers, bilingual flare states, narrow cards, comparison and recorded-event fallback passed.');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});

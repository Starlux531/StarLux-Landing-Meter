const assert=require('node:assert/strict'),path=require('node:path');
const {pathToFileURL}=require('node:url'),{chromium}=require('playwright');
const {fixture}=require('./test_trends_analyzer.cjs');
(async()=>{
 const browser=await chromium.launch({channel:'msedge',headless:true}),page=await browser.newPage(),errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto(pathToFileURL(path.resolve('LMM_Report_Reader.html')).href);
  const raw=fixture().replace('v1.1.8','v1.1.9-beta8').replace('Final rating: Stable','Final rating: Attention')+
    '\n滑跑评价: 偏差超过7 m：至少黄色\nRollout assessment (EN): offset >7 m: at least ATTENTION\n滑跑已触发降级: 1\n滑跑考核状态: COMPLETE\n';
  await page.evaluate(async raw=>{await importFiles([new File([raw],'LMM_rollout.txt')],'main');setLanguage('zh')},raw);
  assert((await page.locator('#dominantInsight').textContent()).includes('滑跑降级'));
  assert((await page.locator('#warningInsight').textContent()).includes('COMPLETE'));
  assert.equal(await page.evaluate(()=>activeRecord().report.status),'ATTENTION');
  await page.evaluate(()=>setLanguage('en'));
  assert((await page.locator('#dominantInsight').textContent()).includes('offset >7 m'));
  assert(!/[\u4e00-\u9fff]/.test(await page.locator('#dominantInsight').textContent()));
  await page.evaluate(async raw=>{await importFiles([new File([raw],'LMM_legacy.txt')],'main')},fixture());
  assert.equal(await page.evaluate(()=>activeRecord().report.status),'STABLE');
  assert(!(await page.locator('#dominantInsight').textContent()).includes('Rollout penalty'));
  assert.deepEqual(errors,[]);console.log('Rollout report: recorded grade, bilingual explanation, phase and untouched legacy rating passed.');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});

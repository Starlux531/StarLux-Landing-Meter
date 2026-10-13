// Wind is arrows only from beta3. Wind angle wrap must not alter the LOC trace.
const assert=require('node:assert/strict'),path=require('node:path');
const {pathToFileURL}=require('node:url'),{chromium}=require('playwright'),{ilsFixture}=require('./ils_fixture.cjs');
(async()=>{
 const browser=await chromium.launch({channel:'msedge',headless:true}),page=await browser.newPage(),errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto(pathToFileURL(path.resolve('LMM_Report_Reader.html')).href);
  let expected=null;
  for(const phase of [0,180]){
   const raw=ilsFixture().split('\n').map(line=>{if(!line.startsWith('W\t'))return line;const row=line.split('\t'),t=Number(row[1])-1000;row[2]='12';row[3]=String(88+phase+3*Math.sin(t/4));row[6]=String(90+phase+3*Math.sin(t/4));return row.join('\t')}).join('\n');
   await page.evaluate(async raw=>{await importFiles([new File([raw],'LMM_wrap.txt')],'main');focusTimeView('full');setPlaybackTime(120)},raw);
   const d=await page.locator('[data-ils-curve]').getAttribute('d');assert.equal((d.match(/M/g)||[]).length,1);
   if(expected!==null)assert.equal(d,expected,'wind reversal must not change aircraft LOC trajectory');expected=d;
   assert.equal(await page.locator('[data-wind-curve]').count(),0);assert(await page.locator('[data-profile-wind]').count()>0);
   const wrap=await page.evaluate(()=>{const g={ux:0,uy:1};return [359,0,1].map(from_deg_true=>windVector({from_deg_true,speed_kt:12},g))});
   assert(wrap[0].x>0&&Math.abs(wrap[1].x)<1e-9&&wrap[2].x<0);assert(wrap.every(v=>v.y>.99));
  }
  assert.deepEqual(errors,[]);console.log('Headwind/tailwind wrap: arrows only, continuous LOC unaffected by wind direction passed.');
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});

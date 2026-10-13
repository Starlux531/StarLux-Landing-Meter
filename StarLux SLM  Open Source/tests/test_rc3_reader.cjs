const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {pathToFileURL}=require('node:url'),{chromium}=require('playwright');
const reportPath=process.argv[2];assert(reportPath,'Pass a real landing TXT path');
(async()=>{const browser=await chromium.launch({channel:'msedge',headless:true});
const page=await browser.newPage({viewport:{width:1450,height:1100}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
try{
 await page.goto(pathToFileURL(path.resolve('LMM_Report_Reader.html')).href);
 await page.evaluate(async raw=>{await importFiles([new File([raw],'LMM_RC3_fixture.txt')],'main');setLanguage('zh');setChartMode('separated');
   setActiveMetricKeys(['ra','physicalFpm','g']);renderMetricPicker();
   focusTimeView('full');},fs.readFileSync(reportPath,'utf8'));
 const result=await page.evaluate(()=>{
   const r=activeRecord().report;const metric=TRAJECTORY_METRICS.find(m=>m.group==='altitude');
   function scales(){return buildMetricScales(buildMetricSeries([metric],r.trajectory,[],r,null)).altitude}
   focusTimeView('full');const full=scales();focusTimeView('100');const near=scales();
   const reportValues=r.trajectory.map(p=>p[metric.key]);
   const view=chartTimeDomain(r,null);setTimeView(view.xmin+2,(view.xmax-view.xmin)*.5);const zoom=scales();
   const valuesUnchanged=reportValues.every((v,i)=>Object.is(v,r.trajectory[i][metric.key]));
   // Explicitly exercise common VVI group and comparison with a different extent.
   const current=chartTimeDomain(r,null),other={trajectory:[{t:current.xmin,ra:100},{t:current.xmax,ra:200}]};
   const paired=buildMetricScales(buildMetricSeries([metric],r.trajectory,other.trajectory,r,other)).altitude;
   return {full,near,zoom,paired,valuesUnchanged,metric:metric.key};
 });
 assert(result.full.max-result.full.min>2000);assert(result.near.max-result.near.min<200);assert(result.zoom.max-result.zoom.min<result.near.max-result.near.min);assert(result.valuesUnchanged);assert(result.paired.max>=200);
 await page.evaluate(()=>{focusTimeView('100');window.oldScales=JSON.stringify(ui.canvas._plot.scales);window.oldView=JSON.stringify(state.timeView)});
 const canvas=page.locator('#flareChart'),rect=await canvas.boundingBox();
 await canvas.dispatchEvent('mousemove',{clientX:rect.x+rect.width*.6,clientY:rect.y+80});await page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
 assert(await page.evaluate(()=>JSON.stringify(state.timeView)===oldView&&JSON.stringify(ui.canvas._plot.scales)===oldScales));
 await page.addStyleTag({content:'.topbar{position:static!important}'});
 await canvas.screenshot({path:'.tools/rc3/visible-window-chart.png'});
 assert.deepEqual(errors,[]);fs.writeFileSync('.tools/rc3/reader-verification.json',JSON.stringify({passed:true,...result},null,2));console.log(JSON.stringify({passed:true,...result}));
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1});

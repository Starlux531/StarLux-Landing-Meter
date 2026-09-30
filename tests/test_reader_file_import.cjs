// Exercise actual DOM file-picker and drag events, not only importFiles directly.
const {chromium}=require('playwright'),assert=require('node:assert/strict'),path=require('node:path'),{pathToFileURL}=require('node:url'),fs=require('node:fs');
const actual=process.argv[2],filename=actual?path.basename(actual):'LMM_legacy.TXT';
const content=actual?fs.readFileSync(actual,'utf8'):'StarLux LMM v1.1.8\nFinal rating: STABLE\nAggregated trajectory table\n0 100 -200\n1 50 -190\n2 0 -180\n\n';
(async()=>{const browser=await chromium.launch({channel:'msedge',headless:true});try{
  for(const html of ['LMM_Report_Reader.html','Starlux_Analyzer_落地分析器.html']){
    const page=await browser.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));await page.goto(pathToFileURL(path.resolve(html)).href);
    const choosing=page.waitForEvent('filechooser');await page.locator('#chooseFiles').click();const chooser=await choosing;
    await chooser.setFiles({name:filename,mimeType:'text/plain',buffer:Buffer.from(content)});await page.waitForFunction(()=>state.records.length===1&&!ui.report.hidden);
    assert.equal(await page.locator('#errorBox').textContent(),'');const count=await page.evaluate(()=>activeRecord().report.trajectory.length);assert(count>0);
    // Selecting nothing is cancellation, not an invalid report.
    await page.locator('#fileInput').dispatchEvent('change');assert.equal(await page.locator('#errorBox').textContent(),'');
    await page.evaluate(()=>{const d=new DataTransfer();d.setData('text/plain','D:/LMM_previous.txt');document.dispatchEvent(new DragEvent('drop',{dataTransfer:d,bubbles:true,cancelable:true}))});
    assert.match(await page.locator('#errorBox').textContent(),/路径|文本|path|text/);assert.equal(await page.evaluate(()=>state.records.length),1);
    await page.evaluate(()=>{const d=new DataTransfer();d.items.add(new File(['x'],'picture.png',{type:'image/png'}));document.dispatchEvent(new DragEvent('drop',{dataTransfer:d,bubbles:true,cancelable:true}))});
    assert.match(await page.locator('#errorBox').textContent(),/picture\.png/);
    await page.evaluate(({name,raw})=>{const d=new DataTransfer();d.items.add(new File([raw],name));document.dispatchEvent(new DragEvent('drop',{dataTransfer:d,bubbles:true,cancelable:true}))},{name:filename,raw:content});await page.waitForFunction(()=>!ui.error.textContent);
    await page.evaluate(async ({name,raw})=>{await handleFileDrop({dataTransfer:{files:[],items:[{kind:'file',getAsFile:()=>new File([raw],name)}],types:['Files']}})},{name:filename,raw:content});assert.equal(await page.locator('#errorBox').textContent(),'');
    await page.evaluate(()=>setLanguage('en'));
    await page.evaluate(()=>handleFileDrop({dataTransfer:{files:[],items:[],types:['Files']}}));assert.match(await page.locator('#errorBox').textContent(),/browser.*file/i);
    assert.deepEqual(errors,[]);console.log(`${html}: picker/drop read ${count} samples; cancel, text/path, wrong extension and file-item fallback passed.`);await page.close();
  }
}finally{await browser.close()}})().catch(e=>{console.error(e);process.exitCode=1});

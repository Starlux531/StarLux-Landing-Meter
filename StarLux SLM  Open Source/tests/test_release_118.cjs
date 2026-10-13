const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const root=path.join(__dirname,'..');
const presetJSON=JSON.parse(fs.readFileSync(path.join(root,'发行预设/analyzer-presets.json'),'utf8'));
assert.deepEqual(presetJSON.items.map(x=>x.name),['默认','黑暗玫瑰','巨峰葡萄','未来展厅','水晶紫罗兰']);
for(const item of presetJSON.items){assert(!item.createdAt&&!item.updatedAt);assert(item.id.startsWith('starlux-bundled-'));assert.deepEqual(Object.keys(item.settings).sort(),['charts','layout','theme']);assert.deepEqual(Object.keys(item.settings.theme),['seed']);}
let plugin='';
for(const file of ['LMM_Report_Reader.html','Starlux_Analyzer_落地分析器.html']){
  const source=fs.readFileSync(path.join(root,file),'utf8');
  const bundled=source.match(/<script type="application\/json" id="lmm-bundled-presets">([\s\S]*?)<\/script>/)[1];
  assert.deepEqual(JSON.parse(bundled),presetJSON);
  for(const match of source.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi))if(!match[0].includes('application/json'))new vm.Script(match[1]);
  assert(!/<script[^>]*\bsrc=|<link[^>]*\brel=["']stylesheet/i.test(source),'external dependency');
  const code=source.slice(source.indexOf('function normalizeUserPreset('),source.indexOf('let userPresets=loadUserPresets()'));
  function load(raw,throws=false){const ctx=vm.createContext({document:{getElementById(){return{textContent:bundled}}},localStorage:{getItem(){if(throws)throw Error('denied');return raw}},USER_PRESET_STORAGE_KEY:'test'});vm.runInContext(code,ctx);return JSON.parse(JSON.stringify(vm.runInContext('loadUserPresets()',ctx)));}
  assert.equal(load(null).length,5,'new profile seeded');
  const custom={id:'custom',name:'用户自己的',settings:{theme:{seed:'#123456'}}};
  assert.deepEqual(load(JSON.stringify({items:[custom]})).map(x=>x.name),['用户自己的'],'existing user list untouched');
  assert.equal(load('[]').length,0,'intentional deletion respected');
  assert.equal(load('{broken').length,0,'corrupt data not silently replaced');
  assert.equal(load(null,true).length,0,'storage-denied safe');
  if(file==='LMM_Report_Reader.html')plugin=source;
  else assert.equal(source,plugin.replaceAll('starlux-lmm-reader-','starlux-lmm-standalone-reader-').replace('<title>StarLux LMM 分析器</title>','<title>StarLux Analyzer · 落地分析器</title>'),'standalone differs only by title/storage namespace');
}
const readme=fs.readFileSync(path.join(root,'README.md'),'utf8');
const images=[...readme.matchAll(/<img src="([^"]+)"/g)].map(m=>m[1]);
assert.equal(images.length,9);assert.equal(images.filter(x=>x.endsWith('.gif')).length,2);
for(const image of ['QQ20260914-105006.png','QQ20260914-111931-HD.gif','QQ20260914-104414-3MB.gif'])assert(images.includes(`docs/images/${image}`),image);
assert(readme.includes('href="docs/images/QQ20260914-104414-HD.gif"'),'full original GIF remains accessible');
assert(!images.includes('docs/images/316f279efdc4f5dd509f893750489b25.gif'),'old demo no longer featured');
for(const image of images)assert(fs.existsSync(path.join(root,image)),image);
assert(!readme.includes('src="docs/images/report-reader-v1.1.4-'));
console.log('Release analyzer: syntax, 5 sanitized presets, existing-data preservation, independent storage, 9 gallery assets passed.');

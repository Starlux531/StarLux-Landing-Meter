const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '..', 'LMM_Report_Reader.html'), 'utf8');
for (const script of source.matchAll(/<script\b[^>]*>([\s\S]*?)<\/script>/gi)) {
  if (!script[0].includes('application/json')) new vm.Script(script[1]);
}
const start = source.indexOf('function setLanguage(language){');
const end = source.indexOf('\n}', start) + 2;
const code = source.slice(start, end);
for (const locked of [false, true]) for (const global of ['zh', 'en']) {
  const context = vm.createContext({window: {LMM_LANGUAGE_LOCKED: locked, LMM_DEFAULT_LANGUAGE: global},
    localStorage: {setItem() {}}, LANGUAGE_PREFERENCE_KEY: 'test', currentLanguage: global,
    applyStaticTranslations() {}, renderChartMode() {}, renderMetricPicker() {}, renderCurrent() {}});
  vm.runInContext(code, context);
  vm.runInContext(`setLanguage('${global === 'zh' ? 'en' : 'zh'}')`, context);
  assert.equal(context.currentLanguage, locked ? global : global === 'zh' ? 'en' : 'zh');
}
assert(source.includes('toggle.hidden=window.LMM_LANGUAGE_LOCKED===true'));
console.log('Reader syntax and 4 global/standalone language-switch cases passed.');

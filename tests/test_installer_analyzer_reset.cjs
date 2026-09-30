// Pass a reader installed with clean mode by the installer fixture suite.
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const original = fs.readFileSync(require('node:path').join(__dirname, '..', 'LMM_Report_Reader.html'), 'utf8');
const installed = fs.readFileSync(process.argv[2], 'utf8');
const hook = installed.match(/<!-- LMM_INSTALLER_RESET_START --><script>([\s\S]*?)<\/script><!-- LMM_INSTALLER_RESET_END -->/)[1];
const keys = [...original.matchAll(/const (?:\w+PREFERENCE_KEY|\w+STORAGE_KEY)="([^"]+)"/g)].map(m => m[1]);
assert(keys.length >= 9, 'all analyzer preferences located');
const data = new Map(keys.map(k => [k, 'user-preference']));
data.set('unrelated-app', 'keep'); data.set('starlux-lmm-standalone-reader-presets-v1', 'keep');
const storage = { get length() { return data.size; }, key(i) { return [...data.keys()][i]; }, getItem(k) { return data.get(k) ?? null; }, setItem(k,v) { data.set(k,v); }, removeItem(k) { data.delete(k); } };
vm.runInNewContext(hook, { localStorage: storage });
for (const key of keys) assert(!data.has(key), `not reset: ${key}`);
assert.equal(data.get('unrelated-app'), 'keep'); assert.equal(data.get('starlux-lmm-standalone-reader-presets-v1'), 'keep');
data.set(keys[0], 'new-settings'); vm.runInNewContext(hook, { localStorage: storage });
assert.equal(data.get(keys[0]), 'new-settings', 'same clean-install token must not reset again');
vm.runInNewContext(hook.replace(/const token="[^"]+"/, 'const token="next-clean-install"'), { localStorage: storage });
assert(!data.has(keys[0]), 'new clean install resets again');
vm.runInNewContext(hook, { get localStorage() { throw Error('Storage blocked'); } });
console.log(`${keys.length} analyzer preferences reset once; unrelated keys preserved; repeated clean install and blocked storage handled.`);

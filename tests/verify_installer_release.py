"""Verify installer artifacts and optional embedded plugin packages without installation."""
from pathlib import Path
import hashlib
import json
import zipfile
import argparse

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--installer-version', default='1.0.0')
parser.add_argument('--plugin-version', default='1.1.8')
args = parser.parse_args()
OUT = ROOT / 'dist/installer' / args.installer_version
sha = lambda raw: hashlib.sha256(raw).hexdigest()
meta = json.loads((OUT / 'installer-release.json').read_text(encoding='utf-8'))
assert meta['product'] == 'StarLux_LMM_Installer' and meta['version'] == args.installer_version
assert sha((OUT / meta['asset']).read_bytes()) == meta['sha256']
exe_name = 'StarLux_LMM_installer_安装器.exe'
with zipfile.ZipFile(OUT / meta['asset']) as update:
    assert set(update.namelist()) == {exe_name, 'installer-update.json'}
    manifest = json.loads(update.read('installer-update.json'))
    assert manifest['product'] == meta['product'] and manifest['version'] == meta['version']
    assert manifest['executable'] == exe_name
    assert sha(update.read(exe_name)) == manifest['sha256']
    assert update.read(exe_name) == (OUT / exe_name).read_bytes()
with zipfile.ZipFile(OUT / f'StarLux_LMM_Installer_v{args.installer_version}.zip') as bundle:
    assert {p.split('/')[0] for p in bundle.namelist()} == {exe_name, 'version'}
    assert bundle.read(exe_name) == (OUT / exe_name).read_bytes()
    manifests = [p for p in bundle.namelist() if p.endswith('/manifest.json') and '/fonts/' not in p]
    for path in manifests:
        package = json.loads(bundle.read(path))
        prefix = path.rsplit('/', 1)[0] + '/payload/'
        assert package['version'] == args.plugin_version, 'unexpected plugin included'
        assert package['uiVariant'] in ('sdk440', 'legacy')
        assert package['defaultLanguage'] in ('zh', 'en')
        expected = {prefix + item['path'] for item in package['files']}
        actual = {p for p in bundle.namelist() if p.startswith(prefix) and not p.endswith('/')}
        assert expected == actual
        for item in package['files']:
            assert sha(bundle.read(prefix + item['path'])) == item['sha256']
            assert not any(k in item['path'] for k in ('LMM_Settings.cfg', 'LMM_Log/', 'Cache'))
for line in (OUT / 'SHA256SUMS.txt').read_text(encoding='utf-8').splitlines():
    expected, name = line.split('  ', 1)
    assert sha((OUT / name).read_bytes()) == expected, name
print(f'Installer {args.installer_version} update manifests/EXE/archive hashes verified; {len(manifests)} completed plugin {args.plugin_version} packages verified.')

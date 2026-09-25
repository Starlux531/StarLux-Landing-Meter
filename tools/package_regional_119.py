"""Create CN/ASCII EN bundles and an explicit GitHub asset set after prepare_release_119.ps1."""
from pathlib import Path
import hashlib
import json
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[1]
meta = json.loads((ROOT / 'development.json').read_text(encoding='utf-8'))
assert meta['channel'] == 'stable' and meta['version'] in ('1.1.9','1.1.9rc2')
version = meta['version']
release = ROOT / 'dist' / version
bundle = release / f'StarLux_LMM_Installer_{version}.zip'
cn = release / f'StarLux_LMM_Installer_{version}_CN.zip'
en = release / f'StarLux_LMM_Installer_{version}_EN.zip'
shutil.copyfile(bundle, cn)
renames = {'StarLux_LMM_installer_安装器.exe': 'StarLux_LMM_Installer.exe',
           'Starlux_Analyzer_落地分析器.html': 'StarLux_Analyzer.html'}
with zipfile.ZipFile(bundle) as src, zipfile.ZipFile(en, 'w', zipfile.ZIP_DEFLATED) as dst:
    for item in src.infolist():
        name = '/'.join(renames.get(part, part) for part in item.filename.split('/'))
        assert name.isascii(), name
        dst.writestr(name, src.read(item.filename))
with zipfile.ZipFile(cn) as a, zipfile.ZipFile(en) as b:
    assert len(a.infolist()) == len(b.infolist())
    for item in a.infolist():
        renamed = '/'.join(renames.get(p, p) for p in item.filename.split('/'))
        assert a.read(item.filename) == b.read(renamed), renamed

publish = release / 'publish'
publish.mkdir(exist_ok=True)
names = [cn.name, en.name, f'Starlux_Analyzer_{version}.zip',
         f'StarLux_LMM_Installer_Only_{version}.zip', 'README_1.1.9.md', 'analyzer-presets.json']
names += [f'StarLux_LMM_v{version}-{variant}-{language}.zip'
          for variant in ('Standard', 'Compatibility') for language in ('CN', 'International')]
for name in names:
    shutil.copyfile(release / name, publish / name)
notes = f'RELEASE_NOTES_v{version}.md'
shutil.copyfile(ROOT / notes, publish / notes)
names.append(notes)
assert {p.name for p in publish.iterdir()} <= set(names) | {'SHA256SUMS.txt'}
def checksum(folder, items):
    return ''.join(hashlib.sha256((folder / name).read_bytes()).hexdigest() + '  ' + name + '\n'
                   for name in sorted(items))
(publish / 'SHA256SUMS.txt').write_text(checksum(publish, names), encoding='utf-8')
(release / 'SHA256SUMS.txt').write_text(checksum(release, [p.name for p in release.iterdir()
    if p.is_file() and p.name != 'SHA256SUMS.txt']), encoding='utf-8')
print(f'CN/EN contents verified; EN has only ASCII paths. {len(names)+1} GitHub assets: {publish}')

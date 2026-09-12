"""Validate only generated release files, never read live simulator/browser data."""
from pathlib import Path
import hashlib,json,sys,zipfile
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'.tools/python'))
from lupa.luajit21 import LuaRuntime
release=ROOT/'dist/1.1.8'
source=(ROOT/'StarLux_LMM_v1.1.8.lua').read_text(encoding='utf-8')
for variant in ('Standard','Compatibility'):
    for language in ('CN','International'):
        name=f'1.1.8-{variant}-{language}'
        package=release/'StarLux_LMM_Installer_1.1.8/version'/name
        manifest=json.loads((package/'manifest.json').read_text(encoding='utf-8'))
        assert manifest['version']=='1.1.8'
        assert manifest['uiVariant']==('sdk440' if variant=='Standard' else 'legacy')
        assert manifest['defaultLanguage']==('zh' if language=='CN' else 'en')
        expected=source
        if variant=='Compatibility': expected=expected.replace('force_compatibility = false','force_compatibility = true')
        if language=='International': expected=expected.replace('    document_language = "zh",','    document_language = "en",')
        actual=(package/'payload/StarLux_LMM_v1.1.8.lua').read_text(encoding='utf-8')
        assert actual==expected,'unexpected source divergence'
        LuaRuntime().execute('assert(loadstring(...))',actual)
        assert len(manifest['files'])==12
        with zipfile.ZipFile(release/f'StarLux_LMM_v{name}.zip') as archive:
            assert set(x.split('/')[0] for x in archive.namelist())=={'manifest.json','payload'}
            listed={'payload/'+f['path'] for f in manifest['files']}
            assert {x for x in archive.namelist() if not x.endswith('/')}==listed|{'manifest.json'}
            for entry in manifest['files']:
                raw=(package/'payload'/entry['path']).read_bytes()
                assert hashlib.sha256(raw).hexdigest()==entry['sha256']
                assert archive.read('payload/'+entry['path'])==raw
                assert not any(x in entry['path'] for x in ('LMM_Settings','LMM_Log','Cache','Viewer_Data'))
        print(name,'12 hashes, archive contents, Lua syntax, variant-only changes OK')
with zipfile.ZipFile(release/'StarLux_LMM_Installer_1.1.8.zip') as archive:
    assert {x.split('/')[0] for x in archive.namelist()}=={'StarLux_LMM_installer_安装器.exe','version'}
    assert archive.read('version/Starlux_Analyzer_落地分析器.html')==(ROOT/'Starlux_Analyzer_落地分析器.html').read_bytes()
    assert archive.read('version/analyzer-presets.json')==(ROOT/'发行预设/analyzer-presets.json').read_bytes()
    assert archive.read('StarLux_LMM_installer_安装器.exe')==(release/'StarLux_LMM_installer_安装器.exe').read_bytes()
for line in (release/'SHA256SUMS.txt').read_text(encoding='utf-8').splitlines():
    digest,name=line.split('  ',1)
    assert hashlib.sha256((release/name).read_bytes()).hexdigest()==digest
print('Portable root, independent analyzer, preset export and SHA256SUMS OK')

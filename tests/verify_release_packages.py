"""Validate only generated release files, never read live simulator/browser data."""
from pathlib import Path
import hashlib,json,sys,zipfile
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'.tools/python'))
from lupa.luajit21 import LuaRuntime
development=json.loads((ROOT/'development.json').read_text(encoding='utf-8'))
version=development['version']
assert (development['channel']=='stable' and version in ('1.1.9','1.1.9rc2')) or (development['channel']=='unpublished' and (version=='1.1.9rc2' or version.startswith(('1.1.9-beta','1.1.10-beta'))))
release=ROOT/'dist'/version
expected_files={f'StarLux_LMM_v{version}.lua','LMM_Report_Reader.html','README_1.1.9.md','LICENSE'}
expected_files.update('LMM_UI_119/'+name for name in ('native_popup.lua','layout.lua','dialog.lua','overlays.lua','core_inputs.lua','core_experience.lua','core_visual_state.lua','core_recording.lua','core_rollout.lua','core_ils.lua','core_updates.lua'))
expected_files.update('LMM_UI_119/fonts/'+name for name in ('LMMUI-Regular.otf','LMMUI-Medium.otf','LMMUI-Bold.otf','OFL.txt','manifest.json'))
source=(ROOT/'StarLux_LMM_v1.1.9.lua').read_text(encoding='utf-8')
for variant in ('Standard','Compatibility'):
    for language in ('CN','International'):
        name=f'{version}-{variant}-{language}'
        package=release/f'StarLux_LMM_Installer_{version}/version'/name
        manifest=json.loads((package/'manifest.json').read_text(encoding='utf-8'))
        assert manifest['version']==version
        assert manifest['build']==name
        assert manifest['uiVariant']==('sdk440' if variant=='Standard' else 'legacy')
        assert manifest['defaultLanguage']==('zh' if language=='CN' else 'en')
        expected=source
        if variant=='Compatibility': expected=expected.replace('force_compatibility = false','force_compatibility = true')
        if language=='International': expected=expected.replace('    document_language = "zh",','    document_language = "en",')
        actual=(package/f'payload/StarLux_LMM_v{version}.lua').read_text(encoding='utf-8')
        assert actual.startswith(f'-- StarLux 落地率插件 v{version}\n')
        assert actual==expected,'unexpected source divergence'
        LuaRuntime().execute('assert(loadstring(...))',actual)
        assert {entry['path'] for entry in manifest['files']}==expected_files
        assert len(manifest['files'])==len(expected_files)
        with zipfile.ZipFile(release/f'StarLux_LMM_v{name}.zip') as archive:
            assert set(x.split('/')[0] for x in archive.namelist())=={'manifest.json','payload'}
            listed={'payload/'+f['path'] for f in manifest['files']}
            assert {x for x in archive.namelist() if not x.endswith('/')}==listed|{'manifest.json'}
            for entry in manifest['files']:
                raw=(package/'payload'/entry['path']).read_bytes()
                assert hashlib.sha256(raw).hexdigest()==entry['sha256']
                assert archive.read('payload/'+entry['path'])==raw
                if entry['path'].endswith('.lua'): LuaRuntime().execute('assert(loadstring(...))',raw.decode('utf-8'))
                if entry['path'].startswith('LMM_UI_119/'):
                    assert raw==(ROOT/entry['path']).read_bytes(),'stale runtime module'
                assert not any(x in entry['path'] for x in ('LMM_Settings','LMM_Log','Cache','Viewer_Data'))
        print(name,len(expected_files),'hashes, archive contents, all Lua syntax, variant-only changes OK')
with zipfile.ZipFile(release/f'StarLux_LMM_Installer_{version}.zip') as archive:
    assert {x.split('/')[0] for x in archive.namelist()}=={'StarLux_LMM_installer_安装器.exe','version'}
    assert archive.read('version/Starlux_Analyzer_落地分析器.html')==(ROOT/'Starlux_Analyzer_落地分析器.html').read_bytes()
    assert archive.read('version/analyzer-presets.json')==(ROOT/'发行预设/analyzer-presets.json').read_bytes()
    assert archive.read('StarLux_LMM_installer_安装器.exe')==(release/'StarLux_LMM_installer_安装器.exe').read_bytes()
for line in (release/'SHA256SUMS.txt').read_text(encoding='utf-8').splitlines():
    digest,name=line.split('  ',1)
    assert hashlib.sha256((release/name).read_bytes()).hexdigest()==digest
print('Portable root, independent analyzer, preset export and SHA256SUMS OK')

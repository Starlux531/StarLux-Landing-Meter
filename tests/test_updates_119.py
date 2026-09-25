import tempfile
import subprocess
import base64
import unittest
from pathlib import Path
import test_ui_119 as baseline
from test_legacy_compat_119 import LEGACY

class UpdatesTests(unittest.TestCase):
    def module(self):
        l=baseline.runtime();l.execute("updates=assert(loadfile(ROOT..'LMM_UI_119/core_updates.lua'))()")
        return l

    def test_versions_and_invalid_tags(self):
        l=self.module()
        for newer,old,expected in [('1.1.9rc2','1.1.9',True),('1.1.9','1.1.9rc2',False),('1.1.9rc3','1.1.9rc2',True),('1.1.10','1.1.9rc2',True),('1.1.10-beta2','1.1.9rc2',True),('1.1.9rc2','1.1.10-beta2',False),('installer-9.0.0','1.1.9rc2',False),('1.1.9-rc2','1.1.9',False)]:
            self.assertEqual(l.globals().updates.newer(newer,old),expected)

    def test_cache_interval_failure_and_persistent_notice(self):
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory)/'cache.txt';l=self.module();l.globals().cache=str(p)
            l.execute("now=100000; launched=0; u=updates.new({current='1.1.9rc2',path=cache,clock=function()return now end,launch=function()launched=launched+1;return true end})")
            l.execute('u:tick();assert(launched==1 and u.pending);u:tick();assert(launched==1)')
            p.write_text('100000\nv1.1.9\nv1.1.10\n',encoding='utf-8')
            l.execute("u:tick();assert(u.available and u.latest=='1.1.10' and not u.pending);now=100100;u:tick();assert(u.available and now>u.toast_until and launched==1)")
            p.unlink();l.execute('now=121700;u:tick();assert(launched==2);now=121746;u:tick();assert(not u.pending and u.available);now=121800;u:tick();assert(launched==2)')
            p.write_text('121800\nv1.1.10\n',encoding='utf-8')
            l.execute("u.current='1.1.10';u:tick();assert(not u.available)")
            l.execute("u.current='1.1.9rc2';u:tick();assert(u.available)")
            p.write_text('121800\n',encoding='utf-8')
            l.execute("u:tick();assert(not u.available and u.latest==nil)")

    def test_worker_script_is_fixed_read_only_github_query(self):
        l=self.module();s=l.globals().updates.script("D:/sim user's/日志/.update.txt",'Compatibility')
        self.assertIn("sim user''s",s);self.assertIn('-TimeoutSec 15',s)
        self.assertIn('!$_.prerelease',s);self.assertIn('-Compatibility-*.zip',s)
        self.assertIn('api.github.com/repos/Starlux531/StarLux-Landing-Meter/releases?',s)
        folder=baseline.ROOT/'.tools/rc2';folder.mkdir(exist_ok=True)
        (folder/'worker-syntax.ps1').write_text(s,encoding='utf-8-sig')

    def test_legacy_language_and_notice_visible_in_settings(self):
        l=baseline.RecorderTests().load_recorder(setup=LEGACY)
        l.execute(r'''
            ui.native_ui.force_compatibility=true
            labels={};texts={};local radio=imgui.RadioButton
            imgui.RadioButton=function(s,b) labels[#labels+1]=s;return radio(s,b) end
            imgui.TextUnformatted=function(s) texts[#texts+1]=s end
            ui.updates={available=true,latest='1.1.10'}
            ma_build_settings_window(nil,0,0,imgui)
            assert(table.concat(labels,'\n'):find('Chinese##lmm_language_zh',1,true))
            assert(table.concat(texts,'\n'):find('Open StarLux Installer',1,true))
            ui.updates.available=false;texts={};ma_build_settings_window(nil,0,0,imgui)
            assert(not table.concat(texts,'\n'):find('Update available',1,true))
        ''')

    def test_worker_filters_actual_response_and_unicode_output(self):
        with tempfile.TemporaryDirectory() as directory:
            out=Path(directory)/"user's-日志.txt";script=Path(directory)/'mock.ps1';l=self.module()
            mock=r'''
function Invoke-RestMethod {
 param($Uri,$Headers,$TimeoutSec)
 if($TimeoutSec -ne 15){throw 'timeout missing'}
 @(
  @{tag_name='v1.1.9';draft=$false;prerelease=$false;assets=@(@{name='StarLux_LMM_v1.1.9-Standard-CN.zip'})},
  @{tag_name='v1.1.9rc2';draft=$false;prerelease=$false;assets=@(@{name='StarLux_LMM_v1.1.9rc2-Compatibility-CN.zip'})},
  @{tag_name='v1.1.10';draft=$false;prerelease=$true;assets=@(@{name='StarLux_LMM_v1.1.10-Compatibility-CN.zip'})},
  @{tag_name='v1.2.0';draft=$true;prerelease=$false;assets=@(@{name='StarLux_LMM_v1.2.0-Compatibility-CN.zip'})}
 )
}
'''
            script.write_text(mock+l.globals().updates.script(str(out),'Compatibility'),encoding='utf-8-sig')
            encoded=base64.b64encode(script.read_text(encoding='utf-8-sig').encode('utf-16le')).decode('ascii')
            result=subprocess.run(['powershell','-NoProfile','-NonInteractive','-EncodedCommand',encoded],capture_output=True,timeout=30)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(out.read_text(encoding='utf-8').splitlines()[1:],['v1.1.9rc2'])

if __name__=='__main__':unittest.main()

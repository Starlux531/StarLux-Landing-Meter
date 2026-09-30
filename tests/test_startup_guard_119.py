"""Missing/broken installation must not throw out of the main Lua chunk."""
import unittest
import test_ui_119 as baseline
from test_legacy_compat_119 import LEGACY

CORE = ('core_inputs.lua', 'core_visual_state.lua', 'core_experience.lua',
        'core_recording.lua', 'core_rollout.lua', 'core_ils.lua')
CAPTURE = r'''
    frame_callbacks={}; draw_callbacks={}; diagnostic=''; diagnostic_closed=false
    function do_every_frame(s) frame_callbacks[#frame_callbacks+1]=s end
    function do_every_draw(s) draw_callbacks[#draw_callbacks+1]=s end
    local open=io.open
    io.open=function(path,mode)
        if path:find('LMM_Startup_Diagnostic.txt',1,true) then
            return {write=function(self,s) diagnostic=diagnostic..s end,
                    close=function() diagnostic_closed=true end}
        end
        return open(path,mode)
    end
'''

class StartupGuardTests(unittest.TestCase):
    def failed(self, setup):
        l=baseline.RecorderTests().load_recorder(setup=CAPTURE+setup, allow_startup_failure=True)
        l.execute(r'''
            assert(ma_landing_meter_update==nil and ma_landing_meter_draw==nil)
            assert(#frame_callbacks==0 and #draw_callbacks==1)
            assert(#macros==1 and #settings_writes==0)
            assert(loadstring(draw_callbacks[1]))()
            assert(loadstring(macros[1].code))()
            assert(table.concat(logs,'\n'):find('STARTUP FAILED',1,true))
            another_script_ran=true
        ''')
        return l

    def test_each_required_module_missing(self):
        for name in CORE:
            with self.subTest(name=name):
                l=self.failed("local original=loadfile; loadfile=function(p) if p:find('"+name+"',1,true) then return nil,'No such file' end return original(p) end")
                self.assertIn(name, l.globals().diagnostic)
                self.assertTrue(l.globals().diagnostic_closed)

    def test_all_required_modules_missing_lists_every_file(self):
        l=self.failed("loadfile=function() return nil,'missing directory' end")
        for name in CORE:
            self.assertIn(name,l.globals().diagnostic)

    def test_compile_failure_throw_and_constructor_failure(self):
        for effect in ("return nil,'syntax error'", "error('read error')",
                       "return function() error('init error') end",
                       "return function() return nil end"):
            with self.subTest(effect=effect):
                self.failed("local original=loadfile; loadfile=function(p) if p:find('core_recording.lua',1,true) then "+effect+" end return original(p) end")

    def test_diagnostic_io_failure_and_optional_notice_helpers(self):
        for action in ("return nil", "error('permission denied')",
                       "return {write=function() error('disk full') end, close=function() end}"):
            with self.subTest(action=action):
                self.failed("loadfile=function() return nil,'missing' end; io.open=function() "+action+" end; draw_string=nil")
        l=baseline.RecorderTests().load_recorder(setup="loadfile=function() return nil,'missing' end; logMsg=nil; add_macro=nil; do_every_draw=nil",allow_startup_failure=True)
        self.assertIsNone(l.globals().ma_landing_meter_update)

    def test_complete_repair_uses_legacy_callbacks_without_sdk440(self):
        source=(baseline.ROOT/'StarLux_LMM_v1.1.9.lua').read_text(encoding='utf-8-sig').replace('force_compatibility = false','force_compatibility = true')
        l=baseline.RecorderTests().load_recorder(source=source,setup=LEGACY)
        l.execute('''
            for i=1,3 do ma_landing_meter_update();ma_landing_meter_draw();draw_legacy_windows() end
            ma_open_settings_window();ma_open_log_manager();draw_legacy_windows()
            assert(not ui.dev.render_error,ui.dev.render_error)
            assert(calls.fonts==0 and #macros==2)
            assert(ui.native_ui.force_compatibility and not ui.native_ui.instance)
        ''')

if __name__=='__main__': unittest.main()

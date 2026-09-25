"""Exercise current Compatibility code with the legacy floating-window callbacks.

The SDK-440 mock is deliberately unavailable. Window and ImGui argument checks
follow FlyWithLua's FLWIntegration.cpp/imgui_iterator.inl, rather than silently
accepting every call. This is a binding double, not an X-Plane 12.4.3 flight test.
"""
import unittest
import zipfile
import test_ui_119 as baseline
from test_ui_119 import ROOT

LEGACY = r'''
SUPPORTS_FLOATING_WINDOWS=1
api.XPLMGetVersions=function(x,s,h) x[0]=12430;s[0]=430;h[0]=1 end
for _,name in ipairs({'XPLMCreateFont','XPLMFontDrawString','XPLMPolygon'}) do api[name]=nil end
windows={}; stack=0; gui_calls=0; hovered=false; active=false; mouse_down=false
local function num(v) assert(type(v)=='number' and v==v, 'numeric argument expected') end
local function wnd(v) assert(windows[v] and not windows[v].destroyed,'invalid window handle');return windows[v] end
function float_wnd_create(w,h,decoration,imgui)
    num(w);num(h);num(decoration);assert(type(imgui)=='boolean')
    local id={};windows[id]={w=w,h=h};return id
end
function float_wnd_set_imgui_builder(w,b) wnd(w).builder=b;assert(type(b)=='string') end
function float_wnd_set_onclose(w,b) wnd(w).close=b end
function float_wnd_set_title(w,t) wnd(w).title=t;assert(type(t)=='string') end
function float_wnd_set_position(w,x,y) wnd(w);num(x);num(y) end
function float_wnd_set_geometry(w,l,t,r,b) wnd(w);num(l);num(t);num(r);num(b);assert(r>l and t>b) end
function float_wnd_destroy(w) wnd(w).destroyed=true end
local function string_arg(s) assert(type(s)=='string');gui_calls=gui_calls+1 end
imgui={constant={Col={Text=0,Button=21,ButtonHovered=22,ButtonActive=23}},
    PushStyleColor=function(i,c) num(i);num(c);assert(c>=0 and c<=4294967295 and c==math.floor(c));stack=stack+1 end,
    PopStyleColor=function() assert(stack>0);stack=stack-1 end,
    Button=function(s,w,h) string_arg(s);if w then num(w);num(h) end;return false end,
    RadioButton=function(s,b) string_arg(s);assert(type(b)=='boolean');return false end,
    Checkbox=function(s,b) string_arg(s);assert(type(b)=='boolean');return false,b end,
    SliderFloat=function(s,v,a,b,fmt) string_arg(s);num(v);num(a);num(b);assert(type(fmt)=='string', "bad argument #5 to 'SliderFloat' (string expected)");return false,v end,
    SliderInt=function(s,v,a,b,fmt) string_arg(s);num(v);num(a);num(b);assert(type(fmt)=='string', "bad argument #5 to 'SliderInt' (string expected)");return false,v end,
    TextUnformatted=string_arg,SetTooltip=string_arg,
    BeginCombo=function(s,v) string_arg(s);string_arg(v);return false end,
    EndCombo=function()end,Selectable=function(s)string_arg(s);return false end,SetItemDefaultFocus=function()end,
    IsItemHovered=function() return hovered end,IsItemActive=function() return active end,
    IsMouseDown=function(i)num(i);return mouse_down end,
    GetCursorPosX=function()return 8 end,GetCursorPosY=function()return 8 end,
    SetCursorPosX=num,SetCursorPosY=num,SameLine=function()end,Separator=function()end}
function draw_legacy_windows()
    for w,v in pairs(windows) do if not v.destroyed and v.builder then
        assert(type(_G[v.builder])=='function',v.builder)
        _G[v.builder](w,0,0);assert(stack==0,'unbalanced ImGui colors')
    end end
end
'''


class LegacyCompatibilityTests(unittest.TestCase):
    def load_package(self, language='CN', cfg='runway_detection_enabled=false\n'):
        source=(ROOT/'StarLux_LMM_v1.1.9.lua').read_text(encoding='utf-8-sig')
        source=source.replace('force_compatibility = false','force_compatibility = true')
        if language=='International':source=source.replace('    document_language = "zh",','    document_language = "en",')
        return baseline.RecorderTests().load_recorder(source=source, setup=LEGACY, cfg=cfg)

    def test_current_compatibility_startup_callbacks_and_all_windows(self):
        for language in ('CN','International'):
            with self.subTest(language=language):
                l=self.load_package(language)
                l.execute('''
                    assert(ui.native_ui.force_compatibility)
                    for i=1,3 do ma_landing_meter_update();ma_landing_meter_draw();draw_legacy_windows() end
                    assert(not ui.dev.render_error,ui.dev.render_error)
                    assert(calls.fonts==0 and not ui.native_ui.instance and #macros==2)
                    assert(ui.dev.legacy.settings and ui.dev.legacy.records)
                    ma_open_settings_window();ma_open_log_manager();draw_legacy_windows()
                    ui.dev.config.stick=true;ui.dev.config.throttle=true;ui.dev.config.n1=true
                    for _,debug_mode in ipairs({false,true}) do
                        ui.dev:present(nil,debug_mode,true);draw_legacy_windows()
                    end
                    assert(gui_calls>100)
                    for _,id in ipairs({'stick','throttle','n1'}) do ui.dev.config[id..'_collapsed']=true end
                    ui.dev:present(nil,false,true);draw_legacy_windows()
                    ma_lmm118_shutdown()
                ''')

    def test_optional_legacy_helpers_absent(self):
        l=self.load_package()
        l.execute('''
            float_wnd_set_geometry=nil
            for _,name in ipairs({'IsItemHovered','IsItemActive','IsMouseDown',
                'GetCursorPosX','GetCursorPosY','SetCursorPosX','SetCursorPosY','SetTooltip'}) do imgui[name]=nil end
            ma_landing_meter_update();ma_landing_meter_draw();draw_legacy_windows()
            ma_open_settings_window();ma_open_log_manager();draw_legacy_windows()
            assert(not ui.dev.render_error and calls.fonts==0)
        ''')

    def test_original_release_and_beta1_reproduce_reported_slider_failure(self):
        # Use both frozen main AND matching module bytes, not current modules.
        for version in ('1.1.9','1.1.10-beta1'):
            with self.subTest(version=version):
                with zipfile.ZipFile(ROOT/f'dist/{version}/StarLux_LMM_v{version}-Compatibility-CN.zip') as z:
                    source=z.read(f'payload/StarLux_LMM_v{version}.lua').decode('utf-8')
                    module=z.read('payload/LMM_UI_119/core_experience.lua').decode('utf-8')
                # Lua long string keeps source literal without quote escaping.
                assert ']====]' not in module
                setup=LEGACY+'\nlocal frozen=[====['+module+']====]\n'+r'''
                    local original=loadfile
                    loadfile=function(path)
                        if path:find('core_experience.lua',1,true) then return loadstring(frozen,'@frozen/core_experience.lua') end
                        return original(path)
                    end
                '''
                l=baseline.RecorderTests().load_recorder(source=source,setup=setup)
                with self.assertRaisesRegex(Exception,"bad argument #5 to 'SliderInt'"):
                    l.execute('ma_open_settings_window();draw_legacy_windows()')

    def test_all_settings_sliders_accept_required_format_and_save_values(self):
        for language in ('zh','en'):
            l=self.load_package(cfg='runway_detection_enabled=false\ndocument_language='+language+'\n')
            l.execute(r'''
                ui.native_ui.instance={ready=true} -- exercise font-size branch too
                slider_labels={}
                local strict=imgui.SliderInt
                imgui.SliderInt=function(label,value,lo,hi,format)
                    strict(label,value,lo,hi,format)
                    assert(format=='%d')
                    slider_labels[label]=true
                    if label:find('##live_edge_alpha',1,true) then return true,42 end
                    if label:find('##lmm_font_px',1,true) then return true,22 end
                    return false,value
                end
                for appearance=1,4 do
                    ui.dev.config.appearance=appearance
                    ma_build_settings_window(nil,0,0,imgui)
                    ui.dev:settings(imgui,function(zh,en)return en end,true,function()end)
                end
                assert(ui.dev.config.edge_alpha==42 and ui.popup_style.font_px==22)
                assert(#settings_writes>0)
                local count=0;for _ in pairs(slider_labels)do count=count+1 end
                assert(count==21,'all 8 basic, 12 per-widget style and 1 font controls covered')
            ''')

    def test_new_required_modules_explain_main_script_only_upgrade_failure(self):
        setup=LEGACY+r'''
            local original_loadfile=loadfile
            loadfile=function(path)
                if path:find('/LMM_UI_119/',1,true) or path:find('/LMM_UI_118/',1,true) then
                    return nil,'cannot open '..path..': No such file or directory'
                end
                return original_loadfile(path)
            end
        '''
        old=(ROOT/'tests/fixtures/v1.1.8/StarLux_LMM.lua').read_text(encoding='utf-8-sig')
        old=old.replace('force_compatibility = false','force_compatibility = true')
        old_runtime=baseline.RecorderTests().load_recorder(source=old,setup=setup)
        old_runtime.execute('ui.native_initialize();assert(#macros==2 and not ui.native_ui.instance)')
        with zipfile.ZipFile(ROOT/'dist/1.1.9/StarLux_LMM_v1.1.9-Compatibility-CN.zip') as z:
            new=z.read('payload/StarLux_LMM_v1.1.9.lua').decode('utf-8')
        with self.assertRaisesRegex(Exception,r'core_experience\.lua.*No such file'):
            baseline.RecorderTests().load_recorder(source=new,setup=setup)


if __name__=='__main__':unittest.main(verbosity=2)

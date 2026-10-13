"""Offline LuaJIT + SDK-double regression. Never loads the real XPLM DLL.

Run: <python> tests/test_ui_118.py
Dependencies: .tools/python (lupa 2.8 and fonttools 4.65.0).
These tests cannot certify actual Vulkan rendering or FlyWithLua reload hooks.
"""
from pathlib import Path
import re
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.tools/python'))
from lupa.luajit21 import LuaRuntime


def runtime():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().ROOT = ROOT.as_posix() + '/'
    lua.execute(r'''
        ffi = require('ffi')
        calls = {fonts=0, destroyed_fonts=0, windows=0, destroyed_windows=0, drawings={}, measures=0}
        function countchars(s)
            local n=0
            for c in s:gmatch('[%z\1-\127\194-\244][\128-\191]*') do n=n+1 end
            return n
        end
        api = {}
        function api.XPLMGetVersions(x, s, h) x[0]=12440; s[0]=440; h[0]=1 end
        function api.XPLMCreateFont() calls.fonts=calls.fonts+1; return ffi.cast('void *', calls.fonts) end
        function api.XPLMDestroyFont() calls.destroyed_fonts=calls.destroyed_fonts+1 end
        function api.XPLMFontAddFace(font, path) return 1 end
        function api.XPLMFontGetMetrics(font, px, m)
            assert(m[0].structSize==16)
            m[0].lineHeight=px*1.2; m[0].lineAscent=px*0.95; m[0].lineDescent=px*0.25
        end
        function api.XPLMFontMeasureString(font, px, text)
            calls.measures=calls.measures+1
            return countchars(text)*px*(0.65+tonumber(ffi.cast('intptr_t', font))*0.04)
        end
        function api.XPLMCreateWindowEx(spec)
            assert(spec.structSize==112, 'SDK 440 64-bit window ABI')
            assert(ffi.offsetof('LMM118_WindowSpec', 'contentType')==88)
            assert(spec.contentType==1)
            calls.spec=ffi.new('LMM118_WindowSpec',spec)
            calls.windows=calls.windows+1
            calls.window_states=calls.window_states or {}
            calls.window_states[calls.windows]={visible=spec.visible,g={spec.left,spec.top,spec.right,spec.bottom}}
            return ffi.cast('void *', calls.windows)
        end
        function api.XPLMDestroyWindow() calls.destroyed_windows=calls.destroyed_windows+1 end
        function window_index(w) return tonumber(ffi.cast('intptr_t',w)) end
        function api.XPLMSetWindowIsVisible(w, v) calls.visible=v; calls.window_states[window_index(w)].visible=v end
        function api.XPLMSetWindowGeometry(w,l,t,r,b) calls.geometry={l,t,r,b}; calls.window_states[window_index(w)].g=calls.geometry end
        function api.XPLMGetWindowGeometry(w,l,t,r,b)
            local g=calls.window_states[window_index(w)].g
            l[0]=g[1]; t[0]=g[2]; r[0]=g[3]; b[0]=g[4]
        end
        function api.XPLMGetWindowIsVisible(w) return calls.window_states[window_index(w)].visible end
        function api.XPLMSetWindowTitle(w,t) calls.window_states[window_index(w)].title=t end
        function api.XPLMSetWindowResizingLimits() end
        function api.XPLMGetScreenBoundsGlobal(l,t,r,b)
            l[0]=-1920; t[0]=1080; r[0]=0; b[0]=0
        end
        function api.XPLMPolygon(c,v,n)
            assert(native_context, 'Panel Graphics outside native callback')
            assert(n==4)
            calls.polygons=(calls.polygons or 0)+1
        end
        function api.XPLMFontDrawString(f,c,s,x,y,t,j)
            assert(native_context, 'Font draw outside native callback')
            calls.drawings[#calls.drawings+1]={font=f,color=c,size=s,x=x,y=y,text=t}
        end
        ffi.load=function() return api end
        function load_native()
            native=assert(loadfile(ROOT..'LMM_UI_118/native_popup.lua'))(ROOT..'LMM_UI_118/')
            host=native.new({system='IBM',root='sim/',assets=ROOT..'LMM_UI_118/'})
        end
        function sample_frame()
            return {lines={'A20N | ZGNN | RWY05','接地报告已生成'},size=18,weight='normal',
                vertical=false,color={0.2,0.7,0.3},text_color={1,1,1},alpha=0.3,
                position=function(sw,sh,w,h) return 30,sh-h-30 end}
        end
        function paint()
            native_context=true
            calls.spec.drawWindowFunc(nil,nil)
            native_context=false
        end
    ''')
    return lua


class NativeTests(unittest.TestCase):
    def test_abi_draw_unicode_weight_and_blink(self):
        l = runtime()
        l.execute('''
            load_native(); assert(host.ready,host.error)
            f=sample_frame(); host:present(f); paint()
            assert(#calls.drawings==2 and calls.drawings[2].text=='接地报告已生成')
            assert(calls.geometry[1]<0, 'negative global desktop origin lost')
            w,h=host.layout.width,host.layout.height
            measurements=calls.measures
            for _,weight in ipairs({'normal','medium','bold'}) do
                f.weight=weight; host:present(f); paint()
                assert(host.layout.width==w and host.layout.height==h)
            end
            assert(calls.measures==measurements, 'layout rebuilt for weight')
            calls.drawings={}; f.hidden_line=2; host:present(f); paint()
            assert(#calls.drawings==1 and host.layout.height==h)
            assert(calls.measures==measurements, 'layout rebuilt for flash')
            host:hide(); assert(calls.visible==0)
            host:destroy(); host:destroy()
            assert(calls.destroyed_fonts==3 and calls.destroyed_windows==1)
        ''')

    def test_missing_symbol_old_version_and_font_failure(self):
        for setup, expected_fonts in [
            ('api.XPLMFontDrawString=nil', 0),
            ('api.XPLMGetVersions=function(x,s,h) x[0]=124300; s[0]=430; h[0]=1 end', 0),
            ('api.XPLMFontAddFace=function() return 0 end', 1),
        ]:
            with self.subTest(setup=setup):
                l=runtime()
                l.execute(setup + '; load_native(); assert(not host.ready and host.error)')
                self.assertEqual(l.eval('calls.fonts'), expected_fonts)
                self.assertEqual(l.eval('calls.destroyed_fonts'), expected_fonts)
                self.assertEqual(l.eval('calls.windows'), 0)

    def test_callback_error_and_reinitialization(self):
        l=runtime()
        l.execute('''
            load_native(); assert(host.ready,host.error)
            host:present(sample_frame())
            api.XPLMPolygon=function() error('injected render failure') end
            paint(); assert(not host.ready and host.error:find('injected'))
            assert(calls.destroyed_windows==0, 'freed callback while running')
            host:destroy(); load_native(); assert(host.ready,host.error)
            assert(calls.fonts==6 and calls.destroyed_fonts==3)
            host:destroy()
        ''')


class LayoutTests(unittest.TestCase):
    def test_size_wrap_and_weight_envelope(self):
        l=runtime()
        l.execute('''
            layout=dofile(ROOT..'LMM_UI_118/layout.lua')
            assert(layout.clamp_size('nan')==14 and layout.clamp_size(100)==32)
            assert(layout.clamp_size(0)==10 and layout.clamp_size(0/0)==14)
            for _,px in ipairs({10,14,18,24,32}) do
                for _,vertical in ipairs({true,false}) do
                    local lines={'A20N | ZGNN | RWY 05',
                        '发生弹跳 | 正在分析第二次触地',
                        'Centreline: calculating; landing report generated',
                        'ABCDEFGHIJKLMN012345678901234567890123456789'}
                    local measure=function(s,p) return countchars(s)*p end
                    local a=layout.build(lines,px,320,900,vertical,
                        function(p) return p*.9,p*.3,p*1.2 end,measure)
                    assert(a.width<=320 and a.height<=900)
                    assert(not a.truncated)
                    for _,row in ipairs(a.rows) do
                        assert(measure(row.text,a.size)<=320-a.left-a.pad)
                    end
                    assert(a.rows[1].source==1)
                end
            end
            local chars=layout.characters('中文ABC°')
            assert(#chars==6 and chars[1]=='中' and chars[6]=='°')
            local narrow=layout.build({'这是非常长的一行文字','Second line'},32,150,95,false,
                function(p) return p,p*.2,p*1.2 end,function(s,p) return countchars(s)*p end)
            assert(narrow.height<=95 and narrow.size<32)
        ''')

    def test_real_font_coverage_and_license(self):
        from fontTools.ttLib import TTFont
        text = (ROOT/'StarLux_LMM_v1.1.8.lua').read_text(encoding='utf-8-sig')
        needed = {ord(c) for c in text if '\u4e00' <= c <= '\u9fff'}
        for weight in ('Regular','Medium','Bold'):
            f=TTFont(ROOT/f'LMM_UI_118/fonts/LMMUI-{weight}.otf')
            self.assertFalse(needed - set(f.getBestCmap()))
            self.assertEqual(f['OS/2'].usWeightClass, {'Regular':400,'Medium':500,'Bold':700}[weight])
            f.close()
        self.assertIn('SIL OPEN FONT LICENSE', (ROOT/'LMM_UI_118/fonts/OFL.txt').read_text())


class RecorderTests(unittest.TestCase):
    def test_separate_menus_and_dialog_pages(self):
        l=self.load_recorder()
        l.execute('''
            assert(#macros==2)
            assert(macros[1].code=='ma_open_settings_window()')
            assert(macros[2].code=='ma_open_log_manager()')
            assert(commands['starlux/lmm/open_settings'] and commands['starlux/lmm/open_records'])
            ma_open_settings_window(); host=ui.native_ui.instance; d=host.dialogs.settings
            for _,lang in ipairs({'zh','en'}) do
                ui.set_global_language(lang)
                for _,w in ipairs({520,860,1200}) do
                    api.XPLMSetWindowGeometry(d.window,0,900,w,0)
                    for _,page in ipairs({'general','position','colors','fonts','tools'}) do
                        ui.settings_ui_tab=page; d.scroll=0; d:tick(); d:tick()
                        local sections=0
                        for _,c in ipairs(d.commands) do
                            if c.kind=='section' then sections=sections+1 end
                            assert(c.x>=0 and c.x+c.w<=w-20)
                            if c.rows and c.kind~='slider' then
                                local pad=(c.kind=='radio' or c.kind=='check') and 46 or 28
                                for _,line in ipairs(c.rows) do assert(d:measure(line)<=c.w-pad+0.01,line) end
                            end
                            if c.id=='lmm_language_en' or c.id=='lmm_language_zh' then assert(#c.rows==1,'short label wraps') end
                        end
                        assert(sections>=2)
                        for i,a in ipairs(d.hits) do for j,b in ipairs(d.hits) do
                            if i<j then assert(a.x+a.w<=b.x or b.x+b.w<=a.x or a.y+a.h<=b.y or b.y+b.h<=a.y,'overlapping controls') end
                        end end
                        native_context=true; d:draw(); native_context=false
                    end
                end
            end
            ma_lmm118_shutdown()
        ''')

    def test_records_responsive_rows_and_delete_confirmation(self):
        l=self.load_recorder()
        l.execute('''
            records=getup(ma_build_log_manager_window,'log_manager_state')
            records.scan_error=''; records.records={}
            for i=1,16 do records.records[i]={name='fixture'..i..'.txt',display_name='2026-09-12 13:43:21 | ZGNN A20N RWY05'} end
            ui.open_log_visualization=function(name) opened=name; return true,'ok' end
            ui.delete_indexed_log=function(name) deleted=name; records.pending_delete=''; return true end
            ma_open_log_manager(); host=ui.native_ui.instance; d=host.dialogs.records
            for _,w in ipairs({520,900,1200}) do
                api.XPLMSetWindowGeometry(d.window,0,1000,w,0); d.scroll=0; d:tick()
                local row,delete
                for _,c in ipairs(d.commands) do
                    if c.id=='lmm_record_1' then row=c end
                    if c.id=='lmm_delete_1' then delete=c end
                    if c.id=='lmm_prev' then assert(c.disabled) end
                end
                assert(row.y==delete.y and row.h==delete.h and row.x+row.w<delete.x)
            end
            d.actions.lmm_record_1=true; d:tick(); assert(opened=='fixture1.txt')
            d.actions.lmm_delete_1=true; d:tick(); assert(records.pending_delete=='fixture1.txt' and not deleted)
            d.actions.lmm_cancel=true; d:tick(); assert(records.pending_delete=='' and not deleted)
            d.actions.lmm_next=true; d:tick(); assert(records.page==2)
            d.actions.lmm_delete_9=true; d:tick(); assert(records.pending_delete=='fixture9.txt' and not deleted)
            d.actions.lmm_confirm=true; d:tick(); assert(deleted=='fixture9.txt')
            ma_lmm118_shutdown()
        ''')

    def test_rgb_slider_track_and_noninteractive_swatch(self):
        l=self.load_recorder()
        l.execute('''
            ma_open_settings_window(); host=ui.native_ui.instance; d=host.dialogs.settings
            d.actions.lmm_tab_colors=true; d:tick(); d:tick()
            local hit
            for _,h in ipairs(d.hits) do
                assert(h.id~='lmm_colour_preview','colour swatch should not be a button')
                if h.id=='lmm_popup_red' then hit=h end
            end
            assert(hit and hit.track_w<hit.w)
            local y=d.top-(hit.y-d.scroll)-44
            d:mouse(d.left+hit.track_x+hit.track_w/2,y,1)
            d:mouse(d.left+hit.track_x+hit.track_w/2,y,3); d:tick()
            assert(math.abs(ui.popup_style.colors[ui.popup_style.edit_status][1]-0.5)<0.001)
            d:mouse(d.left+hit.track_x+hit.track_w,y,1)
            d:mouse(d.left+hit.track_x+hit.track_w+50,y,2)
            d:mouse(d.left+hit.track_x+hit.track_w+50,y,3); d:tick()
            assert(ui.popup_style.colors[ui.popup_style.edit_status][1]==1)
            ma_lmm118_shutdown()
        ''')

    def test_native_settings_and_records_global_language(self):
        l=self.load_recorder()
        l.execute('''
            ma_open_settings_window()
            host=ui.native_ui.instance
            assert(host.ready,ui.native_ui.error)
            assert(host.dialogs.settings,ui.native_ui.dialog_error)
            d=host.dialogs.settings
            assert(d.max_scroll>0)
            local found=false
            for _,c in ipairs(d.commands) do if c.text=='全局语言' then found=true end end
            assert(found)
            d.actions.lmm_tab_fonts=true; host:update_dialogs()
            d.actions.lmm_font_px=1; host:update_dialogs(); assert(ui.popup_style.font_px==32)
            d.actions.lmm_weight_bold=true; host:update_dialogs(); assert(ui.popup_style.font_weight=='bold')
            d.actions.lmm_tab_position=true; host:update_dialogs()
            d.actions.lmm_offset_up=true; host:update_dialogs(); assert(state.popup_offset_y==5)
            d.actions.lmm_tab_general=true; host:update_dialogs()
            d.actions.lmm_language_en=true; host:update_dialogs()
            assert(state.document_language=='en' and ui.popup_language()=='en')
            host:update_dialogs()
            texts={}
            for _,page in ipairs({'general','position','colors','fonts','tools'}) do
                d.actions['lmm_tab_'..page]=true; host:update_dialogs(); host:update_dialogs()
                for _,c in ipairs(d.commands) do if c.text~='中文' then texts[#texts+1]=c.text end end
            end
            ma_open_log_manager(); assert(host.dialogs.records,ui.native_ui.dialog_error)
            for _,c in ipairs(host.dialogs.records.commands) do texts[#texts+1]=c.text end
            english_ui=table.concat(texts,'\\n')
            ui.set_global_language('zh'); host:update_dialogs()
            assert(calls.window_states[window_index(d.window)].title:find('设置',1,true))
            local cache=host.dialogs.records.commands
            assert(cache[1].text=='落地记录')
            paint()
            assert(not host.dialogs.records.failed,host.dialogs.records.failed)
            ma_lmm118_shutdown()
            assert(calls.destroyed_windows==3 and calls.destroyed_fonts==3)
        ''')
        self.assertIsNone(re.search(r'[\u4e00-\u9fff]',l.eval('english_ui')),l.eval('english_ui'))

    def test_dialog_mouse_slider_scroll_and_resize(self):
        l=self.load_recorder()
        l.execute('''
            ma_open_settings_window(); host=ui.native_ui.instance; d=host.dialogs.settings
            local hit
            for _,h in ipairs(d.hits) do if h.id=='lmm_language_en' then hit=h end end
            assert(hit)
            d:mouse(d.left+hit.x+5,d.top-(hit.y-d.scroll)-5,1)
            host:update_dialogs(); assert(state.document_language=='en')
            d.actions.lmm_tab_fonts=true; host:update_dialogs()
            local slider
            for _,c in ipairs(d.commands) do if c.kind=='slider' and c.text=='Native popup font size' then slider=c end end
            assert(slider)
            d.scroll=math.min(d.max_scroll,math.max(0,slider.y-30)); host:update_dialogs()
            hit=nil
            for _,h in ipairs(d.hits) do if h.id=='lmm_font_px' then hit=h end end
            assert(hit,'font slider must be visible for drag regression')
                d:mouse(d.left+hit.x+hit.w,d.top-(hit.y-d.scroll)-5,1)
                d:mouse(d.left+hit.x,d.top-(hit.y-d.scroll)-5,2)
                d:mouse(d.left+hit.x,d.top-(hit.y-d.scroll)-5,3)
                host:update_dialogs(); assert(ui.popup_style.font_px==10)
            api.XPLMSetWindowGeometry(d.window,-1900,1000,-1400,550)
            host:update_dialogs(); assert(d.width==500 and d.height==450)
            for _,c in ipairs(d.commands) do assert(c.x+c.w<=d.width-20) end
            assert(d.max_scroll>0)
            d.scroll=math.min(80,d.max_scroll); d:tick()
            local before=d.scroll
            local track=d.height-20
            local thumb=math.max(25,track*d.height/(d.max_scroll+d.height))
            local grab=10+(track-thumb)*before/d.max_scroll+thumb/2
            d:mouse(d.left+d.width-14,d.top-grab,1)
            assert(math.abs(d.scroll-before)<0.001,'scrollbar jumps on grab')
            d:mouse(d.left+d.width-14,d.top-grab,3)
            api.XPLMSetWindowIsVisible(d.window,0); host:update_dialogs()
            assert(not host.dialogs.settings)
            ma_lmm118_shutdown()
        ''')

    def test_global_report_output_and_legacy_settings_precedence(self):
        l=self.load_recorder(cfg='document_language=en\ninterface_language=zh\nrunway_detection_enabled=false\n')
        self.assertEqual(l.eval('state.document_language'),'en')
        l.execute('ok,report=ui.build_landing_log_payload(); assert(ok,report)')
        report=l.eval('report.content')
        leftovers=[line for line in report.splitlines() if re.search(r'[\u4e00-\u9fff]',line)]
        self.assertFalse(leftovers,'\n'.join(leftovers))
        self.assertIn('_EN.txt',l.eval('report.path'))
        l.execute("ui.set_global_language('zh'); ok,report=ui.build_landing_log_payload(); assert(ok,report)")
        self.assertIn('核心落地结果',l.eval('report.content'))
        self.assertIn('_CN.txt',l.eval('report.path'))

    def test_report_literal_translation_audit(self):
        l=self.load_recorder()
        source=(ROOT/'StarLux_LMM_v1.1.8.lua').read_text(encoding='utf-8-sig')
        body=source.split('function log_tools.build_landing_log_payload()',1)[1].split('function log_tools.finish_landing_log_write',1)[0]
        leaks=[]
        for match in re.finditer(r'"(?:[^"\\]|\\.)*"',body):
            quoted=match.group(0)
            if not re.search(r'[\u4e00-\u9fff]',quoted): continue
            # The Chinese branch of an explicit bilingual call is not sent to
            # the English writer; it is checked by the global-language tests.
            if re.search(r'log_tools\.ui_text\(\s*$',body[:match.start()]): continue
            value=l.execute('return '+quoted)
            translated=l.globals().ui.english_report_text(value)
            if re.search(r'[\u4e00-\u9fff]',translated): leaks.append(translated)
        self.assertFalse(leaks,'\n'.join(leaks))

    def load_recorder(self, setup='', cfg='popup_font_size=large\ndocument_language=zh\nrunway_detection_enabled=false\n', source=None):
        l=runtime()
        l.globals().MAIN_SOURCE=source or (ROOT/'StarLux_LMM_v1.1.8.lua').read_text(encoding='utf-8-sig')
        l.globals().CONFIG=cfg
        l.execute(r'''
            SCRIPT_DIRECTORY=ROOT; SYSTEM_DIRECTORY='sim/'; SYSTEM='IBM'
            SCREEN_WIDTH=1920; SCREEN_HIGHT=1080; SUPPORTS_FLOATING_WINDOWS=false
            logs={}; exit_code=''; settings_writes={}
            function logMsg(s) logs[#logs+1]=s end
            function XPLMFindDataRef(s) return s end
            function XPLMGetDataf(s) return s=='sim/time/total_running_time_sec' and 1 or 0 end
            function XPLMGetDatad() return 0 end
            function XPLMGetDatai() return 0 end
            function XPLMGetDatavf() return {} end
            function XPLMGetDatavi() return {} end
            function XPLMGetDatab() return '' end
            macros={}; commands={}
            function add_macro(name,code) macros[#macros+1]={name=name,code=code} end
            function create_command(name,...) commands[name]=true end
            function do_every_frame() end
            function do_every_draw() end
            function do_on_exit(s) exit_code=exit_code..s..'\n' end
            function XPLMSetGraphicsState() end
            function glColor4f() end
            function glRectf() calls.legacy=(calls.legacy or 0)+1 end
            function draw_string() end
            draw_string_Helvetica_10=draw_string; draw_string_Helvetica_18=draw_string
            function measure_string(s) return #s*7 end
            os.execute=function() return 0 end
            io.popen=function() return nil end
            io.open=function(path,mode)
                if path:find('LMM_Settings.cfg',1,true) then
                    if mode=='r' then
                        return {lines=function() return CONFIG:gmatch('[^\n]+') end, close=function() end}
                    end
                    return {write=function(self,s) settings_writes[#settings_writes+1]=s end, close=function() end}
                end
                return nil
            end
            function getup(fn,name,value,set)
                for i=1,200 do
                    local n,v=debug.getupvalue(fn,i)
                    if not n then break end
                    if n==name then
                        if set then debug.setupvalue(fn,i,value) end
                        return v
                    end
                end
                error('Missing upvalue '..name)
            end
        ''')
        l.execute(setup)
        l.execute('''
            assert(loadstring(MAIN_SOURCE))()
            ui=getup(ma_landing_meter_draw,'log_tools')
            state=getup(ma_landing_meter_draw,'runtime_state')
            refresh=getup(ui.native_initialize,'refresh_popup_cache')
        ''')
        return l

    def test_explicit_legacy_variant_and_language_defaults(self):
        base=(ROOT/'StarLux_LMM_v1.1.8.lua').read_text(encoding='utf-8-sig')
        for legacy in (False, True):
            for language in ('zh','en'):
                source=base.replace('force_compatibility = false', 'force_compatibility = '+str(legacy).lower())
                source=source.replace('    document_language = "zh",', '    document_language = "'+language+'",')
                l=self.load_recorder(cfg='runway_detection_enabled=false\n', source=source)
                self.assertEqual(l.eval('state.document_language'),language)
                l.execute('ui.native_initialize()')
                self.assertEqual(bool(l.eval('ui.native_ui.force_compatibility')),legacy)
                if legacy:
                    self.assertEqual(l.eval('calls.fonts'),0)
                    self.assertEqual(l.eval('ui.settings_text("中文","English")'),'English')
                    self.assertEqual(l.eval('ui.popup_language()'),language)
                    self.assertIsNone(l.eval('ui.native_ui.instance'))
                else:
                    self.assertTrue(l.eval('ui.native_ui.instance.ready'))
                # Existing settings always win over either package default.
                opposite='en' if language=='zh' else 'zh'
                configured=self.load_recorder(cfg='document_language='+opposite+'\nrunway_detection_enabled=false\n',source=source)
                self.assertEqual(configured.eval('state.document_language'),opposite)

    def test_main_migration_language_preview_and_cleanup(self):
        l=self.load_recorder()
        l.execute('''
            assert(ui.popup_style.font_px==18)
            assert(table.concat(settings_writes):find('popup_font_px=18',1,true))
            ma_landing_meter_draw()
            assert(ui.native_ui.instance.ready,ui.native_ui.error)
            assert(ui.popup_language()=='zh')
            getup(ma_landing_meter_draw,'show_until',10,true)
            ma_landing_meter_draw(); paint()
            assert(#calls.drawings>=7 and not calls.legacy)
            local chinese=false
            for _,d in ipairs(calls.drawings) do if d.text:find('迎角',1,true) then chinese=true end end
            assert(chinese)
            state.document_language='en'; refresh(); ma_landing_meter_draw()
            calls.drawings={}; paint()
            for _,d in ipairs(calls.drawings) do assert(not d.text:find('迎角',1,true)) end
            state.replay_active=true; ma_landing_meter_draw(); assert(calls.visible==0)
            assert(loadstring(exit_code))()
            assert(calls.destroyed_windows==1 and calls.destroyed_fonts==3)
        ''')

    def test_main_missing_ffi_cleanup_or_sdk_falls_back(self):
        for setup in (
            'api.XPLMFontDrawString=nil',
            'do_on_exit=nil',
            "local original=require; require=function(n) if n=='ffi' then error('FFI unavailable') end return original(n) end",
        ):
            with self.subTest(setup=setup):
                l=self.load_recorder(setup)
                l.execute('''
                    getup(ma_landing_meter_draw,'show_until',10,true)
                    ma_landing_meter_draw()
                    assert(ui.native_ui.error~='')
                    assert(ui.popup_language()=='zh' and ui.legacy_font_size()=='normal')
                    assert(calls.legacy>0 and calls.windows==0)
                ''')

    def test_main_saved_size_bounds_and_compatibility(self):
        for value, expected in [('10',10),('32',32),('999',18),('nan',18),('-1',18)]:
            with self.subTest(value=value):
                l=self.load_recorder(cfg='popup_font_size=large\npopup_font_px='+value+'\npopup_renderer=legacy\nrunway_detection_enabled=false\n')
                l.execute('ma_landing_meter_draw(); assert(calls.visible~=1)')
                self.assertEqual(l.eval('ui.popup_style.font_px'),expected)

    def test_compile_top_level_and_algorithm_unchanged(self):
        l=runtime()
        for path in ('StarLux_LMM_v1.1.7.lua','StarLux_LMM_v1.1.8.lua',
                     'LMM_UI_118/native_popup.lua','LMM_UI_118/layout.lua'):
            l.globals().path = str(ROOT/path).replace('\\','/')
            l.execute('assert(loadfile(path))')
        old=(ROOT/'StarLux_LMM_v1.1.7.lua').read_text(encoding='utf-8-sig')
        new=(ROOT/'StarLux_LMM_v1.1.8.lua').read_text(encoding='utf-8-sig')
        self.assertEqual(len(re.findall(r'^local ',old,re.M)),len(re.findall(r'^local ',new,re.M)))
        # Exact function-body comparison for every existing function except UI,
        # persistence of new UI preferences, and report version stamps.
        def functions(source):
            source=re.sub(r'log_tools\.report_translations = \{.*?\n\}', '', source, flags=re.S)
            matches=list(re.finditer(r'^(?:local )?function ([\w.:]+)\(',source,re.M))
            result={}
            for i,m in enumerate(matches):
                end=matches[i+1].start() if i+1<len(matches) else len(source)
                block=source[m.start():end]
                last=block.rfind('\nend')
                result[m.group(1)]=block[:last+4]
            return result
        before,after=functions(old),functions(new)
        changed={k for k,v in before.items() if after.get(k)!=v}
        allowed={'log_tools.popup_language','log_tools.settings_text','save_settings','load_settings',
                 'ma_landing_meter_draw','ma_build_settings_window','ma_build_log_manager_window',
                 'ma_open_settings_window','ma_open_log_manager','position_label',
                 'log_tools.popup_font_metrics','log_tools.popup_measure_text','log_tools.draw_popup_glyphs',
                 'log_tools.write_viewer_html'}
        # Report writer & dictionary version changes are normalized, not excused
        # as arbitrary recorder changes.
        after_norm=functions(new.replace('1.1.8','1.1.7'))
        changed={k for k in changed if after_norm.get(k)!=before[k]}
        self.assertFalse(changed-allowed, f'Unexpected algorithm change: {changed-allowed}')


if __name__=='__main__':
    unittest.main(verbosity=2)

"""Legacy FWL callback/config regressions; does not replace an in-sim flight test."""
import unittest
import test_legacy_compat_119 as legacy
import test_ui_119 as baseline


class RC5CompatibilityUI(unittest.TestCase):
    def load(self, cfg=''):
        return legacy.LegacyCompatibilityTests().load_package(cfg='runway_detection_enabled=false\n'+cfg)

    def test_english_ui_and_chinese_report_are_independent(self):
        l=self.load('document_language=zh\n')
        l.execute(r'''
            local labels={}
            for _,key in ipairs({'TextUnformatted','Button','RadioButton','Checkbox','SliderInt','SliderFloat','BeginCombo'}) do
                local original=imgui[key]
                imgui[key]=function(label,...)
                    assert(not label:find('[\128-\255]'),'non-ASCII compatibility label: '..label)
                    labels[label]=true;return original(label,...)
                end
            end
            ma_open_settings_window();ma_open_log_manager();draw_legacy_windows()
            assert(labels['Report output language'] and labels['Chinese##lmm_language_zh'])
            assert(not labels['Global language'])
            assert(state.document_language=='zh' and ui.ui_text('中文报告','English report')=='中文报告')
            assert(ui.settings_text('中文','English')=='English' and ui.popup_language()=='en')
            local select=true
            local radio=imgui.RadioButton
            imgui.RadioButton=function(label,value)
                radio(label,value)
                if select and label=='English##lmm_language_en' then select=false;return true end
                return false
            end
            ma_build_settings_window(nil,0,0,imgui)
            assert(state.document_language=='en')
            ui.set_global_language('zh');draw_legacy_windows()
            assert(state.document_language=='zh' and ui.popup_language()=='en')
            -- Even a future ImGui binding with tabs must never show a CJK radio.
            imgui.Tabs=function() return 'general' end
            ma_build_settings_window(nil,0,0,imgui)
        ''')

    def test_square_geometry_colors_hover_click_drag_and_hide(self):
        l=self.load()
        l.execute(r'''
            local m=ui.dev;assert(m.compatibility)
            m:present(nil,false,true)
            local w=m.legacy.settings;local c=m.legacy_state.settings
            assert(windows[w].w==24 and windows[w].h==24 and windows[w].imgui==false)
            local rects,colors,texts={},{},{}
            glRectf=function(...) rects[#rects+1]={...} end
            glColor4f=function(...) colors[#colors+1]={...} end
            draw_string_Helvetica_10=function(...) texts[#texts+1]={...} end
            MOUSE_X=-100;MOUSE_Y=-100
            _G[windows[w].draw](w,c.x,c.y)
            assert(#rects==5 and rects[1][3]-rects[1][1]==24)
            assert(math.abs(colors[1][4]-.18*.42)<.001)
            assert(math.abs(colors[2][4]-.18)<.001 and texts[1][3]=='S')
            MOUSE_X=c.x+12;MOUSE_Y=c.y+12
            colors={};texts={};_G[windows[w].draw](w,c.x,c.y)
            assert(colors[2][4]==.8 and texts[2][3]=='Settings')
            local click=_G[windows[w].click]
            click(w,12,12,1);click(w,12,12,3);assert(m.pending=='settings');m.pending=nil
            local start=c.y
            click(w,12,12,1);click(w,12,92,2)
            m:present(nil,false,true)
            assert(math.abs(c.y-start-80)<=1)
            click(w,12,92+start-c.y,3)
            assert(m.pending=='save' and not c.drag)
            m.config.compat_edge_size=48;m.config.edge_right=true;m:present(nil,false,true)
            assert(windows[w].w==48 and windows[w].h==48)
            assert(c.x==(SCREEN_WIDTH or 1920)-48)
            m.config.edge=false;m:present(nil,false,true)
            assert(not m.legacy.settings and not m.legacy.records and windows[w].destroyed)
            ma_open_settings_window() -- recovery entry remains available
            m.config.edge=true;m:present(nil,false,true)
            assert(m.legacy.settings and m.legacy.settings~=w)
        ''')

    def test_config_persistence_bounds_and_standard_edition(self):
        l=self.load('live_compat_edge_size=36\nlive_compat_edge_alpha=35\nlive_compat_edge_lightness=62\nlive_edge=false\n')
        l.execute(r'''
            local m=ui.dev
            assert(m.config.compat_edge_size==36 and m.config.compat_edge_alpha==35 and m.config.compat_edge_lightness==62)
            assert(not m.config.edge)
            local output={};m:write_settings({write=function(_,s)output[#output+1]=s end})
            saved=table.concat(output)
            assert(saved:find('live_compat_edge_size=36',1,true) and saved:find('live_edge=false',1,true))
            m:read_setting('live_compat_edge_size','1');assert(m.config.compat_edge_size==20)
            m:read_setting('live_compat_edge_size','999');assert(m.config.compat_edge_size==48)
            m:read_setting('live_compat_edge_alpha','0');assert(m.config.compat_edge_alpha==5)
            m:read_setting('live_compat_edge_lightness','999');assert(m.config.compat_edge_lightness==100)
        ''')
        loaded=self.load(l.eval('saved'))
        self.assertEqual(loaded.eval('ui.dev.config.compat_edge_size'),36)
        self.assertFalse(loaded.eval('ui.dev.config.edge'))
        old=self.load('live_edge_alpha=24\nlive_edge_settings_y=.8\n')
        self.assertEqual(old.eval('ui.dev.config.compat_edge_alpha'),18)
        self.assertEqual(old.eval('ui.dev.config.edge_settings_y'),.8)
        standard=baseline.RecorderTests().load_recorder(cfg='document_language=zh\nrunway_detection_enabled=false\n')
        standard.execute(r'''
            assert(not ui.dev.compatibility and ui.dev.config.edge_alpha==24)
            assert(ui.settings_text('中文','English')=='中文' and ui.popup_language()=='zh')
            local labels={}
            ui.dev:shortcut_settings({TextUnformatted=function()end,Separator=function()end, Checkbox=function(_,v)return false,v end,
                RadioButton=function()return false end,SliderInt=function(label,v)labels[label]=true;return false,v end,
                SliderFloat=function(_,v)return false,v end,Button=function()return false end},function(zh,en)return en end,function()end)
            assert(labels['Shortcut opacity##live_edge_alpha'])
            assert(not labels['Shortcut size (px)##live_compat_edge_size'])
        ''')


if __name__=='__main__':unittest.main(verbosity=2)

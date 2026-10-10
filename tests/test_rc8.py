"""RC8: early touchdown display, bounded capture, rollout independence and layout."""
import unittest
import test_ui_119 as base
import test_legacy_compat_119 as legacy

FRAME = '''
    local original_open=io.open
    io.open=function(path,mode)
        if mode=='wb' and path:find('.part',1,true) then
            return {write=function(self,...) return self end,flush=function()return true end,close=function()return true end}
        end
        return original_open(path,mode)
    end
    refs={}
    local function read(p)return refs[p] or 0 end
    XPLMGetDataf=read;XPLMGetDatad=read;XPLMGetDatai=read
    function frame(t,ground,agl,vy,g,gs)
        refs['sim/time/total_running_time_sec']=t
        refs['sim/flightmodel/failures/onground_any']=ground
        refs['sim/flightmodel/position/y_agl']=agl/3.28084
        refs['sim/flightmodel/position/elevation']=agl/3.28084
        refs['sim/flightmodel/position/local_vy']=vy
        refs['sim/flightmodel/position/vh_ind_fpm']=vy*196.850394
        refs['sim/flightmodel/position/groundspeed']=(gs or 140)/1.943844
        refs['sim/flightmodel/forces/g_nrml']=g
        refs['sim/operation/misc/frame_rate_period']=1/120
        ma_landing_meter_update();ma_landing_meter_draw()
    end
    function visible()
        if ui.native_ui.instance then return ui.native_ui.instance.visible end
        return ui.legacy_popup_bounds~=nil
    end
    function approach()
        for i=0,119 do frame(10+i/120,0,40-i*.3,-1,1)end
    end
'''

class RC8Tests(unittest.TestCase):
    def model(self,compat=False):
        l=legacy.LegacyCompatibilityTests().load_package() if compat else base.RecorderTests().load_recorder()
        l.execute(FRAME)
        return l

    def test_high_speed_popup_short_and_delayed_compression_both_renderers(self):
        for compat in [False,True]:
            for stop,peak in [(.4,.07),(2.8,2.4)]:
                for mode in ['touchdown','live']:
                    with self.subTest(compat=compat,stop=stop,mode=mode):
                        l=self.model(compat);l.globals().mode=mode;l.globals().stop=stop;l.globals().peak=peak
                        l.execute('''
                            getup(ma_landing_meter_draw,'POPUP_MODE',mode,true)
                            approach();assert(visible()==(mode=='live'))
                            frame(11,1,1,-1,1)
                            assert(visible() and ui.pending_touch_popup() and not ui.compact_live(11))
                            assert(#ui.popup_display()>3,'touchdown must expand the panel')
                            for i=1,720 do
                                local dt=i/120
                                frame(11+dt,1,1,dt<stop and -1+dt/stop or 0,1+.6*math.exp(-((dt-peak)/.18)^2))
                                if dt<stop-.15 then assert(ui.pending_touch_popup(),'capture ended prematurely')end
                            end
                            assert(ui.live.state=='complete',ui.live.state)
                            assert(ui.touchdown.active and not ui.touchdown.finalized,'must still monitor rollout')
                            assert(ui.recording.file,'early popup ended disk recording')
                            local result=ui.popup_display()[2]
                            local until1=getup(ma_landing_meter_draw,'show_until')
                            for i=1,120 do frame(17+i/120,1,1,3,2.7)end
                            assert(ui.popup_display()[2]==result,'rollout live loads leaked into landing result')
                            assert(getup(ma_landing_meter_draw,'show_until')==until1,'countdown reset during rollout')
                            ui.dismiss_popup();frame(18.1,1,1,0,1)
                            assert(not visible() and ui.recording.file,'close must hide only')
                        ''')

    def test_deferred_modes_still_wait_and_final_capture_does_not_reopen(self):
        for mode in ['taxi','stopped','off','clean','touchdown']:
            l=self.model();l.globals().mode=mode
            l.execute('''
                getup(ma_landing_meter_draw,'POPUP_MODE',mode,true);approach()
                for i=0,600 do frame(11+i/120,1,1,i<50 and -1 or 0,1.1)end
                assert(visible()==(mode=='touchdown'))
                local until1=getup(ma_landing_meter_draw,'show_until')
                if mode=='touchdown' then ui.dismiss_popup()end
                for i=1,420 do frame(16+i/120,1,1,0,1,20)end
                if mode=='taxi' then assert(visible())else assert(not visible())end
                if mode=='touchdown' then assert(getup(ma_landing_meter_draw,'show_until')==0)end
            ''')

    def test_next_bounce_reenters_capture_without_waiting_for_rollout(self):
        l=base.runtime();l.execute('''
            local m=dofile(ROOT..'LMM_UI_119/core_live.lua').new()
            local td={active=true,start_time=10,current={index=1}}
            local rec={id='a',file={}}
            m:sync(rec,td,false,10,false)
            assert(m:sync(rec,td,false,10,false)=='touchdown')
            td.current.done=true
            assert(m:sync(rec,td,true,11,false)=='complete')
            local at=m.result_at
            assert(not m:sync(rec,td,true,12,false) and m.result_at==at)
            td.current={index=2}
            assert(m:sync(rec,td,true,20,false)=='touchdown' and m:pending())
            m.dismissed=true;td.current.done=true
            assert(m:sync(rec,td,true,21,false)=='complete' and m.dismissed)
            td.active=false;td.finalized=true;td.status='complete'
            assert(not m:sync(rec,td,true,100,false) and m.result_at==21)
        ''')

    def test_settings_defaults_general_order_grid_and_component_switches(self):
        l=base.RecorderTests().load_recorder();l.execute('''
            assert(ui.dev.config.edit and ui.dev.config.fpm_vvi and ui.dev.config.fpm_physical and ui.dev.config.fpm_agl)
            assert(getup(ma_landing_meter_draw,'POPUP_MODE')=='touchdown')
            ma_open_settings_window();local d=ui.native_ui.instance.dialogs.settings
            ui.settings_ui_tab='general';d:tick()
            local ids={};for i,c in ipairs(d.commands)do if c.id then ids[c.id]=i end end
            assert(ids.lmm_language_en<ids.live_edge and ids.live_edge<ids.lmm_live and ids.lmm_live<ids.lmm_immediate)
            assert(not ids.live_edge_right)
            ui.settings_ui_tab='live';d:tick()
            ids={};for i,c in ipairs(d.commands)do if c.id then ids[c.id]=c end end
            assert(not ids.live_edge and not ids.live_edge_right)
            assert(ids.live_fpm_meter.y==ids.live_g_meter.y and ids.live_g_meter.x>ids.live_fpm_meter.x)
            assert(ids.live_engine_combined.y>ids.live_live_combined.y)
            d.actions.live_live_combined=true;d:tick()
            assert(ui.dev.config.live_combined and ui.dev:visible('g_meter') and not ui.dev:visible('fpm_meter'))
            d.actions.live_fpm_meter=true;d:tick()
            assert(not ui.dev.config.live_combined and ui.dev:visible('fpm_meter'))
            d.actions.live_engine_combined=true;d:tick()
            assert(ui.dev:visible('throttle') and not ui.dev:visible('n1'))
            d.actions.live_n1=true;d:tick()
            assert(not ui.dev.config.engine_combined and ui.dev:visible('n1'))
        ''')

if __name__=='__main__':unittest.main(verbosity=2)

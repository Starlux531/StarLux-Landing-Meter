"""RC6 event, rendering and regression tests; no simulator or network access."""
import json
import unittest
import test_ui_119 as baseline
import test_bounce_119 as bounce_tests
import test_legacy_compat_119 as legacy


class TouchdownTests(unittest.TestCase):
    def model(self):
        l=baseline.runtime()
        l.execute('''
            module=dofile(ROOT..'LMM_UI_119/core_touchdown.lua');m=module.new()
            function run(peak,width,fps,stop,spike)
                m:start(0)
                for i=0,math.ceil(4*fps) do
                    local t=i/fps
                    local g=1+.6*math.exp(-((t-peak)/width)^2)
                    if spike and i==math.floor(.4*fps) then g=4.8 end
                    m:update(t,g,t<stop and -1+t/stop or 0,0,0,1,0,false)
                end
                return m.events[1]
            end
        ''')
        return l

    def test_short_peak_matches_original_fixed_percentile(self):
        l=self.model()
        for fps in [30,60,120,240]:
            l.globals().fps=fps
            l.execute('''
                local e=run(.07,.05,fps,.5)
                local a={};for i=0,math.floor(.16*fps)do a[#a+1]=1+.6*math.exp(-((i/fps-.07)/.05)^2)end
                table.sort(a)
                assert(e.mode=='fixed' and math.abs(e.g-a[math.ceil(#a*.75)])<1e-9)
            ''')

    def test_delayed_wide_peak_and_no_single_frame_promotion(self):
        l=self.model()
        for fps in [60,120,240]:
            l.globals().fps=fps
            l.execute('''
                local e=run(.55,.18,fps,.95)
                assert(e.mode=='delayed' and e.g>1.5 and e.fixed_g<1.03)
                local e=run(.07,.05,fps,.8,true)
                assert(e.mode=='fixed' and e.g<1.6 and e.peak==4.8)
                for _,peak in ipairs({1.5,2.4}) do
                    local long=run(peak,.25,fps,2.8)
                    assert(long.mode=='delayed' and long.g>1.5 and long.quality=='valid')
                end
            ''')

    def test_timeout_gap_invalid_and_rollout_exclusion(self):
        l=self.model()
        l.execute('''
            local e=run(2.3,.25,120,10)
            assert(e.reason=='limit' and e.quality=='limit' and e.finish<=3.01)
            local e=run(.55,.18,15,.95);assert(e.quality=='sample_gaps' and e.mode~='delayed')
            m:start(0)
            for i=0,120 do m:update(i/120,i==30 and 0/0 or 1.2,-1+i/120,0,0,1,0,false)end
            m:finish(1,'velocity_settled');assert(m.events[1].quality=='invalid_samples')
            local e=run(.07,.05,120,.5);local peak=m.observed_peak
            m:update(4.01,4.9,0,0,0,1,0,false)
            assert(m.observed_peak==peak,'rollout bump must not overwrite touchdown peak')
        ''')

    def test_pause_rewind_new_session_and_capacity(self):
        l=self.model()
        l.execute('''
            m:start(10);m:update(10,1.2,-1,0,0,1,0,false)
            m:update(50,1.3,-1,0,0,1,0,true)
            m:update(50.01,1.3,-1,0,0,1,0,false)
            -- A paused observer must not fabricate samples.
            assert(m.count<=2)
            m:start(100);m:update(100,1,-1,0,0,1,0,false);m:update(99,1,-1,0,0,1,0,false)
            assert(not m.active and m.status=='incomplete')
            m:start(0);for i=0,3000 do m:update(i/1000,1.4,-1,0,0,1,0,false)end
            assert(m.count<=1024 and m.events[1].reason=='limit')
            m:start(0);assert(#m.events==0 and not m.observed_peak and not m.dismissed)
            assert(module.tone(300,true)==nil and module.tone(-301,true))
        ''')

    def test_a321_low_bounce_geometry_disagreement(self):
        fixture=json.loads((baseline.ROOT/'tests/fixtures/rc6-low-bounce.json').read_text())
        l=bounce_tests.BounceTests().model()
        l.execute("getup(refresh,'landing_status','STABLE',true)")
        l.globals().start(0,fixture['touch_agl_estimated'])
        for r in fixture['samples']:
            l.globals().step(r['t'],r['ground'],r['agl'],r['vy'],r['gs'],r['g'])
        l.execute('''
            assert(bounce.detected and bounce.evidence=='geometry_rebound')
            assert(bounce.second_g_ready and bounce.result_status=='ATTENTION')
            assert(bounce.confirmed_count==1 and bounce.score_applied)
        ''')

    def test_multiple_contacts_demote_once_then_allow_red(self):
        l=bounce_tests.BounceTests().model()
        l.execute('''
            start(0,1)
            step(.1,0,2,.3);step(.3,0,2.2,.3);step(.5,1,1,-1)
            step(.9,1,1,0);assert(bounce.result_status=='STABLE')
            step(1,0,2,.3);step(1.3,0,2.2,.3);step(1.5,1,1,-1)
            step(1.9,1,1,0);assert(bounce.confirmed_count==2 and bounce.result_status=='STABLE')
            step(2,0,2,.3);step(2.3,0,2.2,.3);step(2.5,1,1,-1,140,2)
            step(2.9,1,1,0,140,2);assert(bounce.result_status=='UNSTABLE')
        ''')

    def test_live_popup_colors_layout_and_close_do_not_stop_recording(self):
        l=baseline.RecorderTests().load_recorder()
        l.execute('''
            getup(ma_landing_meter_draw,'POPUP_MODE','live',true)
            ui.live.state='recording';ui.live.started_at=1
            ui.live:update(1,-394,-394,100,false,false,'test')
            local td=ui.touchdown;td:start(1);td:update(1,1.7,-2,0,0,1,0,false)
            local lines,colors=ui.popup_display()
            assert(colors[3] and colors[3][1]==1 and colors[2] and colors[2][2]==.78)
            assert(#lines==3 and lines[2]:find('1.70',1,true) and lines[3]:find('VVI',1,true))
            ma_landing_meter_draw();local h=ui.native_ui.instance;local layout=h.layout
            for i=1,50 do
                td:update(1+i*.005,1.7+i*.001,-2+i*.001,0,0,1,0,false)
                ma_landing_meter_draw()
                assert(h.layout==layout,'live digits rebuilt popup layout')
            end
            ui.dismiss_popup();ma_landing_meter_draw()
            assert(td.active and not h.visible and td.dismissed)
            td:close(true);assert(td.finalized and td.status=='complete')
        ''')

    def test_live_widgets_both_renderers_and_saved_configuration(self):
        for compatibility in [False,True]:
            l=legacy.LegacyCompatibilityTests().load_package() if compatibility else baseline.RecorderTests().load_recorder()
            l.execute('''
                ui.dev.config.g_meter=true;ui.dev.config.fpm_meter=true
                ui.touchdown:update(1,1.9,-2,0,0,0,100,false)
                ma_landing_meter_draw()
                if ui.dev.compatibility then draw_legacy_windows()
                else
                    local r=ui.dev.renderer
                    native_context=true;r:draw(r.windows.g_meter);r:draw(r.windows.fpm_meter);native_context=false
                end
                ui.dev.config.live_combined=true;ma_landing_meter_draw()
                assert(ui.dev:visible('g_meter',false) and not ui.dev:visible('fpm_meter',false))
                local out={};ui.dev:write_settings({write=function(_,s)out[#out+1]=s end})
                assert(table.concat(out):find('live_g_meter=true',1,true))
            ''')

    def test_complete_frame_pipeline_delayed_event_and_final_report(self):
        l=baseline.RecorderTests().load_recorder()
        l.execute('''
            local refs={}; local t=10
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
                ma_landing_meter_update()
            end
            for i=0,119 do frame(10+i/120,0,40-i*.3,-1,1) end
            for i=0,480 do
                local dt=i/120
                frame(11+dt,1,1,dt<.95 and -1+dt/.95 or 0,1+.6*math.exp(-((dt-.55)/.18)^2),dt>1.2 and 20 or 140)
                ma_landing_meter_draw()
            end
            local td=ui.touchdown
            assert(td.finalized and td.status=='complete',td.status)
            assert(#td.events==1 and td.events[1].mode=='delayed')
            assert(td.events[1].fpm~=nil)
            assert(getup(ma_landing_meter_update,'landing_complete'))
            assert(getup(ma_landing_meter_update,'landing_g')>1.5)
            local ok,report=ui.build_landing_log_payload('test.txt');assert(ok)
            assert(report.content:find('LMM_TOUCH_EVENT\\t1\\t1\\t',1,true))
            assert(report.content:find('touchdown-rc6-1',1,true))
        ''')

    def test_rapid_successive_contacts_during_capture(self):
        l=bounce_tests.BounceTests().model()
        l.execute('''
            start(0,1)
            step(.1,0,2,.3);step(.3,0,2.2,.3);step(.5,1,1,-1)
            assert(bounce.phase=='second_capture')
            step(.55,0,1.1,.3);step(.75,0,2,.3);step(.95,1,1,-1)
            step(1.4,1,1,0)
            assert(bounce.confirmed_count==2 and bounce.second_g_ready)
            assert(bounce.result_status=='STABLE')
        ''')


if __name__=='__main__':unittest.main(verbosity=2)

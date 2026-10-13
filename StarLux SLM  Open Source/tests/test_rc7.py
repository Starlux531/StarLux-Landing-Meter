"""RC7 display lifecycle/source selection. Grading remains under RC6 regressions."""
import unittest
import test_ui_119 as base
import test_legacy_compat_119 as legacy
import test_recording_119 as recording

class RC7Tests(unittest.TestCase):
    def test_actual_recorder_threshold_partial_start_and_no_extra_disk_sampling(self):
        fixture=recording.RecordingTests();fixture.setUp();self.addCleanup(fixture.doCleanups)
        l=fixture.lua;l.execute('''
            live=dofile(ROOT..'LMM_UI_119/core_live.lua').new();td={}
            rec:tick(sample(1,2501),1);assert(not live:sync(rec,td,false,1,false))
            rec:tick(sample(1.1,2500),1);assert(live:sync(rec,td,false,1.1,false)=='started')
            local n=rec.samples
            for i=1,1000 do live:update(1.1+i/240,-600,-620,2500-i/240*10,false,false,'plane')end
            assert(rec.samples==n,'display updates wrote recorder samples')
            rec:stop('manual_end',false);assert(live:sync(rec,td,false,6,false)=='interrupted')
            rec.manual_hold=false;rec.closed=false;rec.done=false;rec.retry_after=0
            rec.previous=nil
            rec:tick(sample(10,700),1);rec:tick(sample(10.1,699),1)
            assert(rec.file and rec.missing and live:sync(rec,td,false,10.1,false)=='started')
            rec:shutdown()
        ''')

    def test_sources_zero_missing_independent_and_bounded_estimate(self):
        l=base.runtime();l.execute('''
            local m=dofile(ROOT..'LMM_UI_119/core_live.lua').new()
            m:update(0,0,-640,100,false,false,'a')
            assert(m.values[1]==0 and m.values[2]==-640 and m.values[3]==nil)
            assert(m:line(1,true)=='VVI +0 fpm')
            m:update(.1,-650,-640,99,false,false,'a');assert(math.abs(m.values[3]+600)<.01)
            m:update(.2,nil,0,98,false,false,'a');assert(m:line(1,true):find('unavailable') and m.values[2]==0)
            m:update(.3,-10,-20,97,true,false,'a');assert(not m.values[3])
            m:update(10,-10,-20,97,false,false,'a');assert(not m.values[3])
            m:update(10.1,-10,-20,97,false,true,'a');assert(not m.values[1] and not m.values[2])
            local cfg={fpm_vvi=true,fpm_physical=true,fpm_agl=true,popup_fpm_source=1}
            local a=m:selected(cfg);assert(#a==3 and a==m:selected(cfg))
            cfg.popup_fpm_source=2;assert(a==m:selected(cfg))
        ''')

    def test_session_actual_start_completion_dismiss_pause_and_next_flight(self):
        l=base.runtime();l.execute('''
            local m=dofile(ROOT..'LMM_UI_119/core_live.lua').new()
            local td={};local rec={}
            assert(not m:sync(rec,td,false,0,false) and not m:compact(0))
            rec={file={},id='first'}
            assert(m:sync(rec,td,false,1,false)=='started' and m:compact(1))
            m.dismissed=true;assert(not m:compact(2))
            td.active=true;td.start_time=10;td.finalized=false
            assert(not m:sync(rec,td,true,11,false))
            rec.file=nil;rec.done=true
            assert(not m:sync(rec,td,true,12,false))
            td.active=false;td.finalized=true;td.status='complete'
            assert(m:sync(rec,td,true,13,false)=='complete' and m.dismissed)
            assert(not m:sync(rec,td,true,14,false))
            assert(not m:result_lit(13.1) and m:result_lit(13.6) and not m:result_lit(14.1) and m:result_lit(14.6) and m:result_lit(15))
            rec={file={},id='second'}
            assert(m:sync(rec,td,true,20,false)=='started' and not m.dismissed)
            assert(not m:sync(rec,td,false,21,false) and m:compact(21),'old completed touchdown leaked')
            rec.file=nil;rec.done=true;rec.phase='INCOMPLETE'
            assert(m:sync(rec,td,false,22,false)=='interrupted' and m:compact(23) and not m:compact(26))
            m:sync(rec,td,false,27,true);assert(m.state=='idle')
        ''')

    def test_mode_migration_and_persistence(self):
        for value,expected in [('immediate','live'),('touchdown','touchdown'),('live','live'),('analyzed','touchdown')]:
            l=base.RecorderTests().load_recorder(cfg=f'popup_mode={value}\nrunway_detection_enabled=false\n')
            self.assertEqual(l.eval("getup(ma_landing_meter_draw,'POPUP_MODE')"),expected)
            l.execute("getup(ma_landing_meter_update,'save_settings')()")
            self.assertIn('popup_mode='+expected,l.eval('table.concat(settings_writes)'))
        l=base.RecorderTests().load_recorder()
        self.assertEqual(l.eval("getup(ma_landing_meter_draw,'POPUP_MODE')"),'touchdown')

    def test_compact_popup_sources_close_resize_and_default_results_mode(self):
        for compat in [False,True]:
            l=legacy.LegacyCompatibilityTests().load_package() if compat else base.RecorderTests().load_recorder()
            l.execute('''
                getup(ma_landing_meter_draw,'POPUP_MODE','live',true)
                ui.recording.id='started';ui.recording.file={}
                ui.sync_live(1,false);ui.live:update(1,-500,-600,100,false,false,'plane')
                ui.touchdown:update(1,1.1,-3,0,0,0,100,false)
                local a=ui.popup_display();assert(#a==3 and a[1]:find('SLM') and a[3]:find('VVI'))
                ui.dev.config.popup_fpm_source=2;a=ui.popup_display()
                assert(a[3]:find('-600') and not a[3]:find('VVI'))
                ma_landing_meter_draw()
                if ui.native_ui.instance then assert(ui.native_ui.instance.visible)
                else assert(ui.legacy_popup_bounds and ui.legacy_popup_bounds.h<170) end
                ui.dismiss_popup();ma_landing_meter_draw();assert(ui.recording.file and ui.live.dismissed)
                ui.live.dismissed=false;ui.touchdown.dismissed=false
                getup(ma_landing_meter_draw,'POPUP_MODE','touchdown',true)
                ma_landing_meter_draw()
                if ui.native_ui.instance then assert(not ui.native_ui.instance.visible) else assert(not ui.legacy_popup_bounds) end
            ''')

    def test_result_countdown_once_and_final_source_independent_of_live(self):
        l=base.RecorderTests().load_recorder();l.execute('''
            getup(ma_landing_meter_draw,'POPUP_MODE','live',true)
            ui.live.state='recording';ui.live.session='a'
            ui.recording.id='a';ui.recording.done=true
            getup(ma_landing_meter_update,'landing_complete',true,true)
            ui.touchdown.active=false;ui.touchdown.finalized=true;ui.touchdown.status='complete';ui.touchdown.start_time=10
            getup(ma_landing_meter_update,'landing_analysis').flare_fpm_source='PHYSICAL'
            ui.dev.config.popup_fpm_source=1
            ui.sync_live(20,false);local until1=getup(ma_landing_meter_draw,'show_until')
            ui.sync_live(21,false);assert(getup(ma_landing_meter_draw,'show_until')==until1)
            local lines=ui.popup_display();assert(lines[2]:find('物理') or lines[2]:find('Physical'))
            assert(not lines[2]:find('VVI'))
        ''')

    def test_multi_source_widgets_fit_without_geometry_changes(self):
        for compat in [False,True]:
            l=legacy.LegacyCompatibilityTests().load_package() if compat else base.RecorderTests().load_recorder()
            l.execute('''
                ui.dev.config.g_meter=true;ui.dev.config.fpm_meter=true;ui.dev.config.live_combined=true
                ui.dev.config.fpm_vvi=true;ui.dev.config.fpm_physical=true;ui.dev.config.fpm_agl=true
                ui.live:update(1,-500,-600,100,false,false,'plane');ui.live:update(1.1,-500,-600,99,false,false,'plane')
                ui.touchdown:update(1.1,1.2,-3,0,0,0,99,false)
                ma_landing_meter_draw()
                if ui.dev.compatibility then draw_legacy_windows() else
                    local r=ui.dev.renderer;local w=r.windows.g_meter
                    local size=ui.dev.config.g_meter_size
                    native_context=true;r:draw(w);native_context=false
                    assert(w.w==size and w.h==size and not w.error)
                end
                local out={};ui.dev:write_settings({write=function(_,s)out[#out+1]=s end})
                assert(table.concat(out):find('live_fpm_physical=true',1,true))
            ''')

if __name__=='__main__':unittest.main(verbosity=2)

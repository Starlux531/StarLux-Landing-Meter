"""Boundary/state-machine tests of production rollout grading and report integration."""
import unittest
import test_ui_119 as baseline
from test_ui_119 import runtime


class RolloutGradingTests(unittest.TestCase):
    def model(self):
        lua=runtime()
        lua.execute('''
            module=assert(loadfile(ROOT..'LMM_UI_119/core_rollout.lua'))()
            runway={lat1=0,lon1=0,lat2=0,lon2=.1,width_m=45,end1='09',end2='27'}
            function fresh() r=module.new(runway,nil,'09','test') end
            function step(t,c,gs,ground)
                return r:update({t=t,lat=c/111195,lon=(1000+t*35)/111195,gs=gs or 100,ground=ground or 1})
            end
            fresh()
        ''')
        return lua

    def test_strict_offsets_and_inclusive_60kt(self):
        self.model().execute('''
            step(0,5,60);assert(r.steps==0)
            step(.1,5.01,60);assert(r:score('NICE')=='STABLE')
            assert(r:score('STABLE',r.steps)=='STABLE','do not repeat')
            step(.2,7);assert(not r.offset_7)
            step(.3,7.01);assert(r:score('NICE')=='ATTENTION')
            assert(r:score('UNSTABLE')=='UNSTABLE')
            fresh();for i=0,100 do step(i*.1,25,59.99) end
            assert(r.samples==0 and r.revision==0)
            fresh();for i=0,100 do step(i*.1,25,100,0) end
            assert(r.revision==0)
        ''')

    def test_swing_requires_both_sides_and_never_accumulates_path_length(self):
        self.model().execute('''
            for i=0,200 do step(i*.1,i%2==0 and 5 or 0) end
            assert(not r.lateral_swing and r.steps==0)
            fresh();step(0,6);step(.1,0);assert(not r.lateral_swing and r.steps==1)
            step(.2,-5);assert(not r.lateral_swing)
            step(.3,-5.1);assert(r.lateral_swing and r.steps==2)
            for i=4,300 do step(i*.1,i%2==0 and 6 or -6) end
            assert(r.steps==2 and r.swings==1 and #r.evidence==2)
            assert(r:score('NICE')=='ATTENTION')
            fresh();step(0,12);step(.1,0);assert(not r.lateral_swing)
        ''')

    def test_red_hysteresis_duration_and_reset(self):
        self.model().execute('''
            for i=0,50 do step(i*.1,9) end;assert(not r.sustained_9)
            fresh();step(0,9.1);for i=1,29 do step(i*.1,8) end
            assert(not r.sustained_9);step(3,8);assert(r.sustained_9)
            assert(r:score('NICE')=='UNSTABLE')
            fresh();step(0,9.1);for i=1,29 do step(i*.1,8) end
            step(3,7);for i=31,70 do step(i*.1,8) end;assert(not r.sustained_9)
        ''')

    def test_outside_three_continuous_not_accumulated(self):
        self.model().execute('''
            for i=0,49 do step(i*.1,3.1) end;assert(not r.outside_3)
            step(5,3.1);assert(r.outside_3 and r.steps==1 and r:score('NICE')=='STABLE')
            fresh();for i=0,200 do step(i*.1,i%40==0 and 3 or 4) end
            assert(not r.outside_3)
        ''')

    def test_interruptions_break_all_continuous_evidence(self):
        for interrupt in ["step(2.5,10,59)","step(2.5,10,100,0)","r:reset_segment()", "step(4,8)"]:
            with self.subTest(interrupt=interrupt):
                self.model().execute('''
                    step(0,9.5);for i=1,24 do step(i*.1,8) end
                '''+interrupt+'''
                    for i=41,55 do step(i*.1,8) end
                    assert(not r.sustained_9 and not r.outside_3)
                ''')
        self.model().execute('''
            step(0,6);step(.1,0,59);step(.2,-6);assert(not r.lateral_swing)
        ''')

    def test_late_geometry_replays_touchdown_and_limits_memory(self):
        self.model().execute('''
            rec=assert(loadfile(ROOT..'LMM_UI_119/core_recording.lua'))().new('')
            rec.id='test';rec.touch_time=0;r.session_id='test'
            for i=0,60 do rec:rollout_sample({t=i*.1,lat=4/111195,lon=(1000+i*3.5)/111195,gs=100,ground=1}) end
            assert(not rec.route);rec:bind_rollout(r)
            assert(r.outside_3 and r.samples==61 and #rec.rollout_pending==0)
            local samples=r.samples;rec:bind_rollout(r);assert(r.samples==samples)
            rec.id='other';rec:bind_rollout(r);assert(r.samples==samples)
            rec.rollout_pending={};for i=1,650 do rec:rollout_sample({t=i,lat=0,lon=0,gs=100,ground=1}) end
            assert(rec.rollout_front_missing and #rec.rollout_pending<=600)
        ''')

    def test_plugin_rating_idempotence_and_bilingual_final_report(self):
        lua=baseline.RecorderTests().load_recorder()
        lua.execute('''
            context=getup(ui.build_landing_log_payload,'landing_context')
            getup(ma_landing_meter_update,'landing_complete',true,true)
            getup(refresh,'landing_status','NICE',true)
            ui.recording.id='flight';ui.recording.touch_time=100;context.recording_id='flight'
            r=ui.rollout_module.new({lat1=0,lon1=0,lat2=0,lon2=.1,width_m=45,end1='09',end2='27'},nil,'09','test')
            r.session_id='flight';ui.dev.route=r
            r:update({t=100,lat=6/111195,lon=.01,gs=100,ground=1})
            ui.apply_rollout_score();assert(getup(refresh,'landing_status')=='STABLE')
            for i=1,100 do ui.apply_rollout_score() end;assert(getup(refresh,'landing_status')=='STABLE')
            r:update({t=100.1,lat=8/111195,lon=.0101,gs=100,ground=1})
            ui.apply_rollout_score();assert(getup(refresh,'landing_status')=='ATTENTION')
            assert(ui.recording.summary_dirty)
            local ok,built=ui.build_landing_log_payload('test.txt');assert(ok)
            assert(built.content:find('滑跑考核状态: IN_PROGRESS',1,true))
            assert(built.content:find('offset_7; T+0.10 s',1,true))
            ui.recording.done=true;ui.recording.phase='COMPLETE';ui.recording.closed=true
            ui.recording.summary='earlier snapshot';ui.recording.report_path='test.txt'
            ui.recording.begin_export=function(self) exported=self.summary end
            ui.recording.tick=function() end
            ui.record_frame({t=110})
            assert(exported:find('滑跑考核状态: COMPLETE',1,true))
            assert(exported:find('滑跑评分等级: ATTENTION',1,true))
            ui.set_global_language('en');local ok,out=ui.build_landing_log_payload('test.txt');assert(ok);english=out.content
        ''')
        import re
        self.assertIsNone(re.search(r'[\u4e00-\u9fff]',lua.eval('english')))

    def test_streamed_recording_preserves_graded_events_and_metadata(self):
        import tempfile
        from pathlib import Path
        with tempfile.TemporaryDirectory(prefix='lmm-rollout-') as folder:
            lua=self.model();lua.globals().OUT=Path(folder).as_posix()+'/'
            lua.execute('''
                rec=assert(loadfile(ROOT..'LMM_UI_119/core_recording.lua'))().new(OUT)
                function s(t,ground,gs)
                    return {t=t,lat=10/111195,lon=(1000+t*35)/111195,ground=ground,gs=gs,agl=ground==1 and 0 or 5,vy=-1,identity='test'}
                end
                rec:tick(s(0,0,100),1);rec:tick(s(.1,0,100),1)
                r.session_id=rec.id
                for i=2,35 do rec:tick(s(i*.1,1,100),1,r) end
                assert(r.sustained_9)
                for i=36,57 do rec:tick(s(i*.1,1,29),1,r) end
                assert(rec.phase=='COMPLETE' and rec.done)
                rec:begin_export();while rec.export do rec:export_step() end
            ''')
            text=Path(lua.eval('rec.saved_path')).read_text(encoding='utf-8')
            self.assertIn('META\trollout_mode\tgraded',text)
            self.assertIn('META\trollout_min_gs_kt\t60',text)
            self.assertIn('\tsustained_9\t',text)
            self.assertIn('\tgraded\t100',text)
            self.assertNotIn('shadow_unvalidated',text)


if __name__=='__main__':unittest.main(verbosity=2)

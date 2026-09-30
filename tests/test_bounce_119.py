"""Exercise the real bounce state machine with recorded and synthetic samples."""
import json
import unittest
import test_ui_119 as baseline


class BounceTests(unittest.TestCase):
    def model(self):
        lua = baseline.RecorderTests().load_recorder()
        lua.execute('''
            monitor=getup(ma_landing_meter_update,'process_bounce_monitor')
            begin=getup(ma_landing_meter_update,'begin_bounce_monitor')
            bounce=getup(monitor,'bounce_state')
            trace_finish=getup(getup(ma_landing_meter_update,'update_flare_trace'),'finish_flare_trace')
            ui.recording.id='flight';ui.recording.done=false
            context=getup(ui.build_landing_log_payload,'landing_context');context.recording_id='flight'
            getup(ma_landing_meter_update,'landing_complete',true,true)
            getup(refresh,'landing_status','NICE',true)
            function start(t,h)
                begin(t,h or 0);getup(monitor,'was_on_ground',1,true)
            end
            function step(t,ground,h,vy,gs,g)
                monitor(t,ground,h or 0,vy or 0,g or 1.15,gs or 140)
                getup(monitor,'was_on_ground',ground,true)
            end
        ''')
        return lua

    def test_real_beta6_long_bounce_detected_and_final_summary_refreshed(self):
        lua = self.model()
        samples = json.loads((baseline.ROOT/'tests/fixtures/bounce-long-beta6.json').read_text())['samples']
        started = False
        for point in samples:
            if not started:
                if point['ground'] != 1:
                    continue
                lua.globals().start(point['t'], point['agl'])
                started = True
            lua.globals().step(point['t'],point['ground'],point['agl'],point['physical_fpm']/196.850394,point['gs'],point['g'])
        lua.execute('''
            assert(bounce.detected and bounce.second_g_ready and bounce.score_applied)
            assert(bounce.second_touch_time-bounce.first_touch_time>6)
            assert(bounce.airborne_duration_seconds>5.5)
            assert(bounce.phase=='confirmed' and bounce.monitoring)
            assert(getup(refresh,'landing_status')=='STABLE')
            assert(ui.recording.summary_dirty)
            local ok,report=ui.build_landing_log_payload('preserved.txt');assert(ok)
            assert(report.content:find('弹跳检测: 发生弹跳',1,true))
            -- The early 8 s report may predate a later bounce. Final export
            -- refreshes the prefix at the original path, without another file.
            ui.recording.closed=true;ui.recording.summary='old no-bounce snapshot'
            ui.recording.report_path='preserved.txt'
            ui.recording.begin_export=function(self)
                exported=self.summary;export_path=self.report_path
            end
            ui.recording.tick=function() end
            ui.record_frame({t=230,lat=0,lon=0,agl=0,ground=1,gs=20})
            assert(exported:find('弹跳检测: 发生弹跳',1,true))
            assert(export_path=='preserved.txt' and not ui.recording.summary_dirty)
        ''')

    def test_late_long_bounce_survives_short_excerpt_and_does_not_rearm(self):
        lua = self.model()
        lua.execute('''
            start(10,0)
            for i=1,600 do step(10+i*.1,1) end
            trace_finish(70,'excerpt complete');assert(bounce.monitoring)
            for i=1,900 do step(70+i*.1,0,3, i<100 and .3 or 0) end
            step(160.1,1,0,-1)
            for i=2,6 do step(160+i*.1,1) end
            assert(bounce.detected and bounce.second_g_ready and bounce.monitoring)
            assert(bounce.second_touch_time-bounce.first_touch_time>150)
            for i=1,100 do step(160.6+i*.1,0,30,1) end
            assert(bounce.monitoring,'later bounce remains part of the same landing')
            for i=1,22 do step(170.6+i*.1,1,0,0,29) end
            assert(not bounce.monitoring and bounce.detected)
        ''')

    def test_jitter_gaps_session_changes_pause_and_goaround(self):
        for scenario in ['jitter','gap','rewind','changed','ended','pause','goaround']:
            with self.subTest(scenario=scenario):
                lua = self.model()
                lua.globals().scenario=scenario
                lua.execute('''
                    start(10,7)
                    if scenario=='jitter' then
                        step(10.1,0,7.1,.01);step(10.15,1,7,0)
                        step(10.3,0,7.1,.01);step(10.6,1,7,0)
                        assert(not bounce.detected and bounce.monitoring)
                    elseif scenario=='pause' then
                        ui.recording.pause_at=10.1
                        for i=1,20 do step(10+i,1) end
                        ui.recording.pause_at=nil;step(30.1,1);assert(bounce.monitoring)
                    elseif scenario=='goaround' then
                        for i=1,70 do step(10+i*.1,0,350,4) end
                        assert(not bounce.monitoring and not bounce.detected)
                    else
                        step(10.1,0,9,.4)
                        if scenario=='changed' then ui.recording.id='other' end
                        if scenario=='ended' then ui.recording.done=true end
                        step(scenario=='gap' and 14 or scenario=='rewind' and 9 or 10.5,1)
                        assert(not bounce.monitoring and not bounce.detected)
                    end
                ''')

    def test_snapshot_refresh_failure_waits_for_explicit_retry(self):
        lua = self.model()
        lua.execute('''
            local rec=ui.recording
            rec.closed=true;rec.summary='original';rec.summary_dirty=true;rec.report_path='original.txt'
            builds=0;ui.build_landing_log_payload=function() builds=builds+1;error('fixture failure') end
            rec.tick=function() end
            for i=1,4 do ui.record_frame({t=i}) end
            assert(builds==1 and rec.export_failed and rec.summary=='original' and rec.saved_path==nil)
        ''')


if __name__ == '__main__':
    unittest.main()

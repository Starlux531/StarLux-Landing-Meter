import tempfile
import unittest
from pathlib import Path
from test_ui_119 import runtime

class RecordingTests(unittest.TestCase):
    def test_post_touch_climb_keeps_bounce_but_ends_confirmed_goaround(self):
        self.lua.execute('''
            rec:tick(sample(1,30),1);rec:tick(sample(1.1,20),1)
            rec:tick(sample(1.2,0,1),1)
            for i=1,70 do local s=sample(1.2+i*.1,40,0);s.vy=4;rec:tick(s,1) end
            assert(rec.file and rec.touch_time==1.2,'low bounce must not be mistaken for go-around')
            for i=1,70 do local s=sample(8.2+i*.1,350,0);s.vy=4;rec:tick(s,1) end
            assert(not rec.file and rec.reason=='go_around')
        ''')

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='lmm119-')
        self.addCleanup(self.temp.cleanup)
        self.lua=runtime(); self.lua.globals().OUT=Path(self.temp.name).as_posix()+'/'
        self.lua.execute('''
            rec=assert(loadfile(ROOT..'LMM_UI_119/core_recording.lua'))().new(OUT)
            function sample(t,h,ground)
                return {t=t,agl=h or 800,lat=25,lon=121,gs=100,vy=-2,ground=ground or 0,
                    identity='test',wind_speed=10,wind_from=90,heading=0,pitch_input=.2}
            end
            function finish()
                rec:stop('manual_end',false); rec:begin_export()
                for i=1,10000 do if not rec.export then break end; rec:export_step() end
                assert(rec.saved_path,rec.error)
            end
        ''')

    def text(self):
        return Path(self.lua.eval('rec.saved_path')).read_text(encoding='utf-8')

    def test_highland_threshold_uses_agl_not_msl(self):
        self.lua.execute('''
            local a=sample(0,2501);a.msl=8501;rec:tick(a,1);assert(not rec.file)
            local b=sample(.1,2500);b.msl=8500;rec:tick(b,1)
            assert(rec.file and rec.start_agl==2500 and not rec.missing)
            local c=sample(.2,1500);c.msl=7500;rec:tick(c,1)
            local d=sample(.3,0,1);d.msl=6000;rec:tick(d,1)
            assert(rec.touch_time==.3);finish()
        ''')
        self.assertIn('META\tstart_reason\tthreshold',self.text())
        self.assertIn('META\theight_source\tsim/flightmodel/position/y_agl',self.text())

    def test_highland_partial_load_and_full_channels(self):
        self.lua.execute('''
            for i=0,10 do
                local s=sample(i*.1,1500-i);s.msl=6000+s.agl
                s.trace_fpm=-650;s.trace_fpm_source='physical_velocity';s.physical_fpm=-650;s.vvi=-640
                s.elevator1=0;s.elevator2=-1;s.aileron1=3;s.aileron2=-3;s.rudder1=2
                s.lever1=.5;s.detent1='CL';s.detent_mode=0;s.engine_count=2
                rec:tick(s,1)
            end
            assert(rec.missing and rec.file);finish()
        ''')
        raw=self.text();self.assertIn('META\tstart_reason\tmid_approach',raw)
        fields=next(l.split('\t')[2:] for l in raw.splitlines() if l.startswith('FIELDS\tT\t'))
        rows=[dict(zip(fields,l.split('\t')[1:])) for l in raw.splitlines() if l.startswith('T\t')]
        self.assertEqual(len(rows),11)
        for r in rows:
            self.assertEqual(r['trace_fpm'],'-650');self.assertEqual(r['vvi'],'-640')
            self.assertEqual(r['elevator1'],'0');self.assertEqual(r['elevator2'],'-1')
            self.assertEqual(r['rudder2'],'');self.assertEqual(r['detent1'],'CL')
            self.assertEqual(r['detent_mode'],'0');self.assertEqual(r['trace_fpm_source'],'physical_velocity')

    def test_low_load_touchdown_and_complete_data_at_end(self):
        self.lua.execute('''
            rec:tick(sample(1),1); rec:tick(sample(1.1),1)
            assert(rec.phase=='APPROACH_RECORDING' and rec.missing)
            rec:tick(sample(1.2,5),1); rec:tick(sample(1.3,0,1),1)
            assert(rec.touch_time==1.3)
            rec:attach_summary('100 ft excerpt - Full recording at the end\\n',OUT..'LMM_test.txt')
            finish()
        ''')
        raw=self.text()
        self.assertIn('100 ft excerpt',raw)
        self.assertLess(raw.index('Recording:'),raw.index('100 ft excerpt'))
        self.assertIn('META\tfront_missing\t1',raw)
        self.assertIn('E\t1.3\ttouchdown',raw)
        self.assertTrue(raw.rstrip().splitlines()[-1].startswith('LMM_RECORDING_END\t1\t'))

    def test_no_fake_touch_from_ground_load_and_paused(self):
        self.lua.execute('''
            rec:tick(sample(1,0,1),1); rec:tick(sample(2,0,1),1)
            assert(not rec.file and not rec.touch_time)
            rec:tick(sample(3,50),1); rec:tick(sample(3.1,40),1)
            local n=rec.samples
            local s=sample(10,0,1); s.paused=true; rec:tick(s,1)
            assert(rec.samples==n and not rec.touch_time)
            rec:shutdown()
        ''')

    def test_loaded_immediately_before_touchdown(self):
        self.lua.execute('''
            rec:tick(sample(1,5),1); rec:tick(sample(1.1,0,1),1)
            assert(rec.file and rec.touch_time==1.1 and rec.start_agl==5)
            finish()
        ''')
        self.assertIn('late_approach_touchdown',self.text())

    def test_final_wind_bucket_and_new_session_clean(self):
        self.lua.execute('''
            rec:tick(sample(0),10); rec:tick(sample(.1),10)
            local s=sample(.2); s.wind_speed=25; rec:tick(s,10)
            rec.route={rule='old',max_offset=99}; finish()
            assert(rec.saved_path)
        ''')
        self.assertIn('W\t0.2\t25',self.text())
        self.lua.execute('''
            rec:start(sample(1),'test_next_session'); assert(rec.route==nil)
            rec:shutdown()
        ''')

    def test_rewind_preserves_old_attempt(self):
        self.lua.execute('''
            rec:tick(sample(100),1); rec:tick(sample(100.1),1)
            local id=rec.id; local old=rec.spool
            rec:tick(sample(90),1); assert(rec.reason=='load_or_discontinuity')
            rec:begin_export(); while rec.export do rec:export_step() end
            rec:tick(sample(91),1); rec:tick(sample(91.1),1)
            assert(rec.id~=id and rec.spool~=old)
            rec:shutdown()
        ''')

    def test_low_speed_without_geometry_strict_threshold_and_two_seconds(self):
        self.lua.execute("""
            rec:tick(sample(0),1); rec:tick(sample(.1),1); rec:tick(sample(.2,0,1),1)
            for i=1,30 do local s=sample(.2+i*.1,0,1); s.gs=30; rec:tick(s,1) end
            assert(rec.file and not rec.low_speed_since)
            for i=0,19 do local s=sample(3.3+i*.1,0,1); s.gs=29.9; rec:tick(s,1) end
            assert(rec.file)
            local s=sample(5.3,0,1); s.gs=29.9;rec:tick(s,1)
            assert(rec.phase=='COMPLETE' and rec.reason=='low_speed')
            assert(rec.last.t<=5.3 and rec.last.t>=5.1)
        """)

    def test_low_speed_reset_speed_airborne_pause_and_gap(self):
        for reset in ('s.gs=30', 's.ground=0', 's.paused=true', 's.t=s.t+2'):
            with self.subTest(reset=reset):
                self.lua.globals().RESET=reset
                self.lua.execute("""
                    rec:shutdown();rec=assert(loadfile(ROOT..'LMM_UI_119/core_recording.lua'))().new(OUT)
                    rec:tick(sample(0),1);rec:tick(sample(.1),1);rec:tick(sample(.2,0,1),1)
                    for i=0,10 do local s=sample(.3+i*.1,0,1);s.gs=20;rec:tick(s,1) end
                    local s=sample(1.4,0,1);s.gs=20;assert(loadstring('return function(s) '..RESET..' end'))()(s);rec:tick(s,1)
                    local base=s.t+.1
                    for i=0,18 do local n=sample(base+i*.1,0,1);n.gs=20;rec:tick(n,1) end
                    assert(rec.file,RESET);rec:shutdown()
                """)

    def test_30_minute_stream_has_bounded_queue_and_wind(self):
        self.lua.execute('''
            rec:tick(sample(0),1)
            for i=1,18000 do local s=sample(i*.1,800); s.wind_speed=10+i%5; rec:tick(s,1); assert(rec.queued<131072) end
            assert(rec.samples==18001)
            finish()
        ''')
        raw=self.text()
        self.assertGreater(raw.count('\nW\t'),1500)
        self.assertLess(len(raw),8_000_000)
        width=None
        for line in raw.splitlines():
            if line.startswith('FIELDS\tW\t'): width=len(line.split('\t'))-1
            if line.startswith('W\t'): self.assertEqual(len(line.split('\t')),width)

    def test_write_failure_has_backoff_and_preserves_fragment(self):
        self.lua.execute('''
            rec:tick(sample(1),1);rec:tick(sample(1.1),1)
            local old=rec.spool;rec.file:close()
            rec.file={write=function() return nil,'injected disk full' end,close=function() return true end}
            rec:emit('E',{1.2,'test'});assert(not rec:flush())
            assert(rec.error=='injected disk full' and not rec.file)
            rec:tick(sample(2),1);assert(not rec.file and rec.spool==old)
            local f=assert(io.open(old,'rb'));f:close()
        ''')

    def test_export_failure_waits_for_explicit_retry(self):
        self.lua.execute('''
            rec:tick(sample(1),1);rec:tick(sample(1.1),1);rec:stop('test',false)
            rec.report_path=OUT..'missing/record.txt';rec:begin_export()
            assert(rec.export_failed and rec.closed and not rec.export)
            rec.report_path=OUT..'recovered.txt';rec:begin_export();assert(not rec.export)
            rec.export_failed=false;rec:begin_export()
            while rec.export do rec:export_step() end
            assert(rec.saved_path)
        ''')

class GeometryTests(unittest.TestCase):
    def test_runway_projection_backtrack_and_low_speed_exclusion(self):
        l=runtime();l.execute("""
            local module=assert(loadfile(ROOT..'LMM_UI_119/core_rollout.lua'))()
            assert(module.network==nil and module.parse==nil)
            local runway={lat1=0,lon1=0,lat2=0,lon2=.03,width_m=45,end1='09',end2='27'}
            local r=module.new(runway,nil,'09','test')
            local along,cross=r:project(10/111195,1000/111195)
            assert(math.abs(along-1000)<.01 and math.abs(cross-10)<.01)
            r:update({lat=0,lon=.01,t=1,ground=1,gs=60})
            local off=r:update({lat=.0001,lon=.011,t=1.1,ground=1,gs=60})
            assert(off.max_offset>11)
            local slow=r:update({lat=.001,lon=.012,t=1.2,ground=1,gs=29})
            assert(slow.max_offset==off.max_offset)
            assert(r:update({lat=0,lon=.009,t=1.3,ground=1,gs=15}).backtrack)
            local rev=module.new(runway,nil,'27','test')
            local a,c=rev:project(10/111195,1000/111195)
            assert(math.abs(a-(r.length-1000))<.01 and math.abs(c+10)<.01)
        """)

class RecoveryTests(unittest.TestCase):
    def test_partial_recovery_never_overwrites(self):
        import importlib.util
        spec=importlib.util.spec_from_file_location('recover',Path(__file__).resolve().parents[1]/'tools/recover_recording_119.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            source=Path(directory)/'source.part';target=Path(directory)/'recovered.txt'
            raw='LMM_RECORDING_BEGIN\t1\nFIELDS\tT\tt\tlat\nT\t1\t25\nT\t2\t'
            source.write_text(raw,encoding='utf-8')
            self.assertEqual(module.recover(source,target),1)
            self.assertIn('META\tphase\tINCOMPLETE',target.read_text(encoding='utf-8'))
            self.assertEqual(source.read_text(encoding='utf-8'),raw)
            with self.assertRaises(FileExistsError):module.recover(source,target)

if __name__=='__main__': unittest.main(verbosity=2)

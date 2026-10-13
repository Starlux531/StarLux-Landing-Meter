"""Offline LuaJIT ILS geometry, loaded-navdata matching, budgets and log tests."""
import tempfile
import unittest
import importlib.util
from pathlib import Path
from test_ui_119 import runtime
import test_ui_119 as baseline

LOC = '4 22.596677778 108.161941667 436 11090 18 82306.719 IUY ZGNN ZG 23 ILS-cat-I'
GS = '6 22.615875000 108.185730556 436 11090 18 300226.719 IUY ZGNN ZG 23 GS'


class ILSTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='lmm-ils-')
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.l = runtime()
        self.l.globals().NAVROOT = self.path.as_posix()
        self.l.globals().LOC = LOC
        self.l.globals().GS = GS
        self.l.execute('''
          I=assert(loadfile(ROOT..'LMM_UI_119/core_ils.lua'))()
          loc=I.parse(LOC,1150,'fixture'); gs=I.parse(GS,1150,'fixture')
          api={}; sdk={loc,gs}; queries=0
          function api.XPLMFindNavAid(name,id,lat,lon,freq,kind)
            queries=queries+1
            for i,n in ipairs(sdk) do
              if n.id==id and n.frequency==freq and (n.kind==4 and 8 or n.kind==5 and 16 or 32)==kind then return i end
            end
            return -1
          end
          function api.XPLMGetNavAidInfo(i)
            local n=sdk[i]
            return n.kind==4 and 8 or n.kind==5 and 16 or 32,n.lat,n.lon,99999,n.frequency,n.course,n.id,'unused SDK name'
          end
          m=I.new({root=NAVROOT,api=api})
          target={airport='ZGNN',runway='23',lat=22.618,lon=108.189,course=226.719,length=3200}
          function ready()
            for i=0,10000 do m:scan(i*.051); if m.state~='loading' and m.state~='pending' then break end end
            assert(m.state=='ready',m.state)
          end
          function point(ref,forward,right,height)
            local c=ref.ils_loc_course_true*math.pi/180
            local e=forward*math.sin(c)+right*math.cos(c)
            local n=forward*math.cos(c)-right*math.sin(c)
            return {lat=ref.ils_loc_lat+n/111195,lon=ref.ils_loc_lon+e/(111195*math.cos(ref.ils_loc_lat*math.pi/180)),
                    ground=0,msl=(height or 1000)/.3048,t=0,gs=100,identity='test'}
          end
        ''')

    def navfile(self, relative='Resources/default data/earth_nav.dat', rows=None, version=1150):
        p = self.path / relative
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(f'I\n{version} Version - fixture\n' + '\n'.join(rows if rows is not None else [LOC, GS]) + '\n99\n')
        return p

    def test_actual_zgnn_decoding_and_sdk_height_not_used(self):
        self.navfile()
        self.l.execute('''ready(); ref=m:resolve(target)
            assert(ref.ils_status=='ils'); assert(math.abs(ref.ils_loc_course_true-226.719)<1e-8)
            assert(math.abs(ref.ils_gs_elevation_m-132.8928)<1e-8 and ref.ils_gs_angle_deg==3)
            assert(ref.ils_loc_id=='IUY' and ref.ils_airport=='ZGNN' and ref.ils_runway=='23')
            assert(ref.ils_loc_half_width_deg==nil and ref.ils_scale_source=='reference')
            assert(queries==2)
        ''')

    def test_parser_versions_packed_nonstandard_gs_and_bad_rows(self):
        self.l.execute('''
            for _,v in ipairs({1100,1150,1200}) do
                assert(I.parse(GS:gsub('300226.719','325226.719'),v).angle==3.25)
            end
            assert(not I.parse(GS,9999))
            assert(not I.parse(GS:gsub('300226.719','300426.719'),1150))
            assert(not I.parse(GS:gsub('300226.719','226.719'),1150))
            assert(not I.parse(GS:gsub('22.615875000','99.0'),1150))
            assert(not I.parse(GS:gsub('23 GS','00 GS'),1150))
        ''')

    def test_sign_scaling_limits_ground_and_backcourse(self):
        self.navfile()
        self.l.execute('''ready(); ref=m:resolve(target)
            local s=point(ref,-8000,-8000*math.tan(1.25*math.pi/180))
            local out=I.geometry(ref,s)
            assert(out.loc_valid and math.abs(out.loc_dots-1)<1e-8)
            s=point(ref,-8000,8000*math.tan(1.25*math.pi/180))
            assert(math.abs(I.geometry(ref,s).loc_dots+1)<1e-8)
            for _,s in ipairs({point(ref,100,0),point(ref,-40000,0),point(ref,-.1,0),point(ref,-8000,8000)}) do
                local o=I.geometry(ref,s); assert(not o.loc_valid and o.loc_dots==nil and o.gs_dots==nil)
            end
            s=point(ref,-8000,0); s.ground=nil; assert(not I.geometry(ref,s).loc_valid)
            s.ground=1; assert(not I.geometry(ref,s).gs_valid)
            s.ground=0; s.replay=true; assert(not I.geometry(ref,s).loc_valid)
        ''')

    def test_high_terrain_msl_glideslope_needle_and_horizontal_distance(self):
        self.l.execute('''
            ref={ils_status='ils',ils_loc_lat=30,ils_loc_lon=120,ils_loc_course_true=0,
                ils_gs_lat=30,ils_gs_lon=120,ils_gs_elevation_m=2000,ils_gs_angle_deg=3.25}
            s=point(ref,-10000,0,2000+10000*math.tan(2.9*math.pi/180)); s.agl=20
            out=I.geometry(ref,s); assert(out.gs_valid and math.abs(out.gs_dots-1)<1e-8)
            s.msl=(2000+10000*math.tan(3.6*math.pi/180))/.3048
            assert(math.abs(I.geometry(ref,s).gs_dots+1)<1e-8)
            s.msl=nil; out=I.geometry(ref,s); assert(out.loc_valid and not out.gs_valid and out.gs_dots==nil)
            s.msl=0/0; assert(not I.geometry(ref,s).gs_valid)
        ''')

    def test_dateline_projection(self):
        self.l.execute('''
            ref={ils_status='loc_only',ils_loc_lat=0,ils_loc_lon=-179.99,ils_loc_course_true=90}
            out=I.geometry(ref,{lat=0,lon=179.99,ground=0})
            assert(out.loc_valid and math.abs(out.loc_dots)<1e-9)
        ''')

    def test_js_contract_gs_uses_18nm_shared_sector_and_no_angle_gate(self):
        self.l.execute('''
            ref={ils_status='ils',ils_loc_lat=0,ils_loc_lon=0,ils_loc_course_true=0,
                ils_gs_lat=0,ils_gs_lon=0,ils_gs_elevation_m=2000,ils_gs_angle_deg=3}
            s=point(ref,-25000,5000,1000) -- >10 NM, >8 degrees LOC, negative aircraft angle
            out=I.geometry(ref,s); assert(out.loc_valid and out.gs_valid and out.gs_dots>2)
            s=point(ref,-18*1852-.1,0,2000); assert(not I.geometry(ref,s).loc_valid)
            s=point(ref,-18*1852+.1,0,2000); assert(I.geometry(ref,s).gs_valid)
            ref.ils_gs_lat=-.3; s=point(ref,-10000,0); out=I.geometry(ref,s)
            assert(out.loc_valid and not out.gs_valid) -- passed the GS aerial
        ''')

    def test_loc_only_and_no_ils(self):
        self.navfile(rows=[LOC.replace('4 ', '5 ', 1), GS])
        self.l.execute('''sdk[1].kind=5; ready(); ref=m:resolve(target)
            assert(ref.ils_status=='loc_only' and ref.ils_gs_lat==nil)
            target.runway='05'; assert(m:resolve(target).ils_status=='no_ils')
        ''')

    def test_gs_pair_requires_id_frequency_region_runway_course(self):
        for row in [GS.replace('IUY','IUZ'), GS.replace('11090','11030'), GS.replace('ZG 23','ZH 23'),
                    GS.replace('23 GS','05 GS'), GS.replace('300226.719','300046.719')]:
            with self.subTest(row=row):
                self.navfile(rows=[LOC,row])
                self.l.execute("m=I.new({root=NAVROOT,api=api}); ready(); assert(m:resolve(target).ils_status=='loc_only')")

    def test_airport_parallel_and_opposite_direction_not_confused(self):
        self.navfile(rows=[LOC.replace('ZGNN','ZGXX'), GS])
        self.l.execute("ready(); assert(m:resolve(target).ils_status=='no_ils')")
        self.navfile(rows=[LOC.replace('23 ILS','23L ILS'), GS])
        self.l.execute("m=I.new({root=NAVROOT,api=api}); ready(); assert(m:resolve(target).ils_status=='no_ils')")
        self.navfile()
        self.l.execute("m=I.new({root=NAVROOT,api=api}); ready(); target.course=46.719; assert(m:resolve(target).ils_status=='no_ils')")

    def test_sdk_exact_match_rejects_substring_ids_course_location_frequency(self):
        self.navfile()
        self.l.execute('''ready()
            local actual=api.XPLMGetNavAidInfo
            for _,field in ipairs({'id','course','lat','frequency'}) do
                api.XPLMGetNavAidInfo=function(i)
                    local k,lat,lon,h,f,c,id,name=actual(i)
                    if field=='id' then id='XIUY' elseif field=='course' then c=c+180
                    elseif field=='lat' then lat=lat+.01 else f=f+20 end
                    return k,lat,lon,h,f,c,id,name
                end
                m.cache={}; assert(m:resolve(target).ils_status=='sdk_mismatch')
            end
        ''')

    def test_layer_precedence_custom_replaces_default_user_overrides_curated(self):
        self.navfile(rows=[LOC.replace('IUY','BAD'), GS.replace('IUY','BAD')])
        self.navfile('Custom Data/earth_nav.dat')
        self.navfile('Global Scenery/Global Airports/Earth nav data/earth_nav.dat', [GS.replace('300226.719','320226.719')])
        self.navfile('Custom Data/user_nav.dat', [GS.replace('300226.719','325226.719')])
        self.l.execute('''ready(); ref=m:resolve(target)
            assert(ref.ils_status=='ils' and ref.ils_gs_angle_deg==3.25)
            assert(ref.ils_loc_source_path:find('Custom Data/earth_nav.dat',1,true))
            assert(ref.ils_gs_source_path:find('Custom Data/user_nav.dat',1,true))
        ''')

    def test_arinc_override_unknown_format_and_missing_api_fail_explicitly(self):
        self.navfile('Custom Data/earth_424.dat', [])
        self.l.execute("m:scan(0); assert(m.state=='unsupported_arinc_override' and queries==0)")
        (self.path/'Custom Data/earth_424.dat').unlink()
        self.navfile(version=9999)
        self.l.execute("m=I.new({root=NAVROOT,api=api}); m:scan(0); assert(m.state=='unsupported_navdata')")
        self.navfile()
        self.l.execute("m=I.new({root=NAVROOT,api={}}); ready(); assert(m:resolve(target).ils_status=='sdk_mismatch')")

    def test_ambiguous_localizers_never_guessed(self):
        self.navfile(rows=[LOC, LOC.replace('IUY','ABC'), GS])
        self.l.execute("ready(); assert(m:resolve(target).ils_status=='ambiguous_localizer' and queries==0)")

    def test_bounded_scan_and_cached_positive_negative_sdk_queries(self):
        self.navfile(rows=['2 1 1 1 200 25 0 N ENRT ZG NDB']*10000+[LOC,GS])
        self.l.execute('''
            for i=0,120 do m:scan(i/120) end
            assert(m.stats.steps<=21 and m.stats.bytes<=21*32768)
            ready(); ref=m:resolve(target); assert(ref.ils_status=='ils')
            for i=1,10000 do m:resolve(target) end
            assert(queries==2)
            target.runway='05'; for i=1,10000 do m:resolve(target) end
            assert(queries==2)
        ''')

    def test_approach_selection_ambiguity_and_confirmed_route(self):
        self.l.execute('''
            r={lat1=0,lon1=0,lat2=.03,lon2=0,end1='36',end2='18'}
            cache={TEST={runways={r}}}
            s={t=0,lat=-.05,lon=0,ground=0,true_heading=0,gs=100,identity='A'}
            t=I.choose(s,cache); assert(t.runway=='36')
            s.true_heading=180; assert(not I.choose(s,cache)); s.true_heading=0
            cache.NEXT={runways={r}}; assert(not I.choose(s,cache)); cache.NEXT=nil
            m:update(s,cache); assert(m.selected_target.runway=='36')
            for i=1,119 do s.t=i/120; m:update(s,cache) end
            assert(m.stats.selections==1)
            s.t=1; s.ground=1; m:update(s,cache,I.target('TEST',r,'18'))
            assert(m.selected_target.runway=='18' and not m.runtime.loc_valid)
            s.t=.2; m:update(s,{}); assert(not m.selected_target)
        ''')

    def test_recording_snapshots_final_reference_without_cross_session_leak(self):
        self.navfile()
        self.l.execute('''
            ready(); ref=m:resolve(target)
            rec=assert(loadfile(ROOT..'LMM_UI_119/core_recording.lua'))().new(NAVROOT..'/')
            s={t=0,lat=22.6,lon=108.1,msl=3000,agl=1000,ground=0,gs=100,vy=-2,identity='test'}
            rec:tick(s,1,nil,ref)
            s={t=.1,lat=22.6,lon=108.1,msl=3000,agl=999,ground=0,gs=100,vy=-2,identity='test'}
            rec:tick(s,1,nil,ref); assert(rec.file)
            ref.ils_loc_id='MUTATED'; assert(rec.ils_reference.ils_loc_id=='IUY')
            rec:stop('test',false); spool=rec.spool
            rec.closed=false; rec:start(s,'new'); assert(rec.ils_reference==nil); rec:stop('test',false)
        ''')
        text = Path(self.l.eval('spool')).read_text()
        self.assertIn('META\tils_loc_id\tIUY\n',text)
        self.assertIn('META\tils_gs_elevation_m\t132.8928\n',text)
        self.assertNotIn('half_width',text)

    def start_recording(self):
        self.navfile()
        self.l.execute('''
            ready(); ref=m:resolve(target); ref.ils_selection='approach_geometry'
            rec=assert(loadfile(ROOT..'LMM_UI_119/core_recording.lua'))().new(NAVROOT..'/')
            function rs(t)
                return {t=t,lat=22.6,lon=108.1,msl=3000,agl=1000,ground=0,gs=100,vy=-2,identity='test'}
            end
            assert(rec:start(rs(0),'test')); rec:tick(rs(.001),1,nil,ref)
        ''')
        self.addCleanup(lambda: self.l.execute('if rec.file then rec.file:close(); rec.file=nil end'))

    def metadata(self):
        raw=Path(self.l.eval('rec.spool')).read_text()
        meta={}
        for line in raw.splitlines():
            cells=line.split('\t')
            if len(cells)==3 and cells[0]=='META':
                meta[cells[1]]=cells[2]
        return raw,meta

    def test_recording_unchanged_fields_reuse_snapshot_and_in_place_selection_updates(self):
        self.start_recording()
        self.l.execute('''
            snapshot=rec.ils_reference
            for i=1,240 do rec:tick(rs(i/240),1,nil,ref); assert(rec.ils_reference==snapshot) end
            equal={}; for k,v in pairs(ref) do equal[k]=v end
            rec:tick(rs(1.001),1,nil,equal); assert(rec.ils_reference==snapshot)
        ''')
        raw,meta=self.metadata()
        self.assertEqual(raw.count('META\tils_version\t'),1)
        self.assertEqual(meta['ils_selection'],'approach_geometry')
        self.l.execute('''
            ref.ils_selection='touchdown'; rec:tick(rs(1.002),1,nil,ref)
            assert(rec.ils_reference~=snapshot and snapshot.ils_selection=='approach_geometry')
        ''')
        raw,meta=self.metadata()
        self.assertEqual(raw.count('META\tils_version\t'),2)
        self.assertEqual(meta['ils_selection'],'touchdown')
        self.assertNotIn('LMM_RECORDING_END',raw)
        self.l.execute("rec:stop('test',false)")
        self.assertEqual(self.metadata()[0].count('META\tils_version\t'),3)

    def test_recording_loc_only_no_ils_and_missing_reference_clear_old_metadata(self):
        self.start_recording()
        self.l.execute('''
            only={}; for k,v in pairs(ref) do if not k:match('^ils_gs_') then only[k]=v end end
            only.ils_status='loc_only'; rec:tick(rs(.002),1,nil,only)
        ''')
        _,meta=self.metadata()
        self.assertEqual(meta['ils_loc_id'],'IUY')
        self.assertEqual(meta['ils_gs_lat'],'')
        self.assertEqual(meta['ils_gs_angle_deg'],'')
        self.l.execute('''
            none={ils_version=1,ils_model='geometric_reference',ils_airport='ZGNN',ils_runway='05',ils_status='no_ils'}
            rec:tick(rs(.003),1,nil,none)
            assert(rec.ils_reference.ils_loc_lat==nil and rec.ils_reference.ils_gs_lat==nil)
        ''')
        _,meta=self.metadata()
        self.assertEqual(meta['ils_runway'],'05')
        self.assertEqual(meta['ils_status'],'no_ils')
        for key in ('ils_loc_id','ils_loc_lat','ils_loc_course_true','ils_gs_elevation_m','ils_gs_angle_deg'):
            self.assertEqual(meta[key],'')
        self.l.execute('''
            rec:tick(rs(.004),1,nil,nil); missing=rec.ils_reference
            rec:tick(rs(.005),1,nil,nil); assert(rec.ils_reference==missing)
        ''')
        raw,meta=self.metadata()
        self.assertEqual(raw.count('META\tils_version\t'),4)
        self.assertEqual(meta['ils_status'],'reference_unavailable')
        self.assertEqual(meta['ils_airport'],'')

    def test_interrupted_part_recovery_keeps_latest_metadata_and_tombstones(self):
        self.start_recording()
        self.l.execute('''
            rec:tick(rs(.002),1,nil,{ils_version=1,ils_model='geometric_reference',
                ils_airport='OTHER',ils_runway='09',ils_status='no_ils'})
        ''')
        raw,_=self.metadata()
        self.assertNotIn('LMM_RECORDING_END',raw)
        # Read while the writer is still open: on-change file flush must make the
        # whole snapshot available without stop() or even the next sample tick.
        recovery=Path(__file__).resolve().parents[1]/'tools/recover_recording_119.py'
        spec=importlib.util.spec_from_file_location('ils_recovery_test',recovery)
        module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
        target=self.path/'recovered.txt'
        self.assertEqual(module.recover(Path(self.l.eval('rec.spool')),target),1)
        recovered={}
        for line in target.read_text().splitlines():
            cells=line.split('\t')
            if len(cells)==3 and cells[0]=='META': recovered[cells[1]]=cells[2]
        self.assertEqual(recovered['ils_airport'],'OTHER')
        self.assertEqual(recovered['ils_status'],'no_ils')
        self.assertEqual(recovered['ils_loc_lat'],'')
        self.assertEqual(recovered['ils_gs_angle_deg'],'')
        self.assertEqual(recovered['end_reason'],'recovered_after_interruption')

    def test_metadata_flush_failure_stops_recording_without_throwing(self):
        self.start_recording()
        self.l.execute('''
            rec.file:close()
            rec.file={write=function() return true end,flush=function() return nil,'disk failure' end,
                close=function() was_closed=true; return true end}
            ref.ils_selection='touchdown'; rec:tick(rs(.002),1,nil,ref)
            assert(was_closed and not rec.file and rec.phase=='INCOMPLETE' and rec.error=='disk failure')
        ''')

    def test_main_runtime_load_and_overlay_object(self):
        l=baseline.RecorderTests().load_recorder()
        l.execute('''
            assert(ui.dev.ils==ui.ils.runtime and not ui.dev.ils.loc_valid)
            assert(ui.ils_module.meta_keys[1]=='ils_version')
            ma_lmm118_shutdown()
        ''')

    def test_main_frame_connects_cached_approach_and_recording_metadata(self):
        l=baseline.RecorderTests().load_recorder()
        l.execute('''
            ui.ils.state='ready'
            ui.runway_state.cache={TEST={runways={{lat1=0,lon1=0,lat2=.03,lon2=0,end1='36',end2='18'}}}}
            ui.ils.index['TEST:36']={{kind=4,id='ITST',airport='TEST',region='XX',runway='36',
                lat=.031,lon=0,course=0,frequency=11090,path='fixture'}}
            function XPLMFindNavAid() return 1 end
            function XPLMGetNavAidInfo() return 8,.031,0,123,11090,0,'ITST','TEST 36 ILS' end
            ui.recording.tick=function(self,s,interval,route,reference) captured=reference end
            ui.record_frame({t=0,lat=-.05,lon=0,ground=0,msl=1000,agl=1000,true_heading=0,gs=100,identity='A'})
            assert(captured and captured.ils_loc_id=='ITST' and ui.dev.ils.loc_valid)
            assert(ui.dev.route==nil) -- approach hypothesis must not create touchdown evidence
        ''')


if __name__=='__main__':
    unittest.main()

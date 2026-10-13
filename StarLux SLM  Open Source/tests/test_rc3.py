"""RC3 airport disambiguation, low approach grading and real overlay draw geometry."""
import unittest
from test_ui_119 import runtime
import test_ui_119 as baseline
from test_overlay_ils_119 import overlay_runtime

class FlareTests(unittest.TestCase):
    def model(self):
        l=runtime();l.execute('''
            F=assert(loadfile(ROOT..'LMM_UI_119/core_flare.lua'))();f=F.new()
            function step(t,h,gs,ground)
                f:update({t=t,agl=h,msl=6000+h,gs=gs or 140,ground=ground or 0})
            end
            function finish(length)step(30,0,100,1);return f:result(length or 3000)end
        ''');return l
    def test_length_limits_and_nonred_score(self):
        self.model().execute('''
            for i=0,100 do step(i/10,10) end
            local r=finish(3000);assert(r.long_float and r.limit==450 and r.seconds>=5)
            assert(F.score('NICE',r)=='ATTENTION' and F.score('STABLE',r)=='ATTENTION')
            assert(F.score('ATTENTION',r)=='ATTENTION' and F.score('UNSTABLE',r)=='UNSTABLE')
            assert(f:result(1500).limit==300 and f:result(5000).limit==600)
            assert(not f:result(nil).eligible and not f:result(nil).long_float)
            assert(not f:result(3000,'go_around').eligible)
        ''')
    def test_five_seconds_required_and_strict_distance(self):
        self.model().execute('''
            for i=0,48 do step(i/10,10,400) end
            assert(not finish(1000).long_float,'fast but short does not qualify')
            f=F.new();for i=0,70 do step(i/10,10,70)end
            assert(not finish(1000).long_float,'slow distance under 300m')
            local r=f:result(1000);f.flat_distance=300;assert(not f:result(1000).long_float)
            f.flat_distance=300.1;assert(f:result(1000).long_float)
        ''')
    def test_normal_descent_noise_bounce_and_terrain(self):
        self.model().execute('''
            for i=0,50 do step(i/10,20-i*.4)end
            local r=finish();assert(not r.long_float and not r.balloon)
            for i=301,500 do step(i/10,10+i*.1)end
            assert(not f:result(3000).balloon,'bounce after first touchdown excluded')
            f=F.new();for i=0,150 do f:update({t=i*.1,agl=10+math.sin(i)*.4,msl=6010+math.sin(i)*.2,gs=70,ground=0})end
            assert(not finish().balloon)
            f=F.new();for i=0,30 do f:update({t=i*.1,agl=10+i*.2,msl=6010-i*.2,gs=140,ground=0})end
            assert(not finish().balloon,'terrain rises are not aircraft climbs')
        ''')
    def test_rise_persistence_gap_and_goaround(self):
        self.model().execute('''
            for i=0,20 do step(i/10,10+i*.2)end
            local r=finish();assert(r.balloon and r.rise>=3 and r.rise_seconds>=1)
            f=F.new();for i=0,6 do step(i/10,10+i)end;assert(not finish().balloon,'spike too brief')
            f=F.new();for i=0,35 do step(i/10,10)end;for i=100,135 do step(i/10,10)end
            assert(not finish(1000).long_float,'no joining across loading gap')
            f=F.new();for i=0,20 do step(i/10,10+i*.2)end;step(3,100)
            for i=40,90 do step(i/10,20-(i-40)*.4)end
            assert(not finish().balloon,'new approach excludes earlier goaround evidence')
        ''')

class AirportTests(unittest.TestCase):
    def model(self):
        l=baseline.RecorderTests().load_recorder();l.execute('''
            context=getup(ui.select_touchdown_runway,'landing_context')
            context.touch_latitude=18.304300718;context.touch_longitude=109.422527502
            context.touch_vx_mps=-62;context.touch_vz_mps=8;context.recording_id=ui.recording.id
            local line='100 45.00 2 2 0.30 1 3 0 08 18.3008653 109.3963389 0 60 7 1 0 0 26 18.3050132 109.4281967 0 60 7 1 0 0'
            runway=ui.parse_runway_row(line);rs=ui.runway_state
            cached={runways={runway},metadata={icao_code='ZJSY',airport_name='Sanya Phoenix'},source={path='fixture',label='fixture'}}
            rs.airport_nav={XZ0024={latitude=18.3043,longitude=109.4225,name='[H] Sanya Tianya'},ZJSY={latitude=18.301667,longitude=109.413333,name='Sanya Phoenix'}}
            rs.index.complete=true;rs.index.entries={ZJSY={}}
            ui.discover_nearby_prefetch_airports=function() return 'XZ0024' end
        ''');return l
    def test_sanya_actual_touchdown_prefers_runway_over_heliport(self):
        self.model().execute('''
            rs.cache.ZJSY=cached
            assert(ui.begin_landing_runway_search('XZ0024',10))
            assert(context.airport_id=='ZJSY' and context.runway=='26' and context.runway_confidence=='HIGH')
            assert(math.abs(context.touchdown_from_threshold_m-603.7)<1)
            assert(math.abs(context.centerline_offset_m-2.83)<.1)
        ''')
    def test_cold_cache_skips_heliport_and_retries_asynchronously(self):
        self.model().execute('''
            starts={};ui.start_runway_resolver=function(id,now,mode)
                starts[#starts+1]=id;rs.target_airport=id;rs.mode=mode;rs.active=true;return true
            end
            assert(ui.begin_landing_runway_search('XZ0024',10));assert(starts[1]=='ZJSY' and #starts==1)
            rs.active=false;rs.cache.ZJSY=cached;ui.process_runway_resolver(10.1)
            assert(starts[2]=='ZJSY' and rs.landing_search==nil)
        ''')
    def test_nearby_search_total_budget_and_ambiguity(self):
        self.model().execute('''
            rs.landing_search=10;rs.landing_candidates={'ZJSY'};rs.active=false
            ui.process_runway_resolver(41);assert(rs.landing_search==nil and not rs.active)
            rs.cache.ZJSY=cached;rs.cache.OTHER=cached
            assert(not ui.begin_landing_runway_search('XZ0024',50));assert(not context.runway_detected)
        ''')
    def test_complete_index_does_not_queue_heliport_as_land_airport(self):
        self.model().execute('''
            queued={};ui.enqueue_runway_prefetch=function(id)queued[#queued+1]=id end
            XPLMFindNavAid=function()return 1 end
            XPLMGetNavAidInfo=function()return 1,18.3043,109.4225,0,0,0,'XZ0024','[H] Sanya Tianya' end
            ui.probe_prefetch_airport(18.3,109.4,18.3,109.4,15,true);assert(#queued==0)
            XPLMGetNavAidInfo=function()return 1,18.3,109.4,0,0,0,'ZJSY','Sanya Phoenix' end
            ui.probe_prefetch_airport(18.3,109.4,18.3,109.4,15,true);assert(queued[1]=='ZJSY')
        ''')

class OverlayTests(unittest.TestCase):
    def test_yaw_center_and_extents_match_cross_at_multiple_sizes(self):
        l=overlay_runtime();l.execute('''
            for _,size in ipairs({120,180,240,360}) do
                model.config.stick_size=size;renderer:tick();window=renderer.windows.stick;draw_overlay()
                local lines=select_color(rgba(86,180,235,89));local cross,yaw
                for _,p in ipairs(lines) do
                    if p[3]-p[1]>10 and math.abs(p[6]-p[2]-1)<.1 then
                        if math.abs(p[2]-(window.y+16))<.1 then yaw=p else cross=p end
                    end
                end
                assert(cross and yaw and math.abs(cross[1]-yaw[1])<.01 and math.abs(cross[3]-yaw[3])<.01)
            end
        ''')
    def test_combined_pair_missing_channels_reverse_fold_and_restore(self):
        l=overlay_runtime();l.execute('''
            model.config.throttle=true;model.config.n1=true;model.config.engine_combined=true
            model.visual_state={reverse={true,false,false,false}};model.engine_count=4
            for i=1,4 do model.engine['throttle_'..i..'_valid']=true;model.engine['throttle_'..i..'_ratio']=.5;model.engine['n1_'..i..'_valid']=i~=3;model.engine['n1_'..i..'_percent']=82.3 end
            renderer:tick();window=renderer.windows.throttle;draw_overlay()
            assert(window.w>=180 and (not renderer.windows.n1 or not renderer.windows.n1.visible))
            local thr,n1,missing,reverse=0,0,0,0
            for _,t in ipairs(texts)do if t.text=='THR'then thr=thr+1 elseif t.text=='N1'then n1=n1+1 elseif t.text=='--'then missing=missing+1 elseif t.text=='R 1'then reverse=reverse+1 end
                assert(t.x>=window.x and t.x<window.x+window.w and t.y>=window.y and t.y<window.y+window.h)
            end
            assert(thr==4 and n1==4 and missing==1 and reverse==1)
            local saved=model.config.throttle_size;model.config.throttle_collapsed=true;renderer:tick();assert(window.collapsed)
            model.config.throttle_collapsed=false;model.config.engine_combined=false;renderer:tick()
            assert(renderer.windows.n1.visible and model.config.throttle_size==saved)
        ''')

class IntegrationTests(unittest.TestCase):
    def test_final_grade_report_and_no_penalty_leak_between_sessions(self):
        l=baseline.RecorderTests().load_recorder();l.execute('''
            local context=getup(ui.build_landing_log_payload,'landing_context')
            getup(ma_landing_meter_update,'landing_complete',true,true)
            getup(refresh,'landing_status','NICE',true)
            ui.recording.id='flight';context.recording_id='flight';context.runway_detected=true
            local r=ui.rollout_module.new({lat1=0,lon1=0,lat2=0,lon2=.03,width_m=45,end1='09',end2='27',displaced1_m=100},nil,'09','test')
            r.session_id='flight';ui.dev.route=r
            ui.recording.flare=ui.flare_module.new();local f=ui.recording.flare
            for i=0,120 do f:update({t=i*.1,agl=10,msl=6010,gs=140,ground=0})end
            f:update({t=12.1,ground=1})
            ui.apply_rollout_score();assert(getup(refresh,'landing_status')=='ATTENTION')
            assert(math.abs(ui.flare_result().usable_length-(r.length-100))<.01)
            for i=1,50 do ui.apply_rollout_score()end;assert(getup(refresh,'landing_status')=='ATTENTION')
            local ok,out=ui.build_landing_log_payload('fixture.txt');assert(ok and out.content:find('长平飘',1,true))
            ui.set_global_language('en');local ok,out=ui.build_landing_log_payload('fixture.txt');assert(ok and out.content:find('Long float',1,true));english=out.content
            getup(refresh,'landing_status','UNSTABLE',true);ui.apply_rollout_score();assert(getup(refresh,'landing_status')=='UNSTABLE')
            ui.recording.id='new-flight';getup(refresh,'landing_status','NICE',true);ui.apply_rollout_score();assert(getup(refresh,'landing_status')=='NICE')
        ''')
        import re
        self.assertIsNone(re.search(r'[\u4e00-\u9fff]',l.eval('english')))

if __name__=='__main__':unittest.main(verbosity=2)

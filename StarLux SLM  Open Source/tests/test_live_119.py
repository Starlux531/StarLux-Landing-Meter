"""Behavioral input routing and native overlay tests, without a live simulator."""
import unittest
from pathlib import Path
from test_ui_119 import runtime, ROOT
import test_ui_119 as baseline

class InputTests(unittest.TestCase):
    def model(self):
        l=runtime()
        l.execute('''
            values={a=0,b=0,c=0}; kinds={a=2,b=2,c=2}
            specs={}; for _,axis in ipairs({'pitch','roll','yaw'}) do
              specs[axis]={candidates={{id='joystick',path='a'},{id='cockpit',path='b'},{id='flight_control',path='c'}}}
            end
            inputs=assert(loadfile(ROOT..'LMM_UI_119/core_inputs.lua'))().new(specs,{
              find=function(p) return values[p]~=nil and p or nil end,
              types=function(p) return kinds[p] end,
              read=function(p) if p=='error' then error('disconnected') end; return values[p] end})
            inputs:update(0)
        ''')
        return l

    def test_zero_is_valid_and_bad_types_are_not(self):
        l=self.model(); l.execute('''
            assert(inputs.axes.pitch.valid and inputs.axes.pitch.value==0)
            kinds.a=16; inputs:probe(); inputs:update(1)
            assert(inputs.axes.pitch.candidates[1].status=='type')
            values.b=0/0; values.c=7; inputs:update(2)
            assert(not inputs.axes.pitch.valid)
        ''')

    def test_dynamic_source_and_history_are_independent(self):
        l=self.model(); l.execute('''
            old={}; inputs:capture(old)
            values.b=.4; inputs:update(.1)
            assert(inputs.axes.pitch.selected.id=='cockpit')
            new={}; inputs:capture(new)
            assert(new.pitch_input_ratio==.4 and new.pitch_raw_joystick==0)
            assert(old.pitch_input_ratio==0 and old.pitch_input_source=='a')
            assert(inputs:select('pitch','joystick'))
            inputs:update(.2); assert(inputs.axes.pitch.value==0)
            assert(inputs.axes.roll.value==.4)
            values.a=nil; inputs:probe(); inputs:update(.3)
            assert(not inputs.axes.pitch.valid) -- never silently replace a manual choice
            assert(inputs.axes.roll.valid)
        ''')

    def test_late_binding_custom_and_time_reset(self):
        l=self.model(); l.execute('''
            assert(not inputs:set_custom('pitch','bad\\npath'))
            assert(inputs:set_custom('pitch','custom/yoke'))
            inputs:update(1); assert(not inputs:select('pitch','custom'))
            values['custom/yoke']=.7; kinds['custom/yoke']=2
            inputs:update(3); assert(inputs:select('pitch','custom'))
            inputs:update(.5); assert(inputs.axes.pitch.value==.7)
            inputs:set_identity('another aircraft'); inputs:update(.6)
            assert(inputs.axes.pitch.mode=='auto')
            assert(#inputs.axes.pitch.candidates==3)
        ''')

    def test_slow_motion_is_not_mistaken_for_stuck_input(self):
        l=self.model(); l.execute('''
            for i=1,20 do values.b=i*.001; inputs:update(i*.05) end
            assert(inputs.axes.pitch.selected.id=='cockpit')
        ''')

class LiveIntegrationTests(unittest.TestCase):
    def wind_model(self):
        l=baseline.RecorderTests().load_recorder()
        l.execute('''
            finds,reads=0,0;wind_speed,wind_from=10,270
            XPLMFindDataRef=function(p) finds=finds+1;return p end
            XPLMGetDataRefTypes=function() return 2 end
            XPLMGetDataf=function(p) reads=reads+1;if p:find('speed',1,true) then return wind_speed end;return wind_from end
            ui.dev.config.stick=true;ui.dev.config.wind_interval=10
        ''')
        return l

    def test_live_wind_per_frame_cached_handles_and_disabled_cost(self):
        l=self.wind_model()
        l.execute('''
            for i=1,120 do
                wind_from=270+i*.1
                ui.dev:update_wind(i/120,0,5,99,50)
                assert(ui.dev.wind.from==wind_from and ui.dev.wind.source=='aircraft')
            end
            assert(finds==2 and reads==240)
            assert(math.abs(ui.dev.wind.speed-19.438444924406)<1e-9)
            ui.dev.config.stick=false;ui.dev:update_wind(2,0,0,99,50)
            assert(not ui.dev.wind.valid and reads==240 and finds==2)
            ui.dev.debug=true;ui.dev:update_wind(3,0,0,99,50);assert(reads==242)
            ui.dev.config.stick_wind=false;ui.dev:update_wind(4,0,0,99,50);assert(reads==242)
        ''')

    def test_live_wind_true_heading_rotation_wrap_and_calm(self):
        l=self.wind_model()
        l.execute('''
            for _,row in ipairs({{270,0,1,0},{90,0,-1,0},{0,0,0,-1},{0,90,1,0}}) do
                wind_from=row[1];ui.dev:update_wind(1,row[2],17,99,50)
                assert(math.abs(ui.dev.wind.dx-row[3])<1e-9 and math.abs(ui.dev.wind.dy-row[4])<1e-9)
            end
            wind_from=359;ui.dev:update_wind(2,0,0,99,50);local dx=ui.dev.wind.dx
            wind_from=1;ui.dev:update_wind(3,0,0,99,50);assert(math.abs(dx-ui.dev.wind.dx)<.04)
            wind_speed=0;ui.dev:update_wind(4,0,0,99,50)
            assert(ui.dev.wind.valid and ui.dev.wind.calm and ui.dev.wind.speed==0)
        ''')

    def test_live_wind_invalid_fallback_and_same_value_recovery(self):
        l=self.wind_model()
        l.execute('''
            ui.dev:update_wind(1,0,0,99,50);local label=ui.dev.wind.label
            wind_speed=0/0;ui.dev:update_wind(2,0,0,nil,nil);assert(not ui.dev.wind.valid)
            wind_speed=10;ui.dev:update_wind(3,0,0,nil,nil)
            assert(ui.dev.wind.valid and ui.dev.wind.label==label and ui.dev.wind.dx)
            wind_speed=-1;ui.dev:update_wind(4,0,90,12,0)
            assert(ui.dev.wind.source=='instrument' and ui.dev.wind.basis=='M' and ui.dev.wind.speed==12)
            assert(math.abs(ui.dev.wind.dx-1)<1e-9 and ui.dev.wind.label:sub(-1)=='I')
            wind_speed=10;ui.dev:update_wind(5,nil,90,12,0);assert(ui.dev.wind.source=='instrument')
        ''')

    def test_live_wind_missing_handles_probe_only_once_per_second(self):
        l=self.wind_model()
        l.execute('''
            XPLMFindDataRef=function() finds=finds+1;return nil end
            for i=1,120 do ui.dev:update_wind(i/120,0,0,5,90) end
            assert(finds==2 and reads==0 and ui.dev.wind.source=='instrument')
            ui.dev:update_wind(1.1,0,0,5,90);assert(finds==4)
            ui.dev:update_wind(0,0,0,5,90);assert(finds==6)
        ''')

    def test_live_wind_draw_is_three_cached_quads_and_keeps_input_dot(self):
        l=self.wind_model()
        l.execute('''
            ui.dev:update_wind(1,0,0,5,90);ma_landing_meter_draw()
            local renderer=ui.dev.renderer;local w=renderer.windows.stick
            local vertices=ui.native_ui.instance.vertices
            for _,size in ipairs({120,180,360}) do
                ui.dev.config.stick_size=size;renderer:tick()
                local function draw_count()
                    calls.polygons=0;native_context=true;renderer:draw(w);native_context=false
                    return calls.polygons
                end
                ui.dev.wind.calm=true;local base=draw_count();ui.dev.wind.calm=false
                assert(draw_count()==base+3 and ui.native_ui.instance.vertices==vertices)
                assert(not w.error)
            end
        ''')

    def test_snapshot_updates_each_frame_without_duplicate_input_capture(self):
        l=baseline.RecorderTests().load_recorder()
        l.execute('''
            local count=0;local refs=ui.dev.refs;local old=refs.capture
            refs.capture=function(slot,shared) assert(shared);count=count+1;old(slot,shared) end
            local old_read=ui.dev.inputs.api.read
            local value=0;ui.dev.inputs.api.read=function() return value end
            for _,fps in ipairs({60,120}) do
                for i=1,fps do value=i/fps;ui.dev:update(fps+i/fps,'frame-test')
                    assert(ui.dev.engine.pitch_input_ratio==value)
                end
            end
            assert(count==180)
            ui.dev.inputs.api.read=old_read
        ''')

    def test_unchanged_overlay_geometry_does_not_call_sdk(self):
        l=baseline.RecorderTests().load_recorder()
        l.execute('''
            ma_landing_meter_draw();local renderer=ui.dev.renderer;renderer:tick()
            local n=0;local set=api.XPLMSetWindowGeometry
            api.XPLMSetWindowGeometry=function(...) n=n+1;return set(...) end
            for i=1,120 do renderer:tick() end;assert(n==0)
            ui.dev.config.edge_right=true;renderer:tick();assert(n==2)
            renderer:tick();assert(n==2)
        ''')

    def test_record_frame_copies_available_channels_and_fpm_fallback(self):
        l=baseline.RecorderTests().load_recorder()
        l.execute('''
            ui.dev.engine={elevator_1_valid=true,elevator_1_deg=0,elevator_2_valid=false,elevator_2_deg=99,
                aileron_1_valid=true,aileron_1_deg=-3,rudder_2_valid=true,rudder_2_deg=2,
                airbus_lever_1_valid=true,airbus_lever_1_ratio=.5,airbus_detent_1='CL',airbus_detent_2='NA',
                airbus_mode_valid=true,airbus_mode=0}
            ui.recording.tick=function(_,s) captured=s end
            ui.record_frame({t=1,agl=2000,physical_fpm=0,vvi=-50,ground=0})
            assert(captured and captured.elevator1==0 and captured.elevator2==nil)
            assert(captured.aileron1==-3 and captured.rudder2==2)
            assert(captured.detent1=='CL' and captured.detent2==nil and captured.detent_mode==0)
            assert(captured.trace_fpm==0 and captured.trace_fpm_source=='physical_velocity')
            ui.record_frame({t=2,agl=1900,vvi=-650,ground=0})
            assert(captured.trace_fpm==-650 and captured.trace_fpm_source=='vvi')
        ''')

    def test_profile_uses_existing_settings_and_switch_refreshes_snapshot(self):
        l=baseline.RecorderTests().load_recorder()
        l.execute('''
            ui.dev:update(1,'profile-aircraft')
            assert(ui.dev:select_source('pitch','cockpit'))
            assert(ui.dev.engine.pitch_input_source==ui.dev.inputs.axes.pitch.selected.path)
            ui.dev.inputs:remember_profile()
            local chunks={}; ui.dev:write_settings({write=function(_,s) chunks[#chunks+1]=s end})
            local content=table.concat(chunks); assert(content:find('live_profile_',1,true))
            ui.dev.inputs.profiles={}
            for line in content:gmatch('[^\\n]+') do
                local key,value=line:match('^([^=]+)=(.*)$'); ui.dev:read_setting(key,value)
            end
            ui.dev.inputs:set_identity('other'); ui.dev:update(2,'profile-aircraft')
            assert(ui.dev.inputs.axes.pitch.mode=='cockpit')
        ''')

    def test_popup_drag_clamps_global_bounds_and_saves_on_release(self):
        l=baseline.RecorderTests().load_recorder()
        l.execute("""
            getup(ma_landing_meter_draw,'show_until',10,true)
            ma_landing_meter_draw()
            local p=ui.native_ui.instance;assert(p.visible and p.frame.on_move)
            assert(p:mouse(p.x-1,p.y,1)==0)
            assert(p:mouse(p.x+10,p.y+10,1)==1)
            assert(p:mouse(p.x+10000,p.y+10000,2)==1)
            assert(ui.dev.config.popup_free_x==1 and ui.dev.config.popup_free_y==1)
            assert(ui.dev.pending~='save')
            assert(p:mouse(p.x-10000,p.y-10000,3)==1)
            assert(ui.dev.config.popup_free_x==0 and ui.dev.config.popup_free_y==0)
            assert(ui.dev.pending=='save' and p.drag==nil)
            local chunks={};ui.dev:write_settings({write=function(_,v)chunks[#chunks+1]=v end})
            assert(table.concat(chunks):find('live_popup_free_x=0',1,true))
            p:hide();assert(p:mouse(0,0,1)==0)
        """)

    def test_runway_reference_survives_recording_end_and_selected_direction(self):
        l=baseline.RecorderTests().load_recorder()
        l.execute("""
            local context=getup(ui.build_landing_log_payload,'landing_context')
            context.recording_id='finished';context.touch_latitude=25;context.touch_longitude=121.02
            ui.recording.file=nil;ui.recording.closed=true
            ui.dev.route=ui.rollout_module.new({lat1=25,lon1=121,lat2=25,lon2=121.03,width_m=45,end1='09',end2='27'},nil,'27','test')
            ui.dev.route.session_id='finished'
            local ok,report=ui.build_landing_log_payload();assert(ok,report)
            assert(report.content:find('LMM_RUNWAY\\t1\\t25.0000000000\\t121.0300000000\\t25.0000000000\\t121.0000000000\\t45.000',1,true))
            ui.dev.route.session_id='old';ok,report=ui.build_landing_log_payload()
            assert(ok and not report.content:find('LMM_RUNWAY',1,true))
        """)

    def test_legacy_popup_drag_and_click_passthrough(self):
        l=baseline.RecorderTests().load_recorder(cfg='popup_renderer=legacy\nrunway_detection_enabled=false\n')
        l.execute("""
            getup(ma_landing_meter_draw,'show_until',10,true);ma_landing_meter_draw()
            local b=ui.legacy_popup_bounds;assert(b)
            MOUSE_X=b.x-1;MOUSE_Y=b.y;MOUSE_STATUS='down';RESUME_MOUSE_CLICK=false
            ma_lmm119_popup_mouse();assert(not RESUME_MOUSE_CLICK)
            MOUSE_X=b.x+10;MOUSE_Y=b.y+10;ma_lmm119_popup_mouse();assert(RESUME_MOUSE_CLICK)
            MOUSE_X=10000;MOUSE_Y=10000;MOUSE_STATUS='drag';ma_lmm119_popup_mouse()
            assert(ui.dev.config.popup_free_x==1 and ui.dev.config.popup_free_y==1)
            MOUSE_STATUS='up';ma_lmm119_popup_mouse();assert(ui.dev.pending=='save')
            assert(ui.legacy_popup_drag==nil)
            ui.legacy_popup_bounds=nil;RESUME_MOUSE_CLICK=false;ma_lmm119_popup_mouse();assert(not RESUME_MOUSE_CLICK)
        """)

    def test_shared_live_capture_and_source_switch(self):
        l=baseline.RecorderTests().load_recorder()
        l.execute('''
            ui.dev:update(1,'aircraft')
            local refs=getup(ui.dev.refs.capture,'LMM_CONTROL_REFS')
            a={}; refs.capture(a)
            assert(a.pitch_input_valid and a.pitch_input_source~='')
            refs.resolve_input_sources({a},1)
            assert(a.pitch_input_ratio==ui.dev.inputs.axes.pitch.value)
        ''')

    def test_edge_bounds_actions_and_cleanup(self):
        l=baseline.RecorderTests().load_recorder()
        l.execute('''
            ma_landing_meter_draw()
            local renderer=ui.dev.renderer
            local w=renderer.windows.settings
            assert(w.w==32 and w.h==36 and w.x==-1920)
            assert(renderer:mouse(w,w.x-1,w.y,1)==0)
            assert(renderer:mouse(w,w.x+10,w.y+10,1)==1)
            assert(ui.dev.pending==nil)
            assert(renderer:mouse(w,w.x+10,w.y+10,3)==1)
            assert(ui.dev.pending=='settings')
            ui.dev.pending=nil
            ui.dev.config.edge_right=true; renderer:tick()
            assert(w.x==-32)
            ui.dev.config.edge=false; renderer:tick(); assert(not w.visible)
            ma_lmm118_shutdown(); assert(calls.destroyed_windows==calls.windows)
        ''')

    def test_debug_does_not_erase_manual_selection(self):
        l=baseline.RecorderTests().load_recorder()
        l.execute('''
            ui.dev:update(1,'aircraft'); assert(ui.dev.inputs:select('pitch','cockpit'))
            ma_landing_meter_draw()
            ui.dev:present(ui.native_ui.instance,true,false)
            assert(ui.dev.renderer.windows.stick.visible)
            local w=ui.dev.renderer.windows.stick
            native_context=true; ui.dev.renderer:draw(w); native_context=false
            ui.dev:present(ui.native_ui.instance,false,false)
            assert(not w.visible and ui.dev.inputs.axes.pitch.mode=='cockpit')
        ''')

if __name__=='__main__': unittest.main(verbosity=2)

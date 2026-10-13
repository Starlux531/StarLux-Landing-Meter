"""Real callbacks: edge dragging, folding, outer bank dashes and reverse state."""
import unittest
from test_overlay_ils_119 import overlay_runtime
from test_ui_119 import runtime
import test_ui_119 as baseline


class VisualStateTests(unittest.TestCase):
    def model(self):
        l=runtime();l.execute('''
            values={};finds=0;reads=0
            function XPLMFindDataRef(p)
                assert(not p:find('autopilot',1,true) and not p:find('servo',1,true),'removed automation probe: '..p)
                finds=finds+1;return p
            end
            function XPLMGetDataRefTypes(p)
                if p:find('deploy_ratio',1,true) then return 8 end
                if p:find('propmode',1,true) then return 16 end
                if p:find('/phi',1,true) then return 2 end
                return 1
            end
            function read(p) reads=reads+1;if values[p]=='missing' then return nil end;return values[p] or 0 end
            XPLMGetDatai=read;XPLMGetDataf=read
            XPLMGetDatavf=function(p) return values[p] or {[0]=0,[1]=0,[2]=0,[3]=0} end
            XPLMGetDatavi=XPLMGetDatavf
            Module=assert(loadfile(ROOT..'LMM_UI_119/core_visual_state.lua'))();a=Module.new()
            cfg={stick=true,throttle=true,n1=true}
            function step(t,id) a:update(t,id or 'B738',cfg,false,2) end
        ''');return l

    def test_replay_invalid_bank_and_hidden_widgets_clear_visual_state(self):
        self.model().execute('''
            local bank='sim/flightmodel/position/phi';local replay='sim/time/is_in_replay'
            values[bank]=30;values['sim/flightmodel/engine/ENGN_propmode']={[0]=3,[1]=0}
            step(0);assert(a.bank==30 and a.reverse[1] and finds==4)
            assert(a.ap==nil and a.at==nil and a.servo_valid==nil and Module.flash==nil)
            values[replay]=1;step(.1);assert(a.bank==nil and a.reverse[1]==nil)
            values[replay]=0;values[bank]=0/0;step(.2);assert(a.bank==nil and a.reverse[1])
            values[bank]=361;step(.3);assert(a.bank==nil)
            values[bank]='missing';step(.4);assert(a.bank==nil)
            values[bank]=-30;step(.5,'different');assert(a.bank==-30 and finds==8)
            values[bank]=0;step(.1);assert(a.bank==0 and finds==12)
            local n,f=reads,finds;cfg.stick=false;cfg.n1=false;step(.2)
            assert(reads==n and finds==f and a.bank==nil and a.reverse[1]==nil,'throttle needs no visual telemetry')
        ''')

    def test_reverse_bank_and_bounded_reads_without_automation(self):
        self.model().execute('''
            values['sim/flightmodel/position/phi']=30
            values['sim/flightmodel2/engines/thrust_reverser_deploy_ratio']={[0]=1,[1]=0}
            values['sim/flightmodel/engine/ENGN_propmode']={[0]=1,[1]=2}
            step(0);assert(a.bank==30 and finds==4 and reads==2)
            assert(a.reverse[1] and not a.reverse[2],'beta range is not reverse')
            local n=finds;for i=1,120 do step(i/120) end;assert(finds==n)
            values['sim/flightmodel2/engines/thrust_reverser_deploy_ratio']={0,0}
            values['sim/flightmodel/engine/ENGN_propmode']={1,3};step(1.01)
            assert(not a.reverse[1] and a.reverse[2],'one-based array reverse')
            a:update(1.02,'B738',cfg,false,1);assert(a.reverse[2]==nil,'engine count shrank')
            local n=reads;cfg.stick=false;cfg.throttle=false;cfg.n1=false;step(1.03);assert(reads==n)
        ''')

    def test_settings_roundtrip_and_default_migration(self):
        l=baseline.RecorderTests().load_recorder();l.execute('''
            assert(ui.dev.config.edge_settings_y==-1 and not ui.dev.config.stick_collapsed)
            ui.dev:read_setting('live_edge_settings_y','.8');ui.dev:read_setting('live_stick_collapsed','true')
            local out={};ui.dev:write_settings({write=function(_,s)out[#out+1]=s end})
            local raw=table.concat(out);assert(raw:find('live_edge_settings_y=0.8',1,true))
            assert(raw:find('live_stick_collapsed=true',1,true))
            ui.dev:read_setting('live_edge_records_y','-50');assert(ui.dev.config.edge_records_y==-1)
        ''')

    def test_legacy_drag_fold_status_and_balanced_styles(self):
        l=baseline.RecorderTests().load_recorder();l.execute('''
            local d=ui.dev;d.legacy_state.settings={y=300}
            local stack={};local lines={};active=false;down=false;clicked=false
            imgui={constant={Col={Text=1}},
                PushStyleColor=function(_,c)stack[#stack+1]=c end,
                PopStyleColor=function()assert(#stack>0);stack[#stack]=nil end,
                Button=function()return clicked end,IsItemHovered=function()return false end,
                IsItemActive=function()return active end,IsMouseDown=function()return down end,
                TextUnformatted=function(t)lines[#lines+1]={text=t,color=stack[#stack]} end}
            MOUSE_Y=100;active=true;down=true;d:legacy_build('settings')
            MOUSE_Y=200;d:legacy_build('settings');assert(d.pending==nil)
            clicked=true;active=false;down=false;d:legacy_build('settings');assert(d.pending=='save')
            assert(d.config.edge_settings_y>0 and #stack==0)
            clicked=true;d.pending=nil;d:legacy_build('settings');assert(d.pending=='settings')
            d.config.stick_collapsed=true;d:legacy_build('stick');assert(not d.config.stick_collapsed and d.pending=='save')
            clicked=false;d.engine_count=2;d.engine={n1_1_valid=true,n1_1_percent=71,n1_2_valid=true,n1_2_percent=50}
            d.visual_state.reverse={true,false};d:legacy_build('n1')
            local found=false;for _,v in ipairs(lines) do if v.text=='R 1: 71.0' then found=v.color==0xFF3838FF end end
            assert(found and #stack==0)
            d:legacy_build('throttle');d:legacy_build('stick');assert(#stack==0)
            for _,v in ipairs(lines) do assert(not v.text:find('AP',1,true) and not v.text:find('AT ',1,true)) end
        ''')

    def test_legacy_fold_does_not_change_saved_size_or_reposition_each_frame(self):
        l=baseline.RecorderTests().load_recorder();l.execute('''
            SUPPORTS_FLOATING_WINDOWS=true;SCREEN_WIDTH=800;SCREEN_HIGHT=600
            creates=0;positions=0;geometries=0
            float_wnd_create=function()creates=creates+1;return creates end
            float_wnd_set_imgui_builder=function()end
            float_wnd_set_position=function()positions=positions+1 end
            float_wnd_set_geometry=function()geometries=geometries+1 end
            float_wnd_destroy=function()end
            local d=ui.dev;d.config.edge=true;d.config.stick=true
            d:present(nil,false,true);local c,p,g=creates,positions,geometries
            d:present(nil,false,true);assert(creates==c and positions==p and geometries==g)
            d.config.stick_collapsed=true;d:present(nil,false,true)
            assert(d.legacy_state.stick.width==126 and d.legacy_state.stick.height==32)
            d.config.stick_collapsed=false;d:present(nil,false,true)
            assert(d.legacy_state.stick.width==245 and d.legacy_state.stick.height==120 and d.config.stick_size==180)
        ''')


class OverlayStatesTests(unittest.TestCase):
    def test_bank_draw_reuses_buffers(self):
        overlay_runtime().execute('''
            model.visual_state={bank=30,reverse={}}
            api.XPLMPolygon=function()end;api.XPLMFontDrawString=function()end
            for i=1,50 do renderer:draw(window) end
            collectgarbage('collect');collectgarbage('stop');local before=collectgarbage('count')
            for i=1,1000 do renderer:draw(window) end
            local growth=collectgarbage('count')-before;collectgarbage('restart')
            assert(growth<2,'Bank overlay draw allocated '..growth..' KiB')
        ''')

    def test_edge_drag_is_clamped_independent_and_click_on_release(self):
        overlay_runtime().execute('''
            model.config.edge=true;renderer:tick();local s=renderer.windows.settings;local other=renderer.windows.records
            local ox,oy=other.x,other.y;local sy=s.y
            renderer:mouse(s,s.x+12,s.y+12,1);assert(model.pending==nil)
            renderer:mouse(s,s.x+1000,s.y+212,2)
            assert(s.x==-1920 and s.y==sy+200 and other.y==oy and model.pending==nil)
            renderer:mouse(s,s.x+12,99999,3);assert(model.pending=='save' and model.config.edge_settings_y==1)
            model.pending=nil;renderer:mouse(s,s.x+12,s.y+12,1);renderer:mouse(s,s.x+12,s.y+12,3)
            assert(model.pending=='settings')
        ''')

    def test_opacity_applies_to_text_and_hover_reveals(self):
        overlay_runtime().execute('''
            model.config.edge=true;model.config.edge_alpha=10;renderer:tick();window=renderer.windows.settings
            draw_overlay();assert(math.floor(texts[1].color/16777216)==26)
            calls.specs[window_index(window.handle)].handleCursorFunc(nil,window.x+10,window.y+10,nil)
            draw_overlay();assert(math.floor(texts[1].color/16777216)==245)
            renderer.mouse_x,renderer.mouse_y=window.x-1,window.y-1
            draw_overlay();assert(math.floor(texts[1].color/16777216)==26,'leave hover immediately')
        ''')

    def test_all_widgets_fold_restore_exact_geometry(self):
        overlay_runtime().execute('''
            for _,id in ipairs({'stick','throttle','n1'}) do
              for _,size in ipairs({120,180,360}) do
                model.config[id]=true;model.config[id..'_size']=size;renderer:tick();local w=renderer.windows[id]
                local x,y,width,height=w.x,w.y,w.w,w.h
                renderer:mouse(w,w.x+w.w-17,w.y+w.h-14,1)
                renderer:mouse(w,w.x+w.w-17,w.y+w.h-14,3)
                assert(w.collapsed and w.h==28 and w.w<=126 and model.config[id..'_size']==size)
                renderer:mouse(w,w.x+20,w.y+10,1);renderer:mouse(w,w.x+20,w.y+10,3)
                assert(not w.collapsed and w.x==x and w.y==y and w.w==width and w.h==height)
              end
            end
        ''')

    def test_outer_bank_reverse_manual_input_and_no_geometry_change(self):
        overlay_runtime().execute('''
            model.visual_state={bank=30,reverse={true,false}}
            local gold=rgba(255,214,38,242);local red=rgba(255,56,56,255)
            for _,size in ipairs({120,180,240,360}) do
              for _,debug in ipairs({false,true}) do
               for _,bank in ipairs({0,30,-30,90,-90,180}) do
                model.visual_state.bank=bank
                model.debug=debug;model.config.stick_size=size;renderer:tick();window=renderer.windows.stick;draw_overlay()
                local fixed=select_color(rgba(86,180,235,89));local span=fixed[2][3]-fixed[2][1]
                local cx,cy=center(fixed[2]);local dx,dy=math.cos(bank*math.pi/180),-math.sin(bank*math.pi/180)
                local segments=select_color(gold);assert(#segments==6)
                for side=-1,1,2 do for i=0,2 do
                  local p=segments[(side==-1 and 0 or 3)+i+1]
                  local x1,y1=(p[1]+p[3])/2,(p[2]+p[4])/2
                  local x2,y2=(p[5]+p[7])/2,(p[6]+p[8])/2
                  local a,z=side*span*(.25+i*.1),side*span*(.3+i*.1)
                  assert(math.abs(x1-cx-dx*a)<.001 and math.abs(y1-cy-dy*a)<.001)
                  assert(math.abs(x2-cx-dx*z)<.001 and math.abs(y2-cy-dy*z)<.001)
                end end
                assert(#select_color(rgba(38,255,102,255))==1 and #select_color(red)==0)
                for _,t in ipairs(texts) do assert(t.text~='AP' and not t.text:find('AT ',1,true)) end
                for _,p in ipairs(polygons) do for i=1,8,2 do
                  assert(p[i]>=window.x-.001 and p[i]<=window.x+window.w+.001)
                  assert(p[i+1]>=window.y-.001 and p[i+1]<=window.y+window.h+.001)
                end end
               end
              end
            end
            model.config.n1=true;model.engine_count=2;model.engine={n1_1_valid=true,n1_1_percent=70,n1_2_valid=true,n1_2_percent=60}
            renderer:tick();window=renderer.windows.n1;draw_overlay()
            local reverse,value=false,false
            for _,t in ipairs(texts) do if t.text=='R1' then reverse=t.color==red elseif t.text=='70.0' then value=t.color==red end end
            assert(reverse and value)
            model.config.throttle=true
            renderer:tick();window=renderer.windows.throttle;draw_overlay();assert(#select_color(red)==0)
            for _,t in ipairs(texts) do assert(not t.text:find('AT ',1,true)) end
        ''')


if __name__=='__main__':unittest.main(verbosity=2)

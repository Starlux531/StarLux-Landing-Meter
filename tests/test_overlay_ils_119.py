"""Exercise real overlay Lua draw calls against the existing SDK double."""
import unittest

from test_ui_119 import runtime


def overlay_runtime():
    lua = runtime()
    lua.execute('''
        load_native(); assert(host.ready,host.error)
        model={en=true,debug=false,engine_count=0,engine={},
            config={red=86,green=180,blue=235,alpha=65,edge_alpha=24,
                stick=true,stick_size=180,stick_wind=true,size=180},
            wind={valid=true,calm=false,speed=10,dx=1,dy=0,label='270T 10.0kt'},
            inputs={axes={pitch={valid=true,value=0},roll={valid=true,value=0},yaw={valid=true,value=0}}}}
        renderer=assert(loadfile(ROOT..'LMM_UI_119/overlays.lua'))().new(host,ffi,model)
        renderer:tick(); window=renderer.windows.stick
        polygons={}; texts={}
        function api.XPLMPolygon(c,v,n)
            assert(native_context and n==4)
            local p={color=c}
            for i=0,3 do p[#p+1]=tonumber(v[i].x);p[#p+1]=tonumber(v[i].y) end
            polygons[#polygons+1]=p
        end
        function api.XPLMFontDrawString(f,c,s,x,y,t,j)
            assert(native_context)
            texts[#texts+1]={text=t,x=x,y=y,size=s,color=c}
        end
        function draw_overlay()
            polygons={};texts={};native_context=true
            calls.specs[window_index(window.handle)].drawWindowFunc(nil,nil)
            native_context=false; assert(not window.error,window.error)
        end
        function rgba(r,g,b,a) return r+g*256+b*65536+a*16777216 end
        function select_color(c)
            local result={}
            for _,p in ipairs(polygons) do if p.color==c then result[#result+1]=p end end
            return result
        end
        function markers() return select_color(rgba(255,102,242,242)) end
        function scales() return select_color(rgba(209,237,255,166)) end
        function center(p) return (p[1]+p[3]+p[5]+p[7])/4,(p[2]+p[4]+p[6]+p[8])/4 end
        function has_label()
            for _,t in ipairs(texts) do if t.text=='ILS REF' then return true end end
            return false
        end
    ''')
    return lua


class OverlayILSTests(unittest.TestCase):
    def test_ils_never_drawn_or_reserved_in_live_overlay(self):
        lua = overlay_runtime()
        lua.execute('''
            for _,debug in ipairs({false,true}) do
              model.debug=debug
              for _,size in ipairs({120,180,240,360}) do
                model.config.stick_size=size;renderer:tick();model.ils=nil;draw_overlay()
                local cross=select_color(rgba(86,180,235,89));local width=cross[2][3]-cross[2][1]
                model.ils={loc_valid=true,gs_valid=true,loc_dots=1,gs_dots=-1};draw_overlay()
                assert(#markers()==0 and #scales()==0 and not has_label())
                local other=select_color(rgba(86,180,235,89));assert(other[2][3]-other[2][1]==width)
              end
            end
        ''')

    def test_fixed_arrow_length_across_angles_speeds_and_widget_sizes(self):
        lua = overlay_runtime()
        lua.execute('''
            for _,size in ipairs({120,180,240,360}) do
              model.config.stick_size=size;renderer:tick()
              for angle=0,360,15 do
                model.wind.dx=math.cos(angle*math.pi/180);model.wind.dy=math.sin(angle*math.pi/180)
                for _,speed in ipairs({1,10,20,30}) do
                  model.wind.speed=speed;draw_overlay()
                  local ink=speed<=10 and rgba(130,201,154,97) or speed<=20 and rgba(255,231,184,97) or rgba(239,123,130,97)
                  local p=select_color(ink)[1]
                  local dx=(p[5]+p[7]-p[1]-p[3])/2;local dy=(p[6]+p[8]-p[2]-p[4])/2
                  assert(math.abs(math.sqrt(dx*dx+dy*dy)-48)<.001)
                end
              end
            end
        ''')

    def test_wind_thresholds_alpha_and_stick_foreground(self):
        lua = overlay_runtime()
        lua.execute('''
            for _,case in ipairs({{.05,130,201,154},{10,130,201,154},
                {10.001,255,231,184},{20,255,231,184},{20.001,239,123,130},{80,239,123,130}}) do
                model.wind.speed=case[1];draw_overlay()
                local ink=rgba(case[2],case[3],case[4],97)
                assert(#select_color(ink)==3,'wind threshold or dim alpha')
                local last_arrow,stick
                for i,p in ipairs(polygons) do
                    if p.color==ink then last_arrow=i end
                    if p.color==rgba(38,255,102,255) and p[3]-p[1]==6 then stick=i end
                end
                assert(stick and stick>last_arrow,'stick must be above wind')
            end
            model.wind.calm=true;draw_overlay();assert(#select_color(rgba(239,123,130,97))==0)
            model.wind.calm=false;model.wind.valid=false;draw_overlay()
            assert(#select_color(rgba(239,123,130,97))==0)
        ''')

    def test_warm_draw_reuses_buffers_without_heap_growth(self):
        lua = overlay_runtime()
        lua.execute('''
            model.ils={loc_valid=true,gs_valid=true,loc_dots=1,gs_dots=-1}
            api.XPLMPolygon=function() end;api.XPLMFontDrawString=function() end
            for i=1,50 do renderer:draw(window) end
            local vertices=host.vertices
            collectgarbage('collect');collectgarbage('stop')
            local before=collectgarbage('count')
            for i=1,1000 do renderer:draw(window) end
            local growth=collectgarbage('count')-before
            collectgarbage('restart')
            assert(host.vertices==vertices)
            assert(growth<2,'warm draw allocated '..growth..' KiB')
        ''')


if __name__ == '__main__':
    unittest.main()

"""Real Lua callbacks: resize, anchoring, persisted settings and layout safety."""
import unittest
from test_overlay_ils_119 import overlay_runtime
import test_ui_119 as baseline


class ResizeTests(unittest.TestCase):
    def test_all_widget_edges_corners_anchor_and_release(self):
        l = overlay_runtime()
        l.execute('''
            for _,id in ipairs({'stick','throttle','n1'}) do
              model.config[id]=true
              for hx=-1,1 do for hy=-1,1 do if hx~=0 or hy~=0 then
                model.config[id..'_size']=180
                model.config[id..'_x']=.5;model.config[id..'_y']=.5
                model.pending=nil;renderer:tick();local w=renderer.windows[id]
                local ox,oy,ow,oh=w.x,w.y,w.w,w.h
                local x=w.x+(hx+1)*w.w/2;local y=w.y+(hy+1)*w.h/2
                local cb=calls.specs[window_index(w.handle)].handleMouseClickFunc
                assert(cb(nil,x,y,1,nil)==1)
                assert(w.drag and w.drag.resize)
                assert(cb(nil,x+hx*60,y+hy*60,2,nil)==1)
                assert(model.config[id..'_size']==240)
                assert(model.pending==nil,'must not save on each drag frame')
                assert(math.abs((w.x+(hx<0 and w.w or hx==0 and w.w/2 or 0))-
                    (ox+(hx<0 and ow or hx==0 and ow/2 or 0)))<1.1)
                assert(math.abs((w.y+(hy<0 and w.h or hy==0 and w.h/2 or 0))-
                    (oy+(hy<0 and oh or hy==0 and oh/2 or 0)))<1.1)
                -- Mouse-up itself may carry the final delta outside the window.
                assert(cb(nil,x+hx*80,y+hy*80,3,nil)==1)
                assert(model.config[id..'_size']==260 and not w.drag and model.pending=='save')
              end end end
            end
        ''')

    def test_widget_limits_passthrough_debug_sources_and_cancel(self):
        l = overlay_runtime()
        l.execute('''
            local w=window
            assert(renderer:mouse(w,w.x+w.w/2,w.y+w.h/2,1)==0)
            assert(renderer:mouse(w,w.x-1,w.y+40,1)==0)
            assert(renderer:mouse(w,w.x+w.w,w.y+40,1)==1)
            renderer:mouse(w,100000,100000,2)
            assert(model.config.stick_size==360 and w.x>=-1920 and w.x+w.w<=0)
            renderer:mouse(w,-100000,-100000,3)
            assert(model.config.stick_size==120 and not w.drag)
            model.debug=true;renderer:tick()
            model.pending=nil
            renderer:mouse(w,w.x+30,w.y+48,1);assert(model.pending=='cycle_pitch')
            renderer:mouse(w,w.x+w.w,w.y+w.h/2,1);assert(w.drag.resize)
            model.debug=false;model.config.stick=false;renderer:tick();assert(not w.drag)
        ''')

    def test_pad_stays_square_without_distorting_wind_or_covering_readouts(self):
        l = overlay_runtime()
        l.execute('''
            for _,size in ipairs({120,180,240,360}) do
              for _,debug in ipairs({false,true}) do
                model.debug=debug;model.config.stick_size=size;renderer:tick()
                model.wind.dx=.6;model.wind.dy=.8
                model.ils={loc_valid=true,gs_valid=true,loc_dots=2,gs_dots=-2}
                for _,value in ipairs({-1,0,1}) do
                  model.inputs.axes.roll.value=value;model.inputs.axes.pitch.value=value
                  draw_overlay()
                  local cross=select_color(rgba(86,180,235,89))
                  local width=cross[2][3]-cross[2][1]
                  local height=cross[1][8]-cross[1][2]
                  assert(math.abs(width-height)<.001,'input pad must stay square')
                  local stick=select_color(rgba(38,255,102,255))[1]
                  local sx,sy=center(stick)
                  local cx,cy=center(cross[1])
                  assert(math.abs(sx-cx-value*width/2)<.001)
                  assert(math.abs(sy-cy+value*height/2)<.001)
                  local arrow=select_color(rgba(130,201,154,97))[1]
                  local ax=(arrow[5]+arrow[7]-arrow[1]-arrow[3])/2
                  local ay=(arrow[6]+arrow[8]-arrow[2]-arrow[4])/2
                  assert(math.abs(ay/ax-4/3)<.001,'wind must retain its physical angle')
                  for _,p in ipairs(polygons) do for i=1,8,2 do
                    assert(p[i]>=window.x-.001 and p[i]<=window.x+window.w+.001)
                    assert(p[i+1]>=window.y-.001 and p[i+1]<=window.y+window.h+.001)
                  end end
                end
              end
            end
            model.debug=false;model.ils=nil;model.config.stick_size=180;renderer:tick();draw_overlay()
            local cross=select_color(rgba(86,180,235,89))
            assert(cross[2][3]-cross[2][1]==122)
            assert(cross[1][8]-cross[1][2]==122)
        ''')

    def test_popup_all_edges_resize_text_anchor_persist_and_buttons(self):
        l = baseline.RecorderTests().load_recorder()
        l.execute('''
            getup(ma_landing_meter_draw,'show_until',100,true)
            for hx=-1,1 do for hy=-1,1 do if hx~=0 or hy~=0 then
              ui.popup_style.font_px=18
              ui.dev.config.popup_free_x=.5;ui.dev.config.popup_free_y=.5
              ui.dev.pending=nil;ma_landing_meter_draw()
              local p=ui.native_ui.instance
              local ox,oy,ow,oh=p.x,p.y,p.layout.width,p.layout.height
              local x=p.x+(hx+1)*ow/2;local y=p.y+(hy+1)*oh/2
              assert(p:mouse(x,y,1)==1 and p.drag.resize)
              p:mouse(x+hx*ow/3,y+hy*oh/3,2)
              assert(ui.popup_style.font_px==24 and p.layout.size==24)
              assert(ui.dev.pending==nil)
              local pw,ph=p.layout.width,p.layout.height
              assert(math.abs(p.x+(hx<0 and pw or hx==0 and pw/2 or 0)-
                (ox+(hx<0 and ow or hx==0 and ow/2 or 0)))<1.1)
              assert(math.abs(p.y+(hy<0 and ph or hy==0 and ph/2 or 0)-
                (oy+(hy<0 and oh or hy==0 and oh/2 or 0)))<1.1)
              p:mouse(x+hx*ow/2,y+hy*oh/2,3)
              assert(ui.popup_style.font_px==27 and ui.dev.pending=='save' and not p.drag)
              for _,row in ipairs(p.layout.rows) do assert(row.text~='...') end
              ma_landing_meter_update()
              assert(table.concat(settings_writes):find('popup_font_px=27',1,true))
              -- Existing settings slider remains the same source of truth.
              ui.popup_style.font_px=14;ma_landing_meter_draw();assert(p.layout.size==14)
            end end end
            local p=ui.native_ui.instance
            p:mouse(p.x+p.layout.width,p.y+p.layout.height,1)
            p:mouse(100000,100000,2);assert(ui.popup_style.font_px==32)
            p:mouse(-100000,-100000,3);assert(ui.popup_style.font_px==10)
            p:mouse(p.x,p.y,1);p:hide();assert(not p.drag)
        ''')


if __name__ == '__main__':
    unittest.main()

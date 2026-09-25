-- Small independent SDK 440 windows. No invisible screen-sized input surface.
local M={}; M.__index=M
local axes={"pitch","roll","yaw"}
local function byte(x) return math.floor(math.max(0,math.min(1,x))*255+.5) end
local function color(r,g,b,a)
    return byte(r)+byte(g)*256+byte(b)*65536+byte(a)*16777216
end
local wind_green,wind_gold,wind_red=color(130/255,201/255,154/255,.38),color(1,231/255,184/255,.38),color(239/255,123/255,130/255,.38)
local text_ink=color(.82,.93,1,.96)
local green,yellow,red=color(.15,1,.4,1),color(1,.84,.15,.95),color(1,.22,.22,1)
local function text(h,w,x,y,s,px,ink)
    h.api.XPLMFontDrawString(h.fonts.normal,ink or text_ink,px or 12,w.x+x,w.y+y,s,0)
end
local function title(id,en) return id=="stick" and (en and "INPUT" or "操纵输入") or id=="throttle" and (en and "THROTTLE" or "油门") or "N1" end
function M.new(host,ffi,model)
    -- Cache FFI struct views once: indexing the array in interpreted draw code
    -- otherwise creates temporary cdata objects for every vertex assignment.
    local v=host.vertices
    local ok,mouse=pcall(function() return host.api.XPLMGetMouseLocationGlobal end)
    return setmetatable({host=host,ffi=ffi,model=model,windows={},v0=v[0],v1=v[1],v2=v[2],v3=v[3],
        mouse_location=ok and mouse or nil,mouse_position=ffi.new('int[2]')},M)
end
function M:destroy()
    for _,w in pairs(self.windows) do
        if w.handle then self.host.api.XPLMDestroyWindow(w.handle) end
        for _,c in ipairs(w.callbacks) do c:free() end
    end
    self.windows={}
end
function M:create(id)
    local ffi=self.ffi; local w={id=id,callbacks={},x=0,y=0,w=1,h=1}; self.windows[id]=w
    local function callback(kind,fn) local c=ffi.cast(kind,fn); w.callbacks[#w.callbacks+1]=c; return c end
    local spec=ffi.new("LMM118_WindowSpec"); spec.structSize=ffi.sizeof(spec)
    spec.left,spec.top,spec.right,spec.bottom=0,100,100,0
    spec.visible,spec.decorateAsFloatingWindow,spec.layer,spec.contentType=0,0,1,1
    spec.drawWindowFunc=callback("LMM118_Draw",function()
        if w.visible then local ok,e=pcall(self.draw,self,w); if not ok then w.error=tostring(e) end end
    end)
    spec.handleMouseClickFunc=callback("LMM118_Mouse",function(_,x,y,status)
        local ok,result=pcall(self.mouse,self,w,x,y,status)
        if not ok then w.error=tostring(result); return 0 end
        return result
    end)
    spec.handleRightClickFunc=callback("LMM118_Mouse",function() return 0 end)
    spec.handleKeyFunc=callback("LMM118_Key",function() end)
    spec.handleCursorFunc=callback("LMM118_Cursor",function(_,x,y)
        if x>=w.x and x<=w.x+w.w and y>=w.y and y<=w.y+w.h then w.hover_at=os.clock() end
        return 0
    end)
    spec.handleMouseWheelFunc=callback("LMM118_Wheel",function() return 0 end)
    w.handle=self.host.api.XPLMCreateWindowEx(spec); assert(w.handle~=nil,"Overlay window creation failed")
    return w
end
function M:mouse(w,x,y,status)
    local inside=x>=w.x and x<=w.x+w.w and y>=w.y and y<=w.y+w.h
    if not inside and not w.drag and not w.fold_pressed then return 0 end
    if inside then w.hover_at=os.clock() end
    local shortcut=w.id=="settings" or w.id=="records"
    -- Edge shortcuts activate on release, so dragging never opens a dialog.
    if shortcut or w.collapsed then
        if status==1 then w.drag={x=x,y=y,bottom=w.y,moved=false,button=true}
        elseif (status==2 or status==3) and w.drag then
            local d=w.drag
            if math.abs(y-d.y)>4 or math.abs(x-d.x)>4 then d.moved=true end
            if shortcut and d.moved then
                local b=self.bounds
                self.model.config['edge_'..w.id..'_y']=math.max(0,math.min(1,(d.bottom+y-d.y-b[4])/math.max(1,b[2]-b[4]-w.h)))
                self:tick()
            end
            if status==3 then
                if d.moved then if shortcut then self.model.pending="save" end
                elseif inside then
                    if shortcut then self.model.pending=w.id
                    else self.model.config[w.id..'_collapsed']=false;self.model.pending="save";self:tick() end
                end
                w.drag=nil
            end
        end
        return 1
    end
    local fold=x>=w.x+w.w-26 and x<=w.x+w.w-9 and y>=w.y+w.h-23 and y<=w.y+w.h-6
    if status==1 and fold then w.fold_pressed=true;return 1 end
    if w.fold_pressed then
        if status==3 then
            w.fold_pressed=nil
            if fold then self.model.config[w.id..'_collapsed']=true;self.model.pending="save";self:tick() end
        end
        return 1
    end
    local hx,hy=self.host.resize_edges(x,y,w.x,w.y,w.w,w.h)
    local resize=not shortcut and hx and (hx~=0 or hy~=0)
    if status==1 and resize then
        w.drag={resize=true,x=x,y=y,left=w.x,bottom=w.y,w=w.w,h=w.h,hx=hx,hy=hy,
            size=self.model.config[w.id.."_size"] or self.model.config.size}
        return 1
    elseif (status==2 or status==3) and w.drag and w.drag.resize then
        local cfg=self.model.config;local bounds=self.bounds;local d=w.drag
        local extra=w.id=="stick" and self.model.debug and 50 or 0
        local limit=math.min(360,bounds[3]-bounds[1],bounds[2]-bounds[4]-extra)
        cfg[w.id.."_size"]=math.floor(math.max(math.min(120,limit),math.min(limit,d.size*self.host.resize_factor(d,x,y)))+.5)
        local size=cfg[w.id.."_size"]
        local width=math.min(extra>0 and math.max(240,size) or size,bounds[3]-bounds[1])
        local height=math.min(size+extra,bounds[2]-bounds[4])
        local px,py=self.host.resize_position(d,width,height,unpack(bounds))
        cfg[w.id.."_x"]=(px-bounds[1])/math.max(1,bounds[3]-bounds[1]-width)
        cfg[w.id.."_y"]=(py-bounds[4])/math.max(1,bounds[2]-bounds[4]-height)
        self:tick()
        if status==3 then w.drag=nil; self.model.pending="save" end
        return 1
    end
    if w.id~="settings" and w.id~="records" and not w.drag
        and not (self.model.debug and w.id=="stick" and y<w.y+64)
        and not (self.model.config.edit and y>w.y+w.h-26) then return 0 end
    if status==1 then
        if w.id=="settings" or w.id=="records" then self.model.pending=w.id
        elseif self.model.debug and w.id=="stick" and y<w.y+64 then
            local axis=({"pitch","roll","yaw"})[math.min(3,math.floor((w.y+64-y)/21)+1)]
            self.model.pending="cycle_"..axis
        elseif self.model.config.edit and y>w.y+w.h-26 then w.drag={x=x,y=y,left=w.x,bottom=w.y} end
    elseif (status==2 or status==3) and w.drag then
        local cfg=self.model.config; local bounds=self.bounds
        cfg[w.id.."_x"]=math.max(0,math.min(1,(w.drag.left+x-w.drag.x-bounds[1])/math.max(1,bounds[3]-bounds[1]-w.w)))
        cfg[w.id.."_y"]=math.max(0,math.min(1,(w.drag.bottom+y-w.drag.y-bounds[4])/math.max(1,bounds[2]-bounds[4]-w.h)))
        if status==3 then w.drag=nil; self.model.pending="save" end
    end
    return 1
end
function M:rect(x,y,w,h,c)
    local a,b,d,e=self.v0,self.v1,self.v2,self.v3
    a.x,a.y=x,y;b.x,b.y=x+w,y;d.x,d.y=x+w,y+h;e.x,e.y=x,y+h
    self.host.api.XPLMPolygon(c,self.host.vertices,4)
end
function M:wind_line(x1,y1,x2,y2,width,c)
    local dx,dy=x2-x1,y2-y1;local length=math.sqrt(dx*dx+dy*dy);if length<.001 then return end
    local nx,ny=-dy/length*width/2,dx/length*width/2
    local a,b,d,e=self.v0,self.v1,self.v2,self.v3
    a.x,a.y=x1+nx,y1+ny;b.x,b.y=x1-nx,y1-ny
    d.x,d.y=x2-nx,y2-ny;e.x,e.y=x2+nx,y2+ny
    self.host.api.XPLMPolygon(c,self.host.vertices,4)
end
function M:draw(w)
    local h=self.host; local m=self.model; local cfg=m.config
    local r,g,b=(cfg[w.id.."_red"] or cfg.red)/255,(cfg[w.id.."_green"] or cfg.green)/255,(cfg[w.id.."_blue"] or cfg.blue)/255
    local alpha=(w.id=="settings" or w.id=="records") and cfg.edge_alpha/100 or (cfg[w.id.."_alpha"] or cfg.alpha)/100
    local hover=w.hover_at and os.clock()-w.hover_at<.2
    if self.mouse_x then hover=self.mouse_x>=w.x and self.mouse_x<=w.x+w.w and self.mouse_y>=w.y and self.mouse_y<=w.y+w.h end
    if hover then alpha=math.max(alpha,.7) end
    local visual=m.visual_state
    if w.collapsed then alpha=hover and .7 or math.min(alpha,.28) end
    self:rect(w.x,w.y,w.w,w.h,color(.02,.045,.08,alpha))
    self:rect(w.x,w.y+w.h-2,w.w,2,color(r,g,b,(w.id=='settings' or w.id=='records') and alpha or .8))
    if w.id=="settings" or w.id=="records" then
        local ink=color(.82,.93,1,hover and .96 or alpha)
        if hover then text(h,w,3,12,w.id=="settings" and (m.en and "SET" or "设置") or (m.en and "LOG" or "记录"),12,ink)
        else text(h,w,7,11,w.id=="settings" and (m.en and "S" or "设") or (m.en and "R" or "录"),14,ink) end
        return
    end
    if w.collapsed then text(h,w,8,9,title(w.id,m.en).." +",11,color(.82,.93,1,hover and .96 or .5));return end
    self:rect(w.x+w.w-10,w.y+3,7,1,color(r,g,b,.45))
    self:rect(w.x+w.w-4,w.y+3,1,7,color(r,g,b,.45))
    text(h,w,8,w.h-17,w.id=="stick" and (m.en and "INPUT" or "操纵输入") or w.id=="throttle" and (m.en and "THROTTLE %" or "油门 %") or "N1 %")
    self:rect(w.x+w.w-23,w.y+w.h-16,11,2,color(r,g,b,hover and .95 or .55))
    if w.id=="stick" then
        -- ILS belongs only in post-flight analysis, never in the live overlay.
        local bottom=m.debug and 68 or 20
        local available_w=w.w-16
        local available_h=math.max(12,w.h-bottom-(cfg.stick_wind and 38 or 25))
        -- One scale for both input axes, centred in the space left by readouts.
        -- Resizing must never stretch the normalized stick coordinates.
        local span=math.min(available_w,available_h)
        local cx=8+available_w/2; local cy=bottom+available_h/2
        local y0=cy-span/2
        self:rect(w.x+cx-.5,w.y+y0,1,span,color(r,g,b,.35))
        self:rect(w.x+cx-span/2,w.y+cy-.5,span,1,color(r,g,b,.35))
        if visual and visual.bank then
            local angle=visual.bank*math.pi/180
            local dx,dy=math.cos(angle),-math.sin(angle)
            -- Outer quarters only: the middle half stays clear of the input marker.
            for side=-1,1,2 do
                for i=0,2 do
                    local a=side*span*(.25+i*.1);local z=side*span*(.3+i*.1)
                    self:wind_line(w.x+cx+dx*a,w.y+cy+dy*a,w.x+cx+dx*z,w.y+cy+dy*z,1.5,yellow)
                end
            end
        end
        if cfg.stick_wind then
            local wind=m.wind
            local label=wind.valid and wind.label or "N/A"
            if w.wind_label~=label or w.wind_en~=m.en then
                w.wind_label,w.wind_en=label,m.en
                w.wind_text=(m.en and "FROM " or "风来自 ")..label
            end
            text(h,w,8,w.h-31,w.wind_text,w.w<160 and 9 or 10)
            if wind.valid and not wind.calm then
                -- Keep the wind's physical angle and fit the square input pad.
                local dx,dy=wind.dx,wind.dy
                local length=48 -- Fixed pixels: direction/speed never stretch the arrow.
                local x1,y1=w.x+cx-dx*length*.5,w.y+cy-dy*length*.5
                local x2,y2=x1+dx*length,y1+dy*length
                local head=8
                local ink=wind.speed<=10 and wind_green or wind.speed<=20 and wind_gold or wind_red
                self:wind_line(x1,y1,x2,y2,2,ink)
                self:wind_line(x2,y2,x2-dx*head-dy*head*.6,y2-dy*head+dx*head*.6,2,ink)
                self:wind_line(x2,y2,x2-dx*head+dy*head*.6,y2-dy*head-dx*head*.6,2,ink)
            end
        end
        local p,roll=m.inputs.axes.pitch,m.inputs.axes.roll
        if p.valid and roll.valid then
            local px,py=w.x+cx+roll.value*span/2,w.y+cy-p.value*span/2
            self:rect(px-4,py-4,8,8,color(.02,.045,.08,1))
            self:rect(px-3,py-3,6,6,green)
        else text(h,w,12,cy,m.en and "Input unavailable" or "输入不可用") end
        if not m.debug then
            local yaw=m.inputs.axes.yaw; local length=w.w-60
            text(h,w,8,7,"YAW",10); self:rect(w.x+46,w.y+12,length,1,color(r,g,b,.35))
            if yaw.valid then self:rect(w.x+46+(yaw.value+1)*length/2-2,w.y+9,4,6,color(r,g,b,1)) end
        end
        if m.debug then
            for i,axis in ipairs(axes) do
                local a=m.inputs.axes[axis]; local c=a.selected
                text(h,w,8,64-i*21+5,string.format("%s %s %s",axis,c and c.id or "--",a.valid and string.format("%.2f",a.value) or a.status),11)
            end
        end
    else
        local count=math.min(4,m.engine_count or 0)
        if count==0 then text(h,w,10,20,m.en and "Unavailable" or "不可用") end
        for i=1,math.min(4,count) do
            local name=w.id=="n1" and "n1_"..i.."_percent" or "throttle_"..i.."_ratio"
            local valid=m.engine[name:gsub("_percent$","_valid"):gsub("_ratio$","_valid")]
            local value=m.engine[name] or 0; local ratio=w.id=="n1" and value/110 or math.max(0,value)
            local x=12+(i-1)*(w.w-24)/math.max(1,count); local width=(w.w-24)/math.max(1,count)-8
            self:rect(w.x+x,w.y+44,width,w.h-77,color(r,g,b,.12))
            if valid then self:rect(w.x+x,w.y+44,width,(w.h-77)*math.max(0,math.min(1,ratio)),color(r,g,b,.7)) end
            local reverse=w.id=='n1' and visual and visual.reverse[i]
            text(h,w,x,29,reverse and ("R"..i) or (width<30 and "E" or "ENG ")..i,10,reverse and red or nil)
            text(h,w,x,14,valid and string.format(w.id=="n1" and "%.1f" or "%.0f",w.id=="n1" and value or value*100) or "--",11,reverse and red or nil)
        end
    end
end
function M:tick()
    if self.mouse_location then
        self.mouse_location(self.mouse_position,self.mouse_position+1)
        self.mouse_x,self.mouse_y=tonumber(self.mouse_position[0]),tonumber(self.mouse_position[1])
    end
    local b=self.host.bounds; self.host.api.XPLMGetScreenBoundsGlobal(b,b+1,b+2,b+3)
    self.bounds={tonumber(b[0]),tonumber(b[1]),tonumber(b[2]),tonumber(b[3])}
    local left,top,right,bottom=unpack(self.bounds); local cfg=self.model.config
    for _,id in ipairs({"settings","records","stick","throttle","n1"}) do
        local edge=id=="settings" or id=="records"
        local visible=edge and cfg.edge or not edge and (cfg[id] or id=="stick" and self.model.debug)
        local w=self.windows[id]
        if visible and not w then w=self:create(id) end
        if w then
            if not visible then w.drag=nil;w.fold_pressed=nil end
            local size=cfg[id.."_size"] or cfg.size
            local width=edge and 32 or (id=="stick" and self.model.debug and math.max(240,size) or size)
            local height=edge and 36 or size+(id=="stick" and self.model.debug and 50 or 0)
            width=math.min(width,right-left); height=math.min(height,top-bottom)
            w.x=edge and (cfg.edge_right and right-width or left) or left+math.floor((right-left-width)*(cfg[id.."_x"] or .1))
            local edge_y=cfg['edge_'..id..'_y'] or -1
            w.y=edge and (edge_y>=0 and bottom+math.floor((top-bottom-height)*edge_y) or bottom+math.floor((top-bottom)*.55)+(id=="settings" and 42 or 0)) or bottom+math.floor((top-bottom-height)*(cfg[id.."_y"] or .2))
            w.y=math.max(bottom,math.min(top-height,w.y))
            w.collapsed=not edge and cfg[id..'_collapsed'] or false
            if w.collapsed then w.y=w.y+height-28;width=math.min(width,126);height=28 end
            w.w,w.h=width,height
            -- Resizing unchanged SDK windows every draw can cause avoidable compositor work.
            if w.last_x~=w.x or w.last_y~=w.y or w.last_w~=width or w.last_h~=height then
                self.host.api.XPLMSetWindowGeometry(w.handle,w.x,w.y+height,w.x+width,w.y)
                w.last_x,w.last_y,w.last_w,w.last_h=w.x,w.y,width,height
            end
            if w.visible~=visible then self.host.api.XPLMSetWindowIsVisible(w.handle,visible and 1 or 0); w.visible=visible end
        end
    end
end
if jit then for _,f in pairs(M) do if type(f)=="function" then jit.off(f,true) end end end
return M

-- Small immediate-mode UI adapter for the existing LMM builders. Rendering
-- uses the SDK 440 Unicode fonts, NOT FlyWithLua's fixed ImGui font atlas.
-- Native callbacks only draw prepared commands / queue input. Builder actions
-- run on the ordinary Lua update path, never inside a native drawing callback.
local M = {}
local wrap = dofile((... or "") .. "layout.lua")
local function rgb(r,g,b) return 0xFF000000+b*65536+g*256+r end
local colors = {
    bg=rgb(16,25,35), card=rgb(24,37,49), surface=rgb(35,51,66), hover=rgb(49,70,86),
    line=rgb(70,94,111), text=rgb(237,243,246), muted=rgb(171,190,202),
    accent=rgb(84,213,186), selected=rgb(24,69,62), danger=rgb(244,156,163),
    danger_bg=rgb(65,34,44), track=rgb(8,16,25), white=rgb(247,252,255),
    red=rgb(244,149,153), green=rgb(120,219,168), blue=rgb(130,188,250)
}

function M:area()
    local w=math.min(920,self.width-48)
    return math.floor((self.width-w)/2)-4,w
end

function M:finish_section()
    if self.section then self.section.h=self.next_y-self.section.y+5; self.section=nil; self.next_y=self.next_y+16 end
end

local function label(s)
    s = tostring(s or "")
    return s:match("^(.-)##") or s, s:match("##(.*)$") or s
end

function M:measure(s)
    if not self.widths[s] then self.widths[s] = self.host:measure(s, 15) end
    return self.widths[s]
end

function M:place(w, h)
    local left, available=self:area()
    local inset=self.section and 16 or 0
    w = math.min(w, available-inset*2)
    local x, y = left+inset, self.next_y
    if self.same and self.last then x, y = self.last.x + self.last.w + 8, self.last.y end
    if x + w > left+available-inset then x, y = left+inset, self.next_y end
    self.same = false
    self.next_y = math.max(self.next_y, y + h + 10)
    self.last = {x=x, y=y, w=w, h=h}
    return x, y, w, h
end

function M:command(kind, text, x, y, w, h, extra)
    self.commands[#self.commands + 1] = {kind=kind, text=text, x=x, y=y, w=w, h=h, extra=extra,
        button_color=self.styles[1],text_color=self.styles[2]}
end

function M:control(text, w, h, kind, extra)
    local display, id = label(text)
    local _,available=self:area()
    available=available-(self.section and 32 or 0)
    local padding=(kind=='radio' or kind=='check') and 46 or 28
    w = math.min(math.max(w or 0,self:measure(display)+padding+4),available)
    if kind=='slider' then w=available end
    local rows=wrap.wrap(display,math.max(1,w-padding),function(s) return self:measure(s) end)
    local x, y, cw, ch = self:place(w, math.max(h or 36,#rows*21+14))
    self:command(kind or 'button', display, x, y, cw, ch, extra)
    local c=self.commands[#self.commands]; c.id=id; c.rows=rows; c.disabled=self.next_disabled; self.next_disabled=nil
    if kind=='slider' then c.track_x=x+14; c.track_w=cw-28 end
    if not c.disabled and kind~='notice' and kind~='swatch' and y >= self.scroll + 7 and y + ch <= self.scroll + self.height - 7 then
        self.hits[#self.hits + 1] = {id=id, kind=kind, x=x, y=y, w=cw, h=ch,track_x=c.track_x,track_w=c.track_w}
    end
    local action = self.actions[id]
    self.actions[id] = nil
    if c.disabled or kind=='notice' then action=nil end
    return action, id
end

function M:text(text)
    local _,available=self:area(); available=available-(self.section and 32 or 0)
    for _, row in ipairs(wrap.wrap(tostring(text), math.max(1,available), function(s) return self:measure(s) end)) do
        local x,y,w,h = self:place(self:measure(row)+2,23)
        self:command('text',row,x,y,w,h)
    end
end

function M:make_gui()
    local d, g = self, {constant={Col={Button=1,Text=2}}}
    function g.TextUnformatted(text) d:text(text) end
    function g.SameLine() d.same=true end
    function g.Section(text)
        d:finish_section(); d.same=false
        local left,w=d:area()
        local c={kind='section',text=text,x=left,y=d.next_y,w=w,h=40}
        d.commands[#d.commands+1]=c; d.section=c; d.next_y=d.next_y+48; d.last=nil
    end
    function g.Tabs(items,current)
        d:finish_section()
        for i,item in ipairs(items) do
            if i>1 then g.SameLine() end
            if d:control(item[2]..'##lmm_tab_'..item[1],nil,38,'tab',current==item[1]) then
                current=item[1]; d.scroll=0; d.combo=nil
            end
        end
        d.next_y=d.next_y+8; d.same=false
        return current
    end
    function g.Separator()
        local _,available=d:area()
        local x,y,w,h=d:place(available,4)
        d:command('separator','',x,y,w,h)
    end
    function g.Button(text,w,h)
        local _,id=label(text)
        if d.same and d.last and id:match('^lmm_delete_') then h=d.last.h end
        return d:control(text,w,h,id=='lmm_colour_preview' and 'swatch' or 'button') ~= nil
    end
    function g.DisableNext(value) d.next_disabled=value end
    function g.Notice(text,tone) local _,w=d:area(); d:control(text,w,36,'notice',tone) end
    function g.RadioButton(text,selected)
        return d:control(text,nil,29,'radio',selected) ~= nil
    end
    function g.Checkbox(text,checked)
        local action=d:control(text,nil,36,'check',checked)
        if action~=nil then return true,not checked end
        return false,checked
    end
    function g.SliderFloat(text,value,lo,hi,format)
        local display=label(text)
        local ratio=(value-lo)/(hi-lo)
        local action=d:control(text,nil,64,'slider',{
            ratio=ratio,caption=display,value=string.format(format or '%.2f',value)})
        if type(action)=='number' then return true,lo+math.max(0,math.min(1,action))*(hi-lo) end
        return false,value
    end
    function g.SliderInt(text,value,lo,hi)
        local changed,v=g.SliderFloat(text,value,lo,hi,'%.0f')
        return changed,math.floor(v+0.5)
    end
    function g.BeginCombo(text,current)
        local display,id=label(text)
        local action=d:control(display..': '..current..'  v##'..id,nil,36,'button')
        if action then d.combo=d.combo==id and nil or id end
        return d.combo==id
    end
    function g.Selectable(text,selected)
        local action=d:control(text,nil,36,'radio',selected)
        if action then d.combo=nil end
        return action~=nil
    end
    function g.EndCombo() end
    function g.Record(text,id)
        local _,w=d:area(); w=w-32
        local record_w=math.max(110,w-118)
        -- Reserve the action column before wrapping long record identifiers.
        local display=label(text)
        local rows=wrap.wrap(display,record_w-28,function(s) return d:measure(s) end)
        local x,y,cw,ch=d:place(record_w,math.max(45,#rows*21+14))
        d:command('record',display,x,y,cw,ch); local c=d.commands[#d.commands]; c.id=id; c.rows=rows
        if y>=d.scroll+7 and y+ch<=d.scroll+d.height-7 then d.hits[#d.hits+1]={id=id,kind='record',x=x,y=y,w=cw,h=ch} end
        local action=d.actions[id]; d.actions[id]=nil
        return action~=nil
    end
    function g.PushStyleColor(which,color) d.styles[which]=color end
    function g.PopStyleColor() d.styles={} end
    return g
end

function M:draw()
    if not self.host.ready then return end
    local host, a = self.host, self.host.api
    local function rect(x,y,w,h,c) host:rect(self.left+x,self.top-y-h,w,h,c) end
    local function border(x,y,w,h,c)
        rect(x,y,w,1,c); rect(x,y+h-1,w,1,c); rect(x,y,1,h,c); rect(x+w-1,y,1,h,c)
    end
    local function text(s,x,y,color,bold)
        a.XPLMFontDrawString(bold and host.fonts.bold or host.fonts.normal,color,15,self.left+x,self.top-y-16,s,0)
    end
    rect(0,0,self.width,self.height,colors.bg)
    for _,c in ipairs(self.commands) do
        local y=c.y-self.scroll
        if c.kind=='section' then
            local top,bottom=math.max(6,y),math.min(self.height-6,y+c.h)
            if bottom>top then rect(c.x,top,c.w,bottom-top,colors.card); border(c.x,top,c.w,bottom-top,colors.line) end
            if y>=6 and y+36<=self.height-6 then rect(c.x+1,y+1,4,34,colors.accent); text(c.text,c.x+16,y+11,colors.text,true) end
        elseif y>=6 and y+c.h<=self.height-6 then
            local x,text=c.x,c.text
            if c.kind=='separator' then rect(x,y+2,c.w,1,colors.line)
            else
                local fg=c.text_color or colors.text
                if c.kind~='text' then
                    local danger=(c.id and (c.id:match('^lmm_delete_') or c.id=='lmm_confirm')) or (c.kind=='notice' and c.extra=='error')
                    local primary=c.id=='lmm_preview' or c.kind=='tab' and c.extra
                    local active=(c.kind=='radio' or c.kind=='check') and c.extra
                    local hover=not c.disabled and self.hover==c.id
                    rect(x,y,c.w,c.h,c.button_color or (danger and colors.danger_bg or (active or primary) and colors.selected or hover and colors.hover or colors.surface))
                    border(x,y,c.w,c.h,danger and colors.danger or (active or primary or hover) and colors.accent or colors.line)
                    if danger then fg=colors.danger end
                    if c.disabled then fg=colors.muted; rect(x,y,c.w,c.h,colors.card); border(x,y,c.w,c.h,colors.line) end
                    if c.kind=='notice' then
                        rect(x,y,c.w,c.h,colors.card)
                        rect(x,y,3,c.h,c.extra=='error' and colors.danger or colors.accent)
                        fg=c.extra=='error' and colors.danger or colors.muted
                    end
                    if c.kind=='record' then rect(x,y,3,c.h,colors.accent) end
                    if c.kind=='radio' or c.kind=='check' then
                        local cy=y+math.floor((c.h-16)/2)
                        rect(x+12,cy,16,16,colors.track); border(x+12,cy,16,16,c.extra and colors.accent or colors.muted)
                        if c.extra then rect(x+16,cy+4,8,8,colors.accent) end
                        x=x+34
                    elseif c.kind=='slider' then
                        local tint=c.id=='lmm_popup_red' and colors.red or c.id=='lmm_popup_green' and colors.green or c.id=='lmm_popup_blue' and colors.blue or colors.accent
                        local tx,tw=x+14,c.w-28
                        local knob=tx+tw*math.max(0,math.min(1,c.extra.ratio))
                        rect(tx,y+43,tw,8,colors.track); border(tx,y+43,tw,8,colors.line)
                        rect(tx,y+44,knob-tx,6,tint)
                        rect(knob-7,y+37,14,20,colors.white); border(knob-7,y+37,14,20,tint)
                        rect(knob-2,y+41,1,12,colors.line); rect(knob+2,y+41,1,12,colors.line)
                        a.XPLMFontDrawString(host.fonts.normal,fg,15,self.left+x+14,self.top-y-22,c.extra.caption,0)
                        a.XPLMFontDrawString(host.fonts.bold,colors.white,15,self.left+x+c.w-14-self:measure(c.extra.value),self.top-y-22,c.extra.value,0)
                        text=nil
                    else x=x+14 end
                end
                if text then
                    local rows=c.kind=='text' and {text} or c.rows
                    local dy=c.kind=='text' and 0 or math.floor((c.h-#rows*21)/2)
                    for i,row in ipairs(rows) do
                        a.XPLMFontDrawString(host.fonts.normal,fg,15,self.left+x,
                            self.top-y-dy-16-(i-1)*21,row,0)
                    end
                end
            end
        end
    end
    if self.max_scroll>0 then
        local track=self.height-20
        local thumb=math.max(25,track*self.height/(self.max_scroll+self.height))
        rect(self.width-16,10,7,track,colors.track)
        rect(self.width-18,10+(track-thumb)*self.scroll/self.max_scroll,11,thumb,colors.muted)
    end
end

function M:mouse(x,y,status)
    x,y=x-self.left,self.top-y+self.scroll
    if status==1 then
        self.drag=nil
        if x>=self.width-24 and self.max_scroll>0 then
            local track=self.height-20
            local thumb=math.max(25,track*self.height/(self.max_scroll+self.height))
            local pos=y-self.scroll-10
            local top=(track-thumb)*self.scroll/self.max_scroll
            self.drag={kind='scroll',span=track-thumb,
                offset=(pos>=top and pos<=top+thumb) and (pos-top) or thumb/2}
        else
            for _,hit in ipairs(self.hits) do
                if x>=hit.x and x<=hit.x+hit.w and y>=hit.y and y<=hit.y+hit.h then
                    if hit.kind=='slider' then self.drag=hit else self.actions[hit.id]=true end
                    break
                end
            end
        end
    end
    if self.drag then
        if self.drag.kind=='scroll' then
            self.scroll=math.max(0,math.min(self.max_scroll,(y-self.scroll-10-self.drag.offset)/math.max(1,self.drag.span)*self.max_scroll))
        else self.actions[self.drag.id]=math.max(0,math.min(1,(x-self.drag.track_x)/self.drag.track_w)) end
    end
    if status==3 then self.drag=nil end
    return 1
end

function M:tick()
    if self.failed or not self.host.ready or self.host.api.XPLMGetWindowIsVisible(self.window)==0 then return false end
    local b=self.bounds
    self.host.api.XPLMGetWindowGeometry(self.window,b,b+1,b+2,b+3)
    self.left,self.top=tonumber(b[0]),tonumber(b[1])
    self.width,self.height=tonumber(b[2]-b[0]),tonumber(b[1]-b[3])
    self.commands,self.hits,self.next_y,self.last,self.same,self.section={}, {},20,nil,false,nil
    self.builder(self.gui)
    self:finish_section()
    self.max_scroll=math.max(0,self.next_y+12-self.height)
    self.scroll=math.min(self.scroll,self.max_scroll)
    self.actions={}
    return true
end

function M:destroy()
    if self.window then self.host.api.XPLMDestroyWindow(self.window); self.window=nil end
    for _,c in ipairs(self.callbacks or {}) do c:free() end
    self.callbacks={}
end

function M.new(host,ffi,builder,title,width,height)
    local d=setmetatable({host=host,builder=builder,commands={},hits={},widths={},styles={},
        callbacks={},actions={},scroll=0,max_scroll=0,width=width,height=height}, {__index=M})
    local ok,err=pcall(function()
        local a=host.api
        for _,symbol in ipairs({'XPLMGetWindowGeometry','XPLMGetWindowIsVisible',
            'XPLMSetWindowTitle','XPLMSetWindowResizingLimits'}) do assert(a[symbol],symbol) end
        local function keep(ctype,fn)
            local c=ffi.cast(ctype,fn); d.callbacks[#d.callbacks+1]=c; return c
        end
        d.bounds=ffi.new('int[4]')
        a.XPLMGetScreenBoundsGlobal(d.bounds,d.bounds+1,d.bounds+2,d.bounds+3)
        width=math.min(width,tonumber(d.bounds[2]-d.bounds[0])-40)
        height=math.min(height,tonumber(d.bounds[1]-d.bounds[3])-80)
        local spec=ffi.new('LMM118_WindowSpec')
        spec.structSize=ffi.sizeof(spec)
        spec.left=tonumber(d.bounds[0])+20; spec.top=tonumber(d.bounds[1])-55
        spec.right=spec.left+width; spec.bottom=spec.top-height
        d.left,d.top,d.width,d.height=tonumber(spec.left),tonumber(spec.top),width,height
        spec.visible,spec.decorateAsFloatingWindow,spec.layer,spec.contentType=1,1,1,1
        spec.drawWindowFunc=keep('LMM118_Draw',function()
            local good,e=pcall(d.draw,d); if not good then d.failed=tostring(e) end
        end)
        spec.handleMouseClickFunc=keep('LMM118_Mouse',function(_,x,y,status)
            local good,result=pcall(d.mouse,d,x,y,status)
            if not good then d.failed=tostring(result) end
            return 1
        end)
        spec.handleRightClickFunc=keep('LMM118_Mouse',function() return 1 end)
        spec.handleKeyFunc=keep('LMM118_Key',function() end)
        spec.handleCursorFunc=keep('LMM118_Cursor',function(_,x,y)
            d.hover=nil
            local lx,ly=x-d.left,d.top-y+d.scroll
            for _,hit in ipairs(d.hits) do
                if lx>=hit.x and lx<=hit.x+hit.w and ly>=hit.y and ly<=hit.y+hit.h then d.hover=hit.id; break end
            end
            return 0
        end)
        spec.handleMouseWheelFunc=keep('LMM118_Wheel',function(_,x,y,wheel,clicks)
            if wheel==0 then d.scroll=math.max(0,math.min(d.max_scroll,d.scroll-clicks*45)) end
            return 1
        end)
        d.window=a.XPLMCreateWindowEx(spec); assert(d.window~=nil,'Cannot create native dialog')
        a.XPLMSetWindowTitle(d.window,title)
        a.XPLMSetWindowResizingLimits(d.window,math.min(520,width),math.min(360,height),1200,1400)
        d.gui=d:make_gui()
        d:tick()
    end)
    if not ok then d:destroy(); error(err) end
    return d
end

if jit then for _,fn in pairs(M) do if type(fn)=='function' then jit.off(fn,true) end end end
return M

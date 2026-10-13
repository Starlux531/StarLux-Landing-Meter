local directory=... or ""
local Inputs=assert(loadfile(directory.."core_inputs.lua"))()
local VisualState=assert(loadfile(directory.."core_visual_state.lua"))()
local M={}; M.__index=M
local defaults={edge=true,edge_right=false,edge_alpha=24,stick=false,stick_wind=true,throttle=false,n1=false,engine_combined=false,
    g_meter=false,fpm_meter=false,live_combined=false,g_meter_size=180,fpm_meter_size=180,
    fpm_vvi=true,fpm_physical=true,fpm_agl=true,popup_fpm_source=1,
    g_meter_x=.60,g_meter_y=.22,fpm_meter_x=.75,fpm_meter_y=.22,g_meter_collapsed=false,fpm_meter_collapsed=false,
    compat_edge_size=24,compat_edge_alpha=18,compat_edge_lightness=75,
    edge_settings_y=-1,edge_records_y=-1,stick_collapsed=false,throttle_collapsed=false,n1_collapsed=false,
    edit=true,size=180,stick_size=180,throttle_size=180,n1_size=180,alpha=65,red=86,green=180,blue=235,
    stick_x=.05,stick_y=.22,throttle_x=.23,throttle_y=.22,n1_x=.41,n1_y=.22,wind_interval=1,appearance=1,popup_free_x=-1,popup_free_y=-1}
for _,id in ipairs({"stick","throttle","n1","g_meter","fpm_meter"}) do
    for _,key in ipairs({"alpha","red","green","blue"}) do defaults[id.."_"..key]=defaults[key] end
end
function M.new(refs,base)
    local self=setmetatable({config={},inputs=Inputs.new(refs.inputs,{find=XPLMFindDataRef,read=XPLMGetDataf,types=XPLMGetDataRefTypes}),
        refs=refs,base=base,engine={},legacy={},legacy_state={},wind={valid=false},wind_refs={},visual_state=VisualState.new()},M)
    for k,v in pairs(defaults) do self.config[k]=v end
    refs.observer=self.inputs
    return self
end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function weather_handle(path)
    local ok,h=pcall(XPLMFindDataRef,path); if not ok or not h then return nil end
    if XPLMGetDataRefTypes then
        local good,kind=pcall(XPLMGetDataRefTypes,h)
        if not good or type(kind)~="number" or math.floor(kind/2)%2~=1 then return nil end
    end
    return h
end
local function weather_value(h)
    if not h then return nil end
    local ok,v=pcall(XPLMGetDataf,h); if ok and finite(v) then return v end
end
function M:update_wind(now,true_heading,mag_heading,instrument_speed,instrument_from)
    local w=self.wind
    if not self.config.stick_wind or not (self.config.stick or self.debug) then w.valid=false;return end
    local refs=self.wind_refs
    if (not refs.speed or not refs.direction) and (not refs.probe or now<refs.probe-1 or now>=refs.probe) then
        refs.speed=refs.speed or weather_handle("sim/weather/aircraft/wind_now_speed_msc")
        refs.direction=refs.direction or weather_handle("sim/weather/aircraft/wind_now_direction_degt")
        refs.probe=now+1
    end
    local speed,direction=weather_value(refs.speed),weather_value(refs.direction)
    local heading,source,basis=true_heading,"aircraft","T"
    if finite(speed) and speed>=0 and finite(direction) and finite(heading) then
        speed=speed*1.9438444924406
    else
        speed,direction,heading=instrument_speed,instrument_from,mag_heading
        source,basis="instrument","M"
    end
    w.valid=finite(speed) and speed>=0 and finite(direction) and finite(heading)
    if not w.valid then w.label="N/A";w.dx,w.dy=nil,nil;w.relative=nil;w.display_source=nil;return end
    direction=direction%360
    local relative=(direction-heading)%360
    if w.relative~=relative then
        local angle=relative*math.pi/180
        w.dx,w.dy=-math.sin(angle),-math.cos(angle) -- Screen y is up; arrow blows away from wind origin.
        w.relative=relative
    end
    w.speed,w.from,w.basis,w.source,w.time=speed,direction,basis,source,now
    w.calm=speed<.05
    local degrees=math.floor(direction+.5)%360;local tenths=math.floor(speed*10+.5)
    if w.display_degrees~=degrees or w.display_tenths~=tenths or w.display_source~=source then
        w.label=w.calm and (string.format("0.0kt%s",source=="instrument" and " I" or ""))
            or string.format("%03d%s %.1fkt%s",degrees,basis,tenths/10,source=="instrument" and " I" or "")
        w.display_degrees,w.display_tenths,w.display_source=degrees,tenths,source
    end
end
function M:read_setting(key,value)
    local name=key and key:match("^live_(.+)$"); if not name then return end
    if name:match("^profile_%d+$") then self.inputs:read_profile(value); return end
    if defaults[name]~=nil then
        if type(defaults[name])=="boolean" then self.config[name]=value=="true"
        else
            local n=tonumber(value)
            if n and n==n then
                local min,max=0,255
                if name:match("^popup_free_[xy]$") or name:match("^edge_.+_y$") then min,max=-1,1
                elseif name:match("_[xy]$") then max=1
                elseif name=="compat_edge_size" then min,max=20,48
                elseif name=="compat_edge_lightness" then min,max=20,100
                elseif name:find("size",1,true) then min,max=120,360
                elseif name=="alpha" or name:match("_alpha$") then min,max=5,100
                elseif name=="popup_fpm_source" then min,max=1,3;n=math.floor(n)
                elseif name=="appearance" then min,max=1,6
                elseif name=="wind_interval" then min,max=.1,10 end
                self.config[name]=math.max(min,math.min(max,n))
            end
        end
    elseif name=="custom_pitch" or name=="custom_roll" or name=="custom_yaw" then
        if #value<=240 and value:match("^[%w_./%-]+$") then self.config[name]=value end
    end
end
function M:write_settings(file)
    local keys={}; for k in pairs(self.config) do keys[#keys+1]=k end; table.sort(keys)
    for _,k in ipairs(keys) do file:write("live_"..k.."="..tostring(self.config[k]).."\n") end
    self.inputs:write_profiles(file)
end
function M:update(now,identity)
    -- Observe every simulator frame. Disk sampling remains independently capped at 10 Hz.
    if self.last_time==now and identity==self.inputs.identity then return end
    self.last_time=now
    if identity~=self.inputs.identity then
        self.inputs:set_identity(identity)
        for _,axis in ipairs({"pitch","roll","yaw"}) do
            local p=self.config["custom_"..axis]; if p then self.inputs:set_custom(axis,p) end
        end
        self.refs.refresh_engine_context()
    end
    self.inputs:update(now)
    for axis,a in pairs(self.inputs.axes) do
        self.refs.inputs[axis].selected_candidate=a.selected and (a.selected.spec or a.selected) or nil
    end
    self.refs.capture(self.engine,true)
    self.engine_count=self.refs.recorded_engine_count
    self.visual_state:update(now,identity,self.config,self.debug,self.engine_count)
end
function M:select_source(axis,id)
    if not self.inputs:select(axis,id) then return false end
    self.inputs:update(self.last_time or self.inputs.now)
    for name,a in pairs(self.inputs.axes) do self.refs.inputs[name].selected_candidate=a.selected and (a.selected.spec or a.selected) or nil end
    self.refs.capture(self.engine,true)
    return true
end
function M:cycle(axis)
    local a=self.inputs.axes[axis]; local options={"auto"}
    for _,c in ipairs(a.candidates) do if c.valid then options[#options+1]=c.id end end
    local index=1; for i,id in ipairs(options) do if id==a.mode then index=i end end
    self:select_source(axis,options[index%#options+1])
end
local function section(gui,tr,zh,en)
    if gui.Section then gui.Section(tr(zh,en)) else gui.Separator();gui.TextUnformatted(tr(zh,en)) end
end
local function grid(gui,count,width)
    if gui.BeginGrid then gui.BeginGrid(count,width)
    elseif gui.Columns and gui.GetContentRegionAvail then
        local available=gui.GetContentRegionAvail()
        gui.Columns(math.max(1,math.min(count,math.floor(available/width))),"lmm_live_grid",false)
    end
end
local function grid_next(gui) if not gui.BeginGrid and gui.Columns and gui.GetContentRegionAvail then gui.NextColumn() end end
local function grid_end(gui)
    if gui.EndGrid then gui.EndGrid()
    elseif gui.Columns and gui.GetContentRegionAvail then gui.Columns(1,"lmm_live_grid",false) end
end
local function slider(gui,label,value,lo,hi)
    if not gui.BeginGrid and gui.SetNextItemWidth then
        gui.TextUnformatted(label:match("^(.-)##") or label);gui.SetNextItemWidth(-1)
        label="##"..(label:match("##(.*)$") or label)
    end
    return gui.SliderInt(label,value,lo,hi,"%d")
end
function M:shortcut_settings(gui,tr,save)
    section(gui,tr,"贴边快捷按钮","Edge shortcuts")
    local changed,v=gui.Checkbox(tr("显示贴边快捷按钮","Show edge shortcuts").."##live_edge",self.config.edge)
    if changed then self.config.edge=v;save() end
    gui.TextUnformatted(tr("沿侧边拖动可调整位置；隐藏后可从插件菜单打开设置。","Drag along the edge to reposition. Settings remain in the Plugins menu."))
    grid(gui,3,210)
    local rows=self.compatibility and {{"compat_edge_size","按钮大小","Shortcut size",20,48},{"compat_edge_alpha","按钮透明度","Shortcut opacity",5,100},{"compat_edge_lightness","按钮明暗","Shortcut lightness",20,100}}
        or {{"edge_alpha","按钮透明度","Shortcut opacity",5,100}}
    for _,row in ipairs(rows) do
        local c,n=slider(gui,tr(row[2],row[3]).."##live_"..row[1],self.config[row[1]],row[4],row[5])
        if c then self.config[row[1]]=n;save() end
        grid_next(gui)
    end
    grid_end(gui)
end
function M:settings(gui,tr,debug,save)
    local function choices(rows)
        grid(gui,3,210)
        for _,row in ipairs(rows) do
            local key=row[1]
            local combined=(key=='g_meter' or key=='fpm_meter') and 'live_combined'
                or (key=='throttle' or key=='n1') and 'engine_combined'
            local checked=self.config[key] and not (combined and self.config[combined])
            local changed,v=gui.Checkbox(tr(row[2],row[3]).."##live_"..key,checked)
            if changed then
                self.config[row[1]]=v
                -- Combined is a directly usable component, not a hidden modifier.
                if v and combined then self.config[combined]=false end
                if v and row[1]=='live_combined' then self.config.g_meter=false;self.config.fpm_meter=false end
                if v and row[1]=='engine_combined' then self.config.throttle=false;self.config.n1=false end
                save()
            end
            grid_next(gui)
        end
        grid_end(gui)
    end
    section(gui,tr,"实时组件","Live widgets")
    choices({{"fpm_meter","实时FPM组件","Live FPM widget"},{"g_meter","实时G值组件","Live G widget"},{"live_combined","实时G+FPM组件","Live G + FPM widget"}})
    gui.Separator()
    choices({{"throttle","实时油门杆组件","Live throttle widget"},{"n1","实时N1组件","Live N1 widget"},{"engine_combined","实时油门杆+N1组件","Live throttle + N1 widget"}})
    gui.Separator()
    choices({{"stick","操纵输入组件","Control input widget"},{"stick_wind","实时风向叠加","Live wind overlay"},{"edit","编辑布局（允许拖动）","Edit layout (allow dragging)"}})
    section(gui,tr,"FPM 数据来源","FPM sources")
    gui.TextUnformatted(tr("独立 FPM 来源（可多选）","FPM widget sources (multiple allowed)"))
    grid(gui,3,230)
    for i,key in ipairs({"fpm_vvi","fpm_physical","fpm_agl"}) do
        local label=({tr("VVI 指示","VVI indication"),tr("物理垂直速度","Physical vertical speed"),tr("AGL 高度变化估算","AGL height-change estimate")})[i]
        local changed,v=gui.Checkbox(label.."##live_"..key,self.config[key])
        if changed then
            self.config[key]=v
            if not (self.config.fpm_vvi or self.config.fpm_physical or self.config.fpm_agl) then self.config[key]=true end
            save()
        end
        grid_next(gui)
    end
    grid_end(gui)
    gui.TextUnformatted(tr("即时演算 FPM 来源（独立设置）","Live-calculation FPM source (independent)"))
    grid(gui,3,210)
    for i,label in ipairs({"VVI",tr("物理","Physical"),tr("AGL估算","AGL estimate")}) do
        if gui.RadioButton(label.."##popup_fpm_"..i,self.config.popup_fpm_source==i) then self.config.popup_fpm_source=i;save() end
        grid_next(gui)
    end
    grid_end(gui)
    gui.TextUnformatted(tr("来源缺失显示不可用；仅影响显示，不修改评分。","Missing sources show unavailable; display only, grading unchanged."))
    section(gui,tr,"大小与外观","Size and appearance")
    gui.TextUnformatted(tr("配色修改对象","Appearance target"))
    grid(gui,3,210)
    for i,row in ipairs({{"全部组件","All widgets"},{"摇杆","Input"},{"油门","Throttle"},{"N1","N1"},{"实时 G","Live G"},{"实时 FPM","Live FPM"}}) do
        if gui.RadioButton(tr(row[1],row[2]).."##live_style_"..i,self.config.appearance==i) then self.config.appearance=i end
        grid_next(gui)
    end
    grid_end(gui)
    grid(gui,2,270)
    for _,row in ipairs({
        {"g_meter_size","实时 G 大小","Live G size",120,360},{"fpm_meter_size","实时 FPM 大小","Live FPM size",120,360},{"stick_size","摇杆大小","Input size",120,360},{"throttle_size","油门大小","Throttle size",120,360},
        {"n1_size","N1 大小","N1 size",120,360},{"alpha","组件透明度","Widget opacity",5,100},
        {"red","红","Red",0,255},{"green","绿","Green",0,255},{"blue","蓝","Blue",0,255}}) do
        if not (self.compatibility and row[1]=="edge_alpha") then
        local key=row[1]; local style=key=="alpha" or key=="red" or key=="green" or key=="blue"
        local target=({"","stick_","throttle_","n1_","g_meter_","fpm_meter_"})[math.floor(self.config.appearance)] or ""
        if style then key=target..key end
        -- FlyWithLua's ImGui binding requires format even though C++ has a default.
        local changed,v=slider(gui,tr(row[2],row[3]).."##live_"..key,self.config[key],row[4],row[5])
        if changed then
            self.config[key]=v
            if style and target=="" then for _,id in ipairs({"stick","throttle","n1","g_meter","fpm_meter"}) do self.config[id.."_"..key]=v end end
            save()
        end
        end
        grid_next(gui)
    end
    grid_end(gui)
    if gui.Button(tr("恢复覆盖层默认布局","Reset overlay layout").."##live_reset") then
        for k,v in pairs(defaults) do if k:match("_[xy]$") or k:find("size",1,true) or k:match('_collapsed$') then self.config[k]=v end end; save()
    end
    section(gui,tr,"录制与诊断","Recording and diagnostics")
    local wind_changed,wind_interval=gui.SliderFloat(tr("风采样间隔（秒）","Wind sample interval (seconds)").."##live_wind",self.config.wind_interval,.1,10,"%.1f")
    if wind_changed then self.config.wind_interval=wind_interval; save() end
    if self.recording then
        gui.TextUnformatted(tr("连续录制状态：","Recording: ")..self.recording.phase)
        if self.recording.file and gui.Button(tr("结束并保存当前片段","End and save current segment").."##record_stop") then self.pending="stop_recording" end
        if self.recording.error then gui.TextUnformatted(self.recording.error) end
        if self.recording.export_failed and gui.Button(tr("重试保存完整记录","Retry saving full recording").."##record_retry") then self.pending="retry_recording_export" end
        if self.recording.start_agl then gui.TextUnformatted(string.format("Start %.0f ft / %d samples",self.recording.start_agl,self.recording.samples)) end
    end
    if not debug then return end
    gui.Separator(); gui.TextUnformatted(tr("输入诊断（只读取，不控制飞机）","Input diagnostics (read-only)"))
    if gui.Button(tr("重新探测数据源","Probe sources again").."##live_probe") then self.inputs:probe() end
    for _,axis in ipairs({"pitch","roll","yaw"}) do
        local a=self.inputs.axes[axis]
        gui.TextUnformatted(axis.." / "..a.mode.." / "..a.status)
        if gui.RadioButton(tr("自动","Auto").."##source_"..axis.."_auto",a.mode=="auto") then self:select_source(axis,"auto") end
        for _,c in ipairs(a.candidates) do
            local label=c.id.." ["..c.status.."] "..(c.valid and string.format("raw %.3f / %.3f",c.raw,c.value) or "--")
            if c.valid then label=label..(c.changed_at and string.format(" / changed %.1fs",math.max(0,self.inputs.now-c.changed_at)) or " / no motion observed") end
            if gui.RadioButton(label.."##source_"..axis.."_"..c.id,a.mode==c.id) then
                if not self:select_source(axis,c.id) then self.notice=tr("该来源当前不可读","This source is not readable") end
            end
            gui.TextUnformatted(c.path)
        end
    end
    if gui.Button(tr("为当前机模保存来源选择","Save source choices for this aircraft").."##source_save") then
        self.inputs:remember_profile(); save()
        self.notice=tr("机模配置已写入设置","Aircraft profile written to settings")
    end
    if self.notice then gui.TextUnformatted(self.notice) end
end
function M:visible(id,debug)
    if self.config.live_combined and (id=="g_meter" or id=="fpm_meter") then return id=="g_meter" end
    if id=="settings" or id=="records" then return self.config.edge end
    if self.config.engine_combined and (id=="throttle" or id=="n1") then return id=="throttle" end
    return self.config[id] or id=="stick" and debug
end
function M:present(host,debug,en)
    self.debug,self.en=debug,en
    if host and host.ready then
        if not self.renderer then
            self.renderer=assert(loadfile(self.base.."LMM_UI_119/overlays.lua"))().new(host,require("ffi"),self)
        end
        self.renderer:tick()
        for id,w in pairs(self.legacy) do float_wnd_destroy(w); self.legacy[id]=nil end
    else
        if self.renderer then self.renderer:destroy(); self.renderer=nil end
        if not SUPPORTS_FLOATING_WINDOWS then return end
        for _,id in ipairs({"settings","records","stick","throttle","n1","g_meter","fpm_meter"}) do
            local edge=id=="settings" or id=="records"
            local visible=self:visible(id,debug)
            local w=self.legacy[id]
            local collapsed=not edge and self.config[id..'_collapsed']
            local compact=edge and self.compatibility
            local width=edge and (compact and self.config.compat_edge_size or 52) or collapsed and 126 or 245
            local height=edge and (compact and width or 42) or collapsed and 32 or (id=="throttle" and self.config.engine_combined and math.max(120,40+32*(self.engine_count or 2)) or debug and 210 or 120)
            if visible and not w then
                -- Raw FWL windows avoid ImGui's opaque host background and minimum
                -- size/padding. This uses the old SDK draw API, never SDK 440 fonts.
                w=float_wnd_create(width,height,0,not compact)
                self.legacy[id]=w
                if compact then
                    float_wnd_set_ondraw(w,"ma_live_"..id.."_draw")
                    float_wnd_set_onclick(w,"ma_live_"..id.."_click")
                else float_wnd_set_imgui_builder(w,"ma_live_"..id) end
                self.legacy_state[id]={}
            elseif not visible and w then float_wnd_destroy(w); self.legacy[id]=nil; w=nil end
            if w then
                local sw,sh=SCREEN_WIDTH or 1920,SCREEN_HIGHT or 1080
                local c=self.legacy_state[id];local pos=self.config['edge_'..id..'_y'] or -1
                local x=edge and (self.config.edge_right and sw-width or 0) or math.floor((sw-245)*(self.config[id.."_x"] or .1))
                local y=edge and (pos>=0 and math.floor((sh-height)*pos) or math.floor(sh*.55)+(id=="settings" and height+6 or 0)) or math.floor((sh-210)*(self.config[id.."_y"] or .2))
                y=math.max(0,math.min(sh-height,y))
                if c.width~=width or c.height~=height then
                    if float_wnd_set_geometry then float_wnd_set_geometry(w,x,y+height,x+width,y) end
                    c.width,c.height=width,height
                end
                if c.x~=x or c.y~=y then float_wnd_set_position(w,x,y);c.x,c.y=x,y end
            end
        end
    end
end
function M:edge_draw(id,x,y)
    local c=self.legacy_state[id];if not c then return end
    local size=c.width or self.config.compat_edge_size
    local hover=type(MOUSE_X)=='number' and type(MOUSE_Y)=='number'
        and MOUSE_X>=x and MOUSE_X<=x+size and MOUSE_Y>=y and MOUSE_Y<=y+size
    local a=self.config.compat_edge_alpha/100
    if hover or c.drag then a=math.max(.8,a) end
    local light=self.config.compat_edge_lightness/100
    XPLMSetGraphicsState(0,0,0,1,1,0,0)
    glColor4f(light,light,light,a*.42);glRectf(x,y,x+size,y+size)
    glColor4f(light,light,light,a)
    glRectf(x,y,x+size,y+1);glRectf(x,y+size-1,x+size,y+size)
    glRectf(x,y,x+1,y+size);glRectf(x+size-1,y,x+size,y+size)
    -- XPLM draw_string replaces the GL color with opaque RGB. The legacy bitmap
    -- font preserves glColor4f alpha, so letters fade together with the square.
    draw_string_Helvetica_10(x+(size-7)/2,y+(size-10)/2,id=='settings' and 'S' or 'R')
    if hover and not c.drag then
        local label=id=='settings' and 'Settings' or 'Landing records'
        local tx=self.config.edge_right and x-#label*8-10 or x+size+10
        glColor4f(.05,.07,.09,.8);glRectf(tx-4,y-2,tx+#label*8+4,y+18)
        glColor4f(.9,.94,1,.95);draw_string_Helvetica_10(tx,y+3,label)
    end
end
function M:edge_click(id,x,y,status)
    local c=self.legacy_state[id];if not c then return end
    -- FWL supplies coordinates relative to the window bottom. Recover the
    -- global mouse position before moving it to avoid drag feedback/jumping.
    local global_y=(c.y or 0)+y
    if status==1 then c.drag={start_y=global_y,y=c.y or 0};return end
    local d=c.drag;if not d then return end
    local delta=global_y-d.start_y
    if math.abs(delta)>4 then d.moved=true end
    if d.moved then
        self.config['edge_'..id..'_y']=math.max(0,math.min(1,
            (d.y+delta)/math.max(1,(SCREEN_HIGHT or 1080)-(c.height or self.config.compat_edge_size))))
    end
    if status==3 then
        if d.moved then self.pending='save'
        elseif x>=0 and x<=c.width and y>=0 and y<=c.height then self.pending=id end
        c.drag=nil
    end
end
function M:legacy_build(id)
    local g=imgui
    local edge=id=='settings' or id=='records'
    local state=self.legacy_state[id] or {};self.legacy_state[id]=state
    local visual=self.visual_state
    local function styled(ink,fn)
        local can=g.PushStyleColor and g.PopStyleColor and g.constant and g.constant.Col
        if can then g.PushStyleColor(g.constant.Col.Text,ink) end
        local result=fn()
        if can then g.PopStyleColor() end
        return result
    end
    if id=="settings" or id=="records" then
        local alpha=state.hover and 245 or math.floor(self.config.edge_alpha*2.55+.5)
        local clicked=styled(0xFFEFD1+alpha*16777216,function() return g.Button(id=="settings" and "S" or "R",28,24) end)
        state.hover=g.IsItemHovered and g.IsItemHovered()
        if g.IsItemActive and g.IsItemActive() and type(MOUSE_Y)=='number' then
            state.drag=state.drag or {start_y=MOUSE_Y,y=state.y or 0}
        end
        local d=state.drag
        if d and type(MOUSE_Y)=='number' then
            local delta=MOUSE_Y-d.start_y
            if math.abs(delta)>4 then d.moved=true end
            if d.moved then self.config['edge_'..id..'_y']=math.max(0,math.min(1,(d.y+delta)/math.max(1,(SCREEN_HIGHT or 1080)-42))) end
            if g.IsMouseDown and not g.IsMouseDown(0) then
                if d.moved then self.pending='save' elseif clicked then self.pending=id end
                state.drag=nil
            end
        elseif clicked then self.pending=id end
        if g.IsItemHovered and g.IsItemHovered() and g.SetTooltip then g.SetTooltip(id=="settings" and "Settings" or "Landing records") end
        return
    end
    if self.config[id..'_collapsed'] then
        styled(0x80FFEFD1,function()
            if g.Button(id:upper()..' +',108,20) then self.config[id..'_collapsed']=false;self.pending='save' end
        end)
        return
    end
    -- Corner control overlays the existing first row; it consumes no extra row.
    if g.GetCursorPosX and g.GetCursorPosY and g.SetCursorPosX and g.SetCursorPosY then
        local x,y=g.GetCursorPosX(),g.GetCursorPosY()
        g.SetCursorPosX(215)
        if g.Button('-##fold_'..id,18,16) then self.config[id..'_collapsed']=true;self.pending='save' end
        g.SetCursorPosX(x);g.SetCursorPosY(y)
    end
    if id=="g_meter" or id=="fpm_meter" then
        local td=self.touchdown
        if not td then g.TextUnformatted("Unavailable");return end
        local function number_line(value,label,is_fpm)
            local v=is_fpm and value and math.max(0,-value) or value
            local ink=v and v>(is_fpm and 300 or 1.8) and 0xFF3838FF or v and v>(is_fpm and 250 or 1.5) and 0xFF26C7FF or 0xF5FFEFD1
            styled(ink,function()g.TextUnformatted(label)end)
        end
        g.TextUnformatted("LIVE / display only")
        if id=="g_meter" then number_line(td.live_g,td.g_text,false) end
        if id=="fpm_meter" or self.config.live_combined then
            local live=self.live_fpm
            if live then for _,source in ipairs(live:selected(self.config)) do number_line(live.values[source],live:line(source,true),true) end end
        end
        return
    end
    if id=="stick" then
        if self.config.stick_wind then g.TextUnformatted("WIND FROM "..(self.wind.valid and self.wind.label or "N/A")) end
        for _,axis in ipairs({"pitch","roll","yaw"}) do
            local input=self.inputs.axes[axis]
            local value=input.valid and input.value or nil
            g.TextUnformatted(axis..": "..(value and string.format("%.3f",value) or "--"))
            if self.debug and g.Button((input.selected and input.selected.id or "unavailable").."##"..axis) then self:cycle(axis) end
        end
    else
        g.TextUnformatted(id=="throttle" and self.config.engine_combined and "THR % / N1 %" or id:upper())
        for i=1,self.engine_count or 0 do
            if id=="throttle" and self.config.engine_combined then
                local thr=self.engine["throttle_"..i.."_valid"] and string.format("%.0f",(self.engine["throttle_"..i.."_ratio"] or 0)*100) or "--"
                local n1=self.engine["n1_"..i.."_valid"] and string.format("%.1f",self.engine["n1_"..i.."_percent"] or 0) or "--"
                g.TextUnformatted("ENG "..i.."  THR "..thr.."%")
                styled(visual.reverse[i] and 0xFF3838FF or 0xF5FFEFD1,function() g.TextUnformatted("  N1 "..n1.."%"..(visual.reverse[i] and " R" or "")) end)
            else
            local key=id=="n1" and "n1_"..i.."_percent" or "throttle_"..i.."_ratio"
            local valid=self.engine[key:gsub("_percent$","_valid"):gsub("_ratio$","_valid")]
            local reverse=id=='n1' and visual.reverse[i]
            styled(reverse and 0xFF3838FF or 0xF5FFEFD1,function()
                g.TextUnformatted((reverse and 'R ' or 'ENG ')..i..": "..(valid and string.format("%.1f",self.engine[key]*(id=="n1" and 1 or 100)) or "--"))
            end)
            end
        end
    end
end
function M:destroy()
    if self.renderer then self.renderer:destroy(); self.renderer=nil end
    for _,w in pairs(self.legacy) do float_wnd_destroy(w) end; self.legacy={}
end
M.defaults=defaults
return M

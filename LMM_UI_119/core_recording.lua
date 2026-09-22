-- Versioned, bounded streaming recorder. No synthetic samples across loading gaps.
local M={}; M.__index=M
local ils_keys={"ils_version","ils_model","ils_source","ils_status","ils_airport","ils_runway",
"ils_loc_id","ils_loc_lat","ils_loc_lon","ils_loc_course_true","ils_loc_frequency_mhz",
"ils_gs_lat","ils_gs_lon","ils_gs_elevation_m","ils_gs_angle_deg","ils_scale_source",
"ils_loc_deg_per_dot","ils_gs_deg_per_dot","ils_max_range_nm","ils_max_sector_deg",
"ils_loc_source_path","ils_gs_source_path","ils_gs_status","ils_selection"}
local unavailable_ils={ils_version=1,ils_model="geometric_reference",ils_status="reference_unavailable"}
local fields={"t","lat","lon","agl","msl","gs","ias","pitch","roll","heading","g","ground",
"pitch_input","roll_input","yaw_input","pitch_source","roll_source","yaw_source",
"throttle1","throttle2","throttle3","throttle4","n1_1","n1_2","n1_3","n1_4","along","cross","physical_fpm","vvi","aoa",
"elevator1","elevator2","aileron1","aileron2","rudder1","rudder2","lever1","lever2","lever3","lever4",
"detent1","detent2","detent3","detent4","detent_mode","engine_count","trace_fpm","trace_fpm_source","true_heading"}
local function number(x) return type(x)=="number" and x==x and math.abs(x)<math.huge end
local function text(x)
    if x==nil then return "" end
    if type(x)=="number" then return number(x) and string.format("%.12g",x) or "" end
    return tostring(x):gsub("[\t\r\n]"," ")
end
local function row(kind,values)
    local out={kind}; for i=1,values.n or #values do out[#out+1]=text(values[i]) end
    return table.concat(out,"\t").."\n"
end
local function distance(a,b)
    local lat=(a.lat+b.lat)*math.pi/360
    return math.sqrt(((a.lat-b.lat)*111195)^2+((a.lon-b.lon)*111195*math.cos(lat))^2)
end
function M.new(dir)
    return setmetatable({dir=dir,phase="IDLE",serial=0,pending={},queued=0,samples=0,sequence=0},M)
end
function M:emit(kind,values)
    if not self.file then return end
    local line=row(kind,values)
    if self.queued+#line>131072 then
        self.error="recording queue limit"; self.file:close(); self.file=nil; self.phase="INCOMPLETE"; self.retry_after=(self.last and self.last.t or self.start_time or 0)+10; return
    end
    self.pending[#self.pending+1]=line; self.queued=self.queued+#line
end
function M:flush(sync)
    if not self.file or self.queued==0 then return true end
    local chunk=table.concat(self.pending)
    local ok,e=self.file:write(chunk)
    if ok and sync then ok,e=self.file:flush() end
    if not ok then self.error=tostring(e); self.file:close(); self.file=nil; self.phase="INCOMPLETE"; self.retry_after=(self.last and self.last.t or self.start_time or 0)+10; return false end
    self.pending={}; self.queued=0
    return true
end
function M:emit_ils_metadata()
    if not self.ils_reference then return end
    -- META is last-value-wins. Empty values explicitly remove old LOC/GS fields
    -- when the runway changes to LOC-only, no ILS, or an unavailable reference.
    for _,key in ipairs(ils_keys) do self:emit("META",{key,self.ils_reference[key] or ""}) end
end
function M:update_ils_reference(reference)
    if not self.file then return false end
    local previous=self.ils_reference
    if not reference then
        if not previous then return false end
        reference=unavailable_ils
    end
    -- Identity alone is insufficient: the resolver mutates ils_selection on a
    -- cached reference. Compare the small fixed schema without allocating.
    local changed=not previous
    if previous then
        for _,key in ipairs(ils_keys) do
            if previous[key]~=reference[key] then changed=true; break end
        end
    end
    if not changed then return false end
    local snapshot={}
    for _,key in ipairs(ils_keys) do snapshot[key]=reference[key] end
    self.ils_reference=snapshot
    self:emit_ils_metadata()
    -- Only changes flush the Lua/C file buffer, keeping the newest reference
    -- recoverable from .part even before the next 10 Hz sample or normal close.
    self:flush(true)
    return true
end
function M:start(s,reason)
    if self.file or self.export then return false end
    self.serial=self.serial+1
    self.id=os.date("%Y%m%d_%H%M%S").."_"..self.serial
    local base=self.dir..".LMM_Recording_"..self.id
    while true do
        local old=io.open(base..".part","rb")
        if not old then break end
        old:close(); self.serial=self.serial+1; self.id=os.date("%Y%m%d_%H%M%S").."_"..self.serial; base=self.dir..".LMM_Recording_"..self.id
    end
    local f,e=io.open(base..".part","wb")
    if not f then self.error=tostring(e); self.phase="INCOMPLETE"; self.retry_after=s.t+10; return false end
    self.file=f; self.spool=base..".part"; self.phase="APPROACH_RECORDING"
    self.start_time=s.t; self.start_agl=s.agl; self.missing=s.agl<2450; self.touch_time=nil; self.touch_agl=nil
    self.summary_dirty=false
    self.rollout_pending={};self.rollout_front_missing=false
    self.pending={}; self.queued=0; self.samples=0; self.next_sample=s.t; self.next_wind=s.t
    self.wind=nil; self.route=nil; self.last=nil; self.climb_since=nil; self.low_speed_since=nil; self.gaps=0; self.done=false
    self.ils_reference=nil
    self.max_sample_gap=0; self.missed_slots=0
    self.summary=nil; self.report_path=nil; self.saved_path=nil; self.error=nil; self.identity=s.identity; self.closed=false; self.export_failed=false
    self:emit("LMM_RECORDING_BEGIN",{1})
    local names={"T"}; for _,key in ipairs(fields) do names[#names+1]=key end
    self:emit("FIELDS",names)
    self:emit("FIELDS",{"W","t","speed_kt","from_deg_mag","headwind_kt","crosswind_from_right_kt","mean_speed_kt","peak_speed_kt","peak_time","count","source","from_deg_true","runway_headwind_kt","runway_crosswind_from_right_kt"})
    self:emit("META",{"session_id",self.id}); self:emit("META",{"start_reason",reason})
    self:emit("META",{"height_source","sim/flightmodel/position/y_agl"})
    self:emit("META",{"start_agl_ft",s.agl}); self:emit("META",{"start_time",s.t})
    self:emit("META",{"front_missing",self.missing and 1 or 0})
    self:emit("META",{"aircraft",s.identity})
    self:emit("META",{"units","t=sim_s;lat/lon=deg;agl/msl=ft;gs/ias=kt;pitch/roll/heading/true_heading/aoa/surfaces=deg;physical_fpm/vvi/trace_fpm=ft/min;g=g;input/throttle/lever=ratio;n1=percent;along/cross=m;blank=unavailable"})
    self:emit("META",{"wind_interval_s",self.wind_interval or 1})
    local initial={n=#fields}; for i,key in ipairs(fields) do initial[i]=s[key] end
    self:emit("T",initial); self.samples=1; self.next_sample=s.t+.1
    return true
end
function M:stop(reason,complete)
    if not self.file then return end
    self:wind_row()
    self.phase=complete and "COMPLETE" or "INCOMPLETE"; self.reason=reason; self.done=true
    if reason=="manual_end" then self.manual_hold=true end
    if self.route then
        self:emit("META",{"runway_heading_true",self.route.heading_true})
        self:emit("META",{"rollout_rule",self.route.rule})
        self:emit("META",{"rollout_mode",self.route.shadow and "shadow_unvalidated" or "graded"})
        self:emit("META",{"rollout_max_offset_m",self.route.max_offset})
        self:emit("META",{"rollout_rms_m",self.route.rms})
        self:emit("META",{"rollout_swings",self.route.swings})
        self:emit("META",{"rollout_min_gs_kt",60})
        self:emit("META",{"rollout_span_m",self.route.max_span})
        self:emit("META",{"rollout_outside_3_s",self.route.longest_outside})
        self:emit("META",{"rollout_unrecovered_9_s",self.route.longest_red})
        self:emit("META",{"rollout_samples",self.route.samples})
        self:emit("META",{"rollout_front_missing",self.rollout_front_missing and 1 or 0})
        for _,event in ipairs(self.route.evidence or {}) do
            self:emit("E",{event.t,event.kind,event.value,event.limit,event.duration,self.route.shadow and "shadow_unvalidated" or "graded",event.gs})
        end
    end
    -- One authoritative reference for retrospective projection of the full
    -- track. A late touchdown selection replaces any approach hypothesis.
    self:emit_ils_metadata()
    self:emit("META",{"touch_time",self.touch_time or ""})
    self:emit("META",{"end_time",self.last and self.last.t or self.start_time})
    self:emit("META",{"phase",self.phase}); self:emit("META",{"end_reason",reason})
    self:emit("META",{"gaps",self.gaps}); self:emit("META",{"samples",self.samples})
    self:emit("META",{"max_sample_gap_s",self.max_sample_gap}); self:emit("META",{"missed_sample_slots",self.missed_slots})
    self:emit("LMM_RECORDING_END",{1,self.samples})
    if not self.file or not self:flush() then return end
    local ok,e=self.file:close(); self.file=nil
    if not ok then self.error=tostring(e); self.phase="INCOMPLETE"; self.retry_after=(self.last and self.last.t or self.start_time or 0)+10; return end
    self.closed=true
end
function M:wind_row()
    local w=self.wind
    if not w or w.count==0 then return end
    local s=w.last
    local angle=number(s.heading) and ((s.wind_from-s.heading)%360)*math.pi/180
    local from_true=number(s.true_heading) and number(s.heading) and (s.wind_from+s.true_heading-s.heading)%360 or nil
    local runway_angle=from_true and s.runway_heading_true and (from_true-s.runway_heading_true)*math.pi/180
    self:emit("W",{n=13,s.t,s.wind_speed,s.wind_from,angle and s.wind_speed*math.cos(angle),angle and s.wind_speed*math.sin(angle),w.sum/w.count,w.peak,w.peak_time,w.count,"cockpit2_instrument",from_true,runway_angle and s.wind_speed*math.cos(runway_angle),runway_angle and s.wind_speed*math.sin(runway_angle)})
    self.wind=nil
end
function M:attach_summary(content,path)
    if self.id then self.summary=content; self.report_path=path end
end
function M:begin_export(prefix)
    if not self.closed or self.export or self.saved_path or self.export_failed then return end
    local source,e=io.open(self.spool,"rb"); if not source then self.error=tostring(e); self.export_failed=true; return end
    local target=self.report_path or self.dir.."LMM_"..self.id..".txt"
    local out,err=io.open(target..".recording.tmp","wb")
    if not out then source:close(); self.error=tostring(err); self.export_failed=true; return end
    local zh=self.language=="zh"
    local status=(zh and "连续录制状态: " or "Recording: ")..self.phase.." / "..tostring(self.reason).."\n"..
        (zh and "起始 AGL: " or "Start AGL: ")..text(self.start_agl).." ft; "..
        (zh and "前段缺失: " or "front missing: ")..tostring(self.missing).."; "..
        (zh and "间隙: " or "gaps: ")..self.gaps.."\n\n"
    local fallback="StarLux LMM v"..(self.version or "1.1.9")..(zh and " - 片段记录\n没有已确认的接地分析。\n" or " - partial recording\nNo verified touchdown analysis available.\n")
    self.export={source=source,out=out,path=target,prefix=status..(prefix or self.summary or fallback)..(zh and "\n完整记录\n" or "\nFull recording\n"),offset=1}
end
function M:export_step()
    local e=self.export; if not e then return end
    local chunk
    if e.offset<=#e.prefix then chunk=e.prefix:sub(e.offset,e.offset+8191); e.offset=e.offset+#chunk
    else chunk=e.source:read(8192) end
    if chunk then
        local ok,err=e.out:write(chunk)
        if not ok then self.error=tostring(err); e.source:close(); e.out:close(); self.export=nil; self.export_failed=true end
        return
    end
    e.source:close(); local ok,err=e.out:close()
    if not ok then self.error=tostring(err); self.export=nil; self.export_failed=true; return end
    local old=io.open(e.path,"rb"); local backup=false
    if old then
        old:close()
        -- Never overwrite an earlier recovery backup.
        local exists=io.open(e.path..".previous","rb")
        if exists then exists:close(); self.error="Recovery backup already exists"; self.export=nil; self.export_failed=true; return end
        backup=os.rename(e.path,e.path..".previous")
        if not backup then self.error="Cannot preserve previous report"; self.export=nil; self.export_failed=true; return end
    end
    local renamed,why=os.rename(e.path..".recording.tmp",e.path)
    if not renamed then
        if backup then os.rename(e.path..".previous",e.path) end
        self.error=tostring(why); self.export_failed=true
    else self.saved_path=e.path; self.closed=false end
    self.export=nil
end
function M:tick(s,wind_interval,route,ils_reference)
    self.wind_interval=math.max(.1,wind_interval or 1)
    self:export_step()
    local valid=number(s.t) and number(s.lat) and number(s.lon) and math.abs(s.lat)<=90 and math.abs(s.lon)<=180
        and number(s.agl) and s.agl>=-20 and number(s.gs) and (s.ground==0 or s.ground==1)
    if not valid or s.replay then
        if self.file then self:stop(s.replay and "replay" or "invalid_position",false) end
        self.previous=nil; return
    end
    if s.paused then
        if self.file and not self.pause_at then self:emit("E",{s.t,"pause"}) end
        if self.file and not self.pause_at then self:rollout_sample({break_segment=true},route) end
        self.pause_at=s.t; self.low_speed_since=nil; self.climb_since=nil; return
    end
    if self.pause_at then
        if self.file then self:emit("E",{s.t,"resume"}) end
        self.pause_at=nil
    end
    local prev=self.previous
    if prev and (s.t<prev.t or s.identity~=prev.identity or distance(s,prev)>math.max(500,s.gs*.514445*math.max(0,s.t-prev.t)*3)) then
        if self.file then self:stop("load_or_discontinuity",false) end
        self.previous=nil; self.manual_hold=false; self.blocked_until=s.t+.2; return
    end
    if self.file and prev and s.t-prev.t>1 then
        self.gaps=self.gaps+1; self:emit("E",{s.t,"gap",s.t-prev.t}); self.low_speed_since=nil
    end
    if self.manual_hold and (s.ground==1 or s.agl>2500) then self.manual_hold=false end
    if not self.file and not self.export and not self.closed and not self.manual_hold and s.t>=math.max(self.blocked_until or 0,self.retry_after or 0) then
        if s.ground==0 and s.agl<=2500 and s.gs>35 and (s.vy or 0)<=.5 and prev and prev.ground==0 and s.t>prev.t then
            self:start(prev.agl<=2500 and prev or s,prev.agl>2500 and "threshold" or "mid_approach")
        elseif prev and prev.ground==0 and s.ground==1 and prev.agl>0 and prev.agl<=100
            and prev.gs>35 and (prev.vy or 0)<0 and s.t>prev.t and s.t-prev.t<=.25 then
            self:start(prev,"late_approach_touchdown")
        end
    end
    -- Keep the preceding recording's reference on load/replay discontinuities
    -- (handled above), but clear an explicitly lost reference within this flight.
    if self.file then self:update_ils_reference(ils_reference) end
    if self.file then
        if not self.touch_time and prev and prev.ground==0 and s.ground==1 and s.t>prev.t and s.t-prev.t<=1 then
            self.touch_time=s.t; self.touch_agl=s.agl; self.phase="ROLLOUT"; self:emit("E",{s.t,"touchdown"})
        elseif self.touch_time and prev and prev.ground~=s.ground then
            self:emit("E",{s.t,s.ground==0 and "airborne_after_touchdown" or "ground_contact"})
        end
        if s.ground==0 and (s.vy or 0)>3 and (not self.touch_time or s.agl>(self.touch_agl or 0)+300) then
            self.climb_since=self.climb_since or s.t
        else self.climb_since=nil end
        if self.climb_since and s.t-self.climb_since>5 or s.agl>3000 then self:stop("go_around",false)
        elseif s.t-self.start_time>7200 then self:stop("duration_limit",false) end
    end
    if self.file and self.touch_time then
        if s.ground==1 and s.gs<30 then
            self.low_speed_since=self.low_speed_since or s.t
            self.phase="LOW_SPEED_FINISH"
            if s.t-self.low_speed_since>=2-1e-7 then self:stop("low_speed",true) end
        else self.low_speed_since=nil; self.phase="ROLLOUT" end
    end
    if self.file and s.t+1e-7>=self.next_sample then
        self.max_sample_gap=math.max(self.max_sample_gap,s.t-(self.last and self.last.t or self.start_time))
        self.missed_slots=self.missed_slots+math.max(0,math.floor((s.t-self.next_sample+1e-7)/.1))
        self.last=s; self.next_sample=s.t+.1
        local route_result
        if route and route.session_id and route.session_id~=self.id then route=nil end
        s.runway_heading_true=route and route.heading_true
        if self.touch_time then self:rollout_sample(s,route) end
        local values={n=#fields}; for i,key in ipairs(fields) do values[i]=s[key] end
        self:emit("T",values); self.samples=self.samples+1
        if number(s.wind_speed) and s.wind_speed>=0 and number(s.wind_from) then
            local w=self.wind or {sum=0,count=0,peak=-1}; self.wind=w
            w.sum=w.sum+s.wind_speed; w.count=w.count+1; w.last=s
            if s.wind_speed>w.peak then w.peak=s.wind_speed; w.peak_time=s.t end
            if s.t+1e-7>=self.next_wind then
                self:wind_row(); self.next_wind=s.t+math.max(.1,wind_interval or 1)
            end
        end
        if self.file then self:flush() end
    end
    self.previous=s
end
function M:bind_rollout(route)
    if not route or route.session_id~=self.id then return end
    if self.route==route and #(self.rollout_pending or {})==0 then return end
    for _,s in ipairs(self.rollout_pending or {}) do
        if s.break_segment then route:reset_segment() else route:update(s) end
    end
    self.rollout_pending={};self.route=route;self.summary_dirty=true
end
function M:rollout_sample(s,route)
    if not self.touch_time then return end
    if route and route.session_id==self.id then
        self:bind_rollout(route)
        if s.break_segment then route:reset_segment() else route:update(s) end
        self.summary_dirty=true
    else
        -- Runway matching is asynchronous (up to ~35 s). Preserve the first
        -- 60 s at 10 Hz so the initial 5-second centreline rule is observable.
        self.rollout_pending=self.rollout_pending or {}
        if #self.rollout_pending>=600 then self.rollout_pending={};self.rollout_front_missing=true end
        self.rollout_pending[#self.rollout_pending+1]={t=s.t,lat=s.lat,lon=s.lon,gs=s.gs,ground=s.ground,break_segment=s.break_segment}
    end
end
function M:shutdown()
    if self.file then self:stop("plugin_shutdown",false) end
    if self.export then self.export.source:close(); self.export.out:close(); self.export=nil; self.export_failed=true end
end
M.fields=fields
return M

-- RC3 experimental rule; not an airline QAR standard. Constant-space 10 Hz analysis.
-- Only the final low approach before FIRST ground contact is eligible.
local M={};M.__index=M
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
function M.new()
    return setmetatable({rule="flare-grade-rc3-1",window={},flat_distance=0,flat_seconds=0,
        rise_ft=0,rise_seconds=0,samples=0},M)
end
function M:break_segment()
    self.window={};self.previous=nil;self.flat=nil;self.rise=nil
end
function M:reset_approach()
    self:break_segment();self.flat_distance=0;self.flat_seconds=0;self.rise_ft=0;self.rise_seconds=0
    self.flat_time=nil;self.rise_time=nil;self.low_started=false
end
function M:update(s)
    if self.finished then return end
    if s.ground==1 then self.finished=true;self.touch_time=s.t;self:break_segment();return end
    if not finite(s.t) or not finite(s.agl) or not finite(s.gs) or s.gs<35 or s.paused or s.replay then self:break_segment();return end
    if s.agl>60 then self:reset_approach();return end
    if s.agl<=20 and s.agl>=-5 then self.low_started=true end
    if not self.low_started then return end
    if self.last_t and (s.t<=self.last_t or s.t-self.last_t>1) then self:break_segment() end
    self.last_t=s.t
    local source=finite(s.msl) and "MSL" or "AGL"
    if self.source and self.source~=source then self:break_segment() end
    self.source=source
    local height=source=="MSL" and s.msl or s.agl
    self.window[#self.window+1]=height;if #self.window>5 then table.remove(self.window,1) end
    if #self.window<5 then return end
    local sorted={};for i,v in ipairs(self.window) do sorted[i]=v end;table.sort(sorted)
    local p={t=s.t,h=sorted[3],gs=s.gs};local prev=self.previous;self.previous=p;self.samples=self.samples+1
    if not prev then return end
    local dt=p.t-prev.t;if dt<=0 or dt>1 then return end
    local fpm=(p.h-prev.h)*60/dt
    if s.agl<=20 and math.abs(fpm)<=150 then
        self.flat=self.flat or {t=prev.t,distance=0}
        self.flat.distance=self.flat.distance+(p.gs+prev.gs)*.5*.514444*dt
        local duration=p.t-self.flat.t
        if duration>=5-1e-7 and self.flat.distance>self.flat_distance then
            self.flat_distance=self.flat.distance;self.flat_seconds=duration;self.flat_time=p.t
        end
    else self.flat=nil end
    -- Terrain AGL alone can rise over sloping ground without a balloon.
    local corroborated=source=="MSL" or finite(s.physical_fpm) and s.physical_fpm>10 or finite(s.vvi) and s.vvi>10
    if fpm>5 and corroborated then
        self.rise=self.rise or {t=prev.t,h=prev.h}
        local duration=p.t-self.rise.t;local gain=p.h-self.rise.h
        if duration>=1-1e-7 and gain>=3 and gain>self.rise_ft then self.rise_ft=gain;self.rise_seconds=duration;self.rise_time=p.t end
    else self.rise=nil end
end
function M:result(usable_length,reason)
    local reliable=self.finished and finite(usable_length) and usable_length>=100 and reason~="go_around" and reason~="load_or_discontinuity" and reason~="replay"
    local limit=finite(usable_length) and math.max(300,math.min(600,usable_length*.15)) or nil
    return {rule=self.rule,eligible=reliable,limit=limit,usable_length=usable_length,
        long_float=reliable and self.flat_seconds>=5-1e-7 and self.flat_distance>limit or false,
        balloon=reliable and self.rise_ft>=3 and self.rise_seconds>=1-1e-7 or false,
        distance=self.flat_distance,seconds=self.flat_seconds,rise=self.rise_ft,rise_seconds=self.rise_seconds,
        flat_time=self.flat_time,rise_time=self.rise_time,source=self.source or "unavailable"}
end
function M.score(status,result)
    if status~="UNSTABLE" and (result.long_float or result.balloon) then return "ATTENTION" end
    return status
end
function M.describe(result,en)
    if not result.eligible then return en and "Not assessed: no reliable runway or completed approach" or "未考核：缺少可靠跑道或完整触地证据" end
    local text={}
    if result.long_float then text[#text+1]=string.format(en and "Long float %.1f s / %.0f m (limit %.0f m)" or "长平飘 %.1f 秒 / %.0f 米（门槛 %.0f 米）",result.seconds,result.distance,result.limit) end
    if result.balloon then text[#text+1]=string.format(en and "Balloon +%.1f ft / %.1f s" or "拉飘回升 +%.1f ft / %.1f 秒",result.rise,result.rise_seconds) end
    return #text>0 and table.concat(text,"; ") or (en and "No long float / balloon trigger" or "未触发长平飘或拉飘")
end
return M

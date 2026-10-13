-- O(1) centreline assessment: grounded GS >= 60 kt; each rule latches once.
local M={}; M.__index=M
local R=111195
local function finite(x) return type(x)=="number" and x==x and math.abs(x)<math.huge end
function M.new(runway,network,direction,source)
    if not runway or not finite(runway.lat1) or not finite(runway.lon1)
        or not finite(runway.lat2) or not finite(runway.lon2) then return nil end
    local self=setmetatable({runway=runway,exits={},evidence={},source=source or "",max_offset=0,
        squared=0,duration=0,swings=0,steps=0,revision=0,samples=0,max_span=0,
        longest_outside=0,longest_red=0,rule="rollout-grade-1",shadow=false},M)
    self.lat=runway.lat1; self.lon=runway.lon1; self.cos=math.cos(self.lat*math.pi/180)
    local dx=(runway.lon2-self.lon)*R*self.cos; local dy=(runway.lat2-self.lat)*R
    self.length=math.sqrt(dx*dx+dy*dy); if self.length<100 then return nil end
    self.ux,self.uy=dx/self.length,dy/self.length; self.reverse=direction==runway.end2
    self.heading_true=(math.atan2(self.ux,self.uy)*180/math.pi+(self.reverse and 180 or 0))%360
    self.width=runway.width_m
    return self
end
function M:project(lat,lon)
    local x=(lon-self.lon)*R*self.cos; local y=(lat-self.lat)*R
    local along=x*self.ux+y*self.uy; local cross=self.ux*y-self.uy*x
    if self.reverse then return self.length-along,-cross end
    return along,cross
end
function M:reset_segment()
    self.minimum=nil; self.maximum=nil; self.outside_since=nil; self.red_since=nil;self.previous=nil
end
function M:latch(kind,s,value,limit,duration)
    if self[kind] then return end
    self[kind]=true; self.revision=self.revision+1
    self.evidence[#self.evidence+1]={t=s.t,kind=kind,value=value,limit=limit,duration=duration or 0,gs=s.gs}
end
function M:update(s)
    if not finite(s.lat) or not finite(s.lon) or not finite(s.t) or not finite(s.gs) then self:reset_segment();return self end
    local along,cross=self:project(s.lat,s.lon);s.along,s.cross=along,cross
    local prev=self.previous;local dt=prev and s.t-prev.t or 0
    local contiguous=prev and dt>0 and dt<=.5
    local pos=self.position_previous;local elapsed=pos and s.t-pos.t or 0
    local backtrack=pos and elapsed>0 and elapsed<=.5 and along<pos.along-math.max(.1,elapsed*.5) or false
    self.position_previous={t=s.t,along=along}
    self.along,self.cross,self.backtrack=along,cross,backtrack
    if s.ground~=1 or s.gs<60 or backtrack then self:reset_segment();return self end
    if not contiguous then self:reset_segment() end
    -- Opposite signed samples necessarily crossed the centre band between
    -- observations; do not count that interval as continuously outside it.
    if contiguous and prev.cross*cross<0 then self.outside_since=nil;self.red_since=nil end
    local offset=math.abs(cross)
    self.samples=self.samples+1;self.max_offset=math.max(self.max_offset,offset)
    if contiguous then
        self.squared=self.squared+cross*cross*dt;self.duration=self.duration+dt
        self.rms=math.sqrt(self.squared/self.duration)
    end
    self.minimum=math.min(self.minimum or cross,cross);self.maximum=math.max(self.maximum or cross,cross)
    local span=self.maximum-self.minimum;self.max_span=math.max(self.max_span,span)
    -- Both sides must exceed 5 m. Do not sum travelled distance or repeated corrections.
    if self.minimum< -5-1e-7 and self.maximum>5+1e-7 and span>10+1e-7 then
        self:latch("lateral_swing",s,span,10);self.swings=1
    end
    if offset>5+1e-7 then self:latch("offset_5",s,offset,5) end
    if offset>7+1e-7 then self:latch("offset_7",s,offset,7) end
    -- >9 starts; <=7 cancels; 7..9 keeps the red timer running.
    if offset<=7+1e-7 then self.red_since=nil
    elseif offset>9+1e-7 then self.red_since=self.red_since or s.t end
    if self.red_since then
        local duration=s.t-self.red_since;self.longest_red=math.max(self.longest_red,duration)
        if duration>=3-1e-7 then self:latch("sustained_9",s,offset,9,duration) end
    end
    if offset>3+1e-7 then
        self.outside_since=self.outside_since or s.t
        local duration=s.t-self.outside_since;self.longest_outside=math.max(self.longest_outside,duration)
        if duration>=5-1e-7 then self:latch("outside_3",s,offset,3,duration) end
    else self.outside_since=nil end
    self.steps=(self.offset_5 and 1 or 0)+(self.lateral_swing and 1 or 0)+(self.outside_3 and 1 or 0)
    self.deviation=self.offset_5 or false;self.previous={t=s.t,along=along,cross=cross}
    return self
end
function M:score(status,applied_steps)
    local rank={NICE=1,STABLE=2,ATTENTION=3,UNSTABLE=4}
    local n=rank[status];if not n then return status end
    if self.sustained_9 or n==4 then return "UNSTABLE" end
    n=math.min(3,n+math.max(0,self.steps-(applied_steps or 0)))
    if self.offset_7 then n=3 end
    return ({"NICE","STABLE","ATTENTION"})[n]
end
function M:description(english)
    local reasons={}
    if self.lateral_swing then reasons[#reasons+1]=english and "both sides >5 m, span >10 m: one non-red step" or "左右均超过5 m且摆幅超过10 m：非红降一级" end
    if self.offset_7 then reasons[#reasons+1]=english and "offset >7 m: at least ATTENTION" or "偏差超过7 m：至少黄色"
    elseif self.offset_5 then reasons[#reasons+1]=english and "offset >5 m: one non-red step" or "偏差超过5 m：非红降一级" end
    if self.outside_3 then reasons[#reasons+1]=english and "outside +/-3 m for 5 s: one non-red step" or "连续5秒未回到正负3 m内：非红降一级" end
    if self.sustained_9 then reasons[#reasons+1]=english and "offset >9 m, not back within +/-7 m for 3 s: UNSTABLE" or "超过9 m后连续3秒未回到正负7 m内：红色" end
    return #reasons>0 and table.concat(reasons,"; ") or (english and "No rollout penalty triggered" or "未触发滑跑降级")
end
return M

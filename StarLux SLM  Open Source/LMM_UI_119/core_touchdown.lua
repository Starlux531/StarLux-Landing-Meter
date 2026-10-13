-- RC6: bounded display/event observer. No DataRefs, file I/O or navigation work.
local M={};M.__index=M
local function finite(v) return type(v)=='number' and v==v and math.abs(v)<math.huge end
local function median(a,b,c) return a+b+c-math.min(a,b,c)-math.max(a,b,c) end
local function percentile(self,lo,hi)
    local a=self.scratch;local n=0;local first,last
    for i=1,self.count do
        if self.times[i]>=lo and self.times[i]<=hi and self.values[i] then
            n=n+1;a[n]=self.values[i];first=first or self.times[i];last=self.times[i]
        end
    end
    for i=#a,n+1,-1 do a[i]=nil end
    table.sort(a)
    return n>0 and a[math.ceil(n*.75)] or nil,n,first and last-first or 0
end
function M.new()
    return setmetatable({times={},values={},scratch={},count=0,events={},serial=0,
        active=false,finalized=false,status='idle',g_text='-- G',fpm_text='-- fpm',algorithm='touchdown-rc6-1'},M)
end
function M:begin_event(t)
    self.count=0;self.stable_since=nil;self.last_capture=nil;self.air_since=nil
    self.event_count=(self.event_count or 0)+1
    self.current={index=self.event_count,start=t,peak=nil,quality='valid',max_gap=0}
    self.serial=self.serial+1
end
function M:start(t)
    self.events={};self.event_count=0;self.observed_peak=nil;self.worst_g=nil
    self.active=true;self.finalized=false;self.dismissed=false;self.status='calculating';self.summary_limited=false
    self.last_time=t;self.start_time=t;self:begin_event(t)
end
function M:finish(t,reason)
    local e=self.current;if not e or e.done then return end
    e.done=true;e.finish=t;e.reason=reason
    local fixed,n,span=percentile(self,e.start,math.min(t,e.start+.16))
    local full=percentile(self,e.start,t)
    e.fixed_g=fixed;e.g=fixed or full;e.mode='fixed';e.window_start=e.start;e.window_end=math.min(t,e.start+.16)
    if n<5 or span<.04 then e.g=full;e.mode='insufficient_fixed_window' end
    -- A median-of-three centre identifies a supported later crest. Never
    -- search unrestricted rollout or promote an isolated one-frame spike.
    local peak,pt=-math.huge,nil
    for i=2,self.count-1 do
        local a,b,c=self.values[i-1],self.values[i],self.values[i+1]
        if a and b and c and self.times[i+1]<=t then local v=median(a,b,c);if v>peak then peak,pt=v,self.times[i] end end
    end
    if fixed and n>=5 and span>=.04 and pt and pt>e.start+.16 and peak>fixed+.05
        and e.max_gap<=.05 and e.quality=='valid' then
        local lo,hi=math.max(e.start,pt-.08),math.min(t,pt+.08)
        local candidate,cn,cs=percentile(self,lo,hi)
        local run,best=0,0
        for i=2,self.count do
            local dt=self.times[i]-self.times[i-1]
            if self.times[i]<=t and self.values[i] and self.values[i-1] and self.values[i]>fixed+.05 and self.values[i-1]>fixed+.05 and dt<=.05 then
                run=run+dt;best=math.max(best,run)
            else run=0 end
        end
        if candidate and candidate>fixed+.05 and cn>=5 and cs>=.08 and best>=.08
            and ((e.max_vy or -math.huge)-(e.start_vy or math.huge)>.1 or (e.max_height or 0)-(e.min_height or 0)>.15) then
            e.g=candidate;e.mode='delayed';e.window_start=lo;e.window_end=hi
        end
    end
    if e.max_gap>.05 then e.quality='sample_gaps' end
    if reason=='limit' or reason=='interrupted' then e.quality=reason end
    if e.g then e.g=math.max(1,math.min(5,e.g));self.worst_g=math.max(self.worst_g or 1,e.g) end
    -- Retain bounded summaries, not raw histories for every bounce.
    if #self.events<64 then self.events[#self.events+1]=e else self.summary_limited=true end
    self.serial=self.serial+1;self.status='monitoring'
end
function M:update(t,g,vy,pitch,roll,ground,height,paused)
    -- Simulator time normally freezes on pause. A clock jump while paused is
    -- an interruption, not evidence of a long compression event.
    if paused then return end
    local valid=finite(g) and g>.2 and g<=5 and finite(pitch) and finite(roll)
    local projected=valid and g*math.cos(pitch*math.pi/180)*math.cos(roll*math.pi/180) or nil
    self.pitch,self.roll=pitch,roll
    self.live_g=projected;self.live_fpm=finite(vy) and vy*196.850394 or nil
    local qg=projected and math.floor(projected*100+.5);local qf=self.live_fpm and math.floor(self.live_fpm+.5)
    if qg~=self.qg then self.qg=qg;self.g_text=qg and string.format('%.2f G',qg/100) or '-- G' end
    if qf~=self.qf then self.qf=qf;self.fpm_text=qf and string.format('%+d fpm',qf) or '-- fpm' end
    if not self.active then return end
    if self.last_time and (t<self.last_time or t-self.last_time>1) then self:finish(self.last_time,'interrupted');self:close(false);return end
    self.last_time=t
    local e=self.current;if not e or e.done then return end
    if finite(vy) then e.start_vy=e.start_vy or vy;e.max_vy=math.max(e.max_vy or vy,vy) end
    if finite(height) then e.min_height=math.min(e.min_height or height,height);e.max_height=math.max(e.max_height or height,height) end
    if projected then e.peak=math.max(e.peak or projected,projected);self.observed_peak=math.max(self.observed_peak or projected,projected)
    else e.quality='invalid_samples' end
    if not self.last_capture or t-self.last_capture>=1/240-1e-7 then
        if self.last_capture then e.max_gap=math.max(e.max_gap,t-self.last_capture) end
        if self.count<1024 then
            self.count=self.count+1;self.times[self.count]=t;self.values[self.count]=projected or false
        else e.quality='buffer_limit' end
        self.last_capture=t
    end
    if finite(vy) and vy>=-.05 then self.stable_since=self.stable_since or t else self.stable_since=nil end
    if ground==0 then self.air_since=self.air_since or t else self.air_since=nil end
    if t-e.start>=.16 and self.air_since and t-self.air_since>=.06 then self:finish(self.air_since,'airborne')
    elseif t-e.start>=.16 and self.stable_since and t-self.stable_since>=.06 then self:finish(t,'velocity_settled')
    elseif t-e.start>=3 then self:finish(t,'limit') end
end
function M:close(complete)
    if self.active then self:finish(self.last_time or self.start_time,'interrupted') end
    self.active=false;self.finalized=true;self.status=complete and 'complete' or 'incomplete';self.serial=self.serial+1
end
local red,yellow={1,.24,.24},{1,.78,.15}
function M.tone(value,is_fpm)
    if not finite(value) then return nil end
    local severity=is_fpm and math.max(0,-value) or value
    if severity>(is_fpm and 300 or 1.8) then return red end
    if severity>(is_fpm and 250 or 1.5) then return yellow end
end
return M

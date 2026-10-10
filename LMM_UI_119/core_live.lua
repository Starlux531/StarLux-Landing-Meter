-- RC8 presentation only: existing samples in, no DataRefs, grading or file I/O.
local M={};M.__index=M
local function finite(v)return type(v)=='number' and v==v and math.abs(v)<math.huge end
local names={{'VVI','VVI'},{'物理','Physical'},{'AGL估算','AGL estimate'}}
function M.new()
    return setmetatable({values={},quantized={},texts={},lines_en={},lines_zh={},state='idle'},M)
end
function M:update(t,vvi,physical,agl,paused,replay,identity)
    if replay or identity~=self.identity or self.time and (t<self.time or t-self.time>1) then
        self.anchor=nil;self.estimate=nil
    end
    self.identity=identity;self.time=t;self.paused=paused
    if paused or replay then self.anchor=nil;self.estimate=nil end
    if not paused and not replay and finite(agl) then
        local a=self.anchor
        if not a then self.anchor={t=t,h=agl}
        elseif t-a.t>=.1 then
            self.estimate=t-a.t<=.5 and (agl-a.h)*60/(t-a.t) or nil
            a.t=t;a.h=agl
        end
    elseif not finite(agl) then self.anchor=nil;self.estimate=nil end
    if replay then vvi,physical=nil,nil end
    local values=self.values
    values[1]=finite(vvi) and vvi or nil;values[2]=finite(physical) and physical or nil;values[3]=self.estimate
    for i=1,3 do
        local q=values[i] and math.floor(values[i]+.5) or false
        if self.quantized[i]~=q then
            self.quantized[i]=q;self.texts[i]=q and string.format('%+d fpm',q) or '--'
            self.lines_en[i]=self:label(i,true)..' '..self.texts[i]..(not q and ' / unavailable' or '')
            self.lines_zh[i]=self:label(i,false)..' '..self.texts[i]..(not q and ' / 不可用' or '')
        end
    end
end
function M:label(i,en)return (names[i] or {'来源未记录','Source unrecorded'})[en and 2 or 1] end
function M:line(i,en)
    return (en and self.lines_en or self.lines_zh)[i] or self:label(i,en)..(en and ' -- / unavailable' or ' -- / 不可用')
end
function M:reserve(i,en)return self:label(i,en)..' -99999 fpm / '..(en and 'unavailable' or '不可用') end
function M:selected(cfg)
    local mask=(cfg.fpm_vvi and 1 or 0)+(cfg.fpm_physical and 2 or 0)+(cfg.fpm_agl and 4 or 0)
    if mask~=self.mask then
        self.mask=mask;self.selection={}
        for i=1,3 do if math.floor(mask/2^(i-1))%2==1 then self.selection[#self.selection+1]=i end end
    end
    return self.selection
end
function M:sync(rec,td,complete,t,replay)
    if replay then self.state='idle';self.session=nil;self.result_at=nil;self.touch=nil;self.event=nil;return end
    if rec.file and not rec.done and rec.id~=self.session then
        self.session=rec.id;self.started_at=t;self.state='recording';self.result_at=nil
        self.touch=nil;self.event=nil;self.frozen_lines=nil
        self.dismissed=false;td.dismissed=false
        -- Presentation must never reset the touchdown observer. Remember a
        -- previous completed landing so it cannot finalize this new session.
        self.finished_touch=td.start_time
        if td.active then self.finished_touch=nil end
        return 'started'
    end
    -- Touchdown capture ends independently of the rollout/bounce monitor.
    -- A later confirmed bounce starts a new bounded capture, not an endless
    -- live view of taxi loads. Keep user dismissal until the next recording.
    if td.active and (td.start_time~=self.finished_touch or self.touch==td.start_time) and td.current and
        (self.touch~=td.start_time or self.event~=td.current.index) then
        self.touch=td.start_time;self.event=td.current.index;self.state='touchdown'
        self.result_at=nil;self.frozen_lines=nil
        return 'touchdown'
    end
    if self.state=='touchdown' and td.current and td.current.done and not self.frozen_lines then
        self.frozen_lines={en={},zh={}}
        for i=1,3 do self.frozen_lines.en[i]=self:line(i,true);self.frozen_lines.zh[i]=self:line(i,false) end
    end
    if complete and (self.state=='touchdown' and td.current and td.current.done
        or td.finalized and not td.active and td.status=='complete' and td.start_time~=self.finished_touch) then
        self.state='complete';self.result_at=t;self.finished_touch=td.start_time
        return 'complete'
    end
    if self.state=='touchdown' and td.finalized and not td.active and td.status=='incomplete' then
        self.state='interrupted';self.interrupted_at=t;return 'interrupted'
    end
    if (self.state=='recording' or self.state=='calculating') and not rec.file and td.active then self.state='calculating' end
    if (self.state=='recording' or self.state=='calculating') and not rec.file and not td.active
        and (rec.done or rec.phase=='INCOMPLETE') then
        self.state='interrupted';self.interrupted_at=t;return 'interrupted'
    end
end
function M:pending()
    return self.state=='touchdown' and not self.dismissed
end
function M:compact(t)
    return not self.dismissed and (self.state=='recording' or self.state=='calculating' or self.state=='interrupted' and t-(self.interrupted_at or t)<3)
end
function M:result_lit(t)
    local dt=self.result_at and t-self.result_at
    return not dt or dt<0 or dt>=2 or math.floor(dt/.5)%2==1
end
return M

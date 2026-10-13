-- RC9 bounded cooperative background work. Never changes flight sampling.
local M={};M.__index=M
local background={report_build=true,report_write=true,export=true,context=true}
local clock,clock_kind=os.clock,'cpu_fallback'
do
    local ok,ffi=pcall(require,'ffi')
    if ok and ffi.os=='Windows' then
        pcall(function()
            ffi.cdef('int QueryPerformanceCounter(int64_t *); int QueryPerformanceFrequency(int64_t *);')
            local k=ffi.load('kernel32');local f=ffi.new('int64_t[1]');local t=ffi.new('int64_t[1]')
            assert(k.QueryPerformanceFrequency(f)~=0)
            local frequency=tonumber(f[0])
            clock=function()k.QueryPerformanceCounter(t);return tonumber(t[0])/frequency end
            clock_kind='wall_qpc'
        end)
    end
end
function M.new(timer)
    return setmetatable({clock=timer or clock,clock_kind=timer and 'test' or clock_kind,
        stats={},budget=.0003,bytes=4096,rows=16,protected_until=0},M)
end
function M:begin_frame(t,period,critical)
    if self.time and t<self.time then self.protected_until=0;self.slow_until=0 end
    self.time=t
    if critical then self.protected_until=t+.5 end
    period=tonumber(period) or 0
    if period<=0 or period>1 then period=1/30 end
    self.period=self.period and self.period+(period-self.period)*(period>self.period and .3 or .04) or period
    local p=math.max(period,self.period)
    self.budget=p>1/30 and .00025 or p>1/50 and .0004 or .0007
    self.bytes=p>1/30 and 8192 or p>1/50 and 16384 or 32768
    self.rows=p>1/30 and 16 or p>1/50 and 32 or 48
    if t<(self.slow_until or 0) then self.bytes=1024;self.rows=4;self.budget=.0001 end
    self.used=0;self.claimed=false
end
function M:claim()
    if self.claimed or (self.time or 0)<self.protected_until or (self.used or 0)>=self.budget then return false end
    self.claimed=true;return true
end
function M:record(name,started)
    local elapsed=math.max(0,self.clock()-started)
    local s=self.stats[name]
    if not s then s={count=0,total=0,max=0,bins={0,0,0,0,0,0}};self.stats[name]=s end
    s.count=s.count+1;s.total=s.total+elapsed;s.max=math.max(s.max,elapsed)
    local i=elapsed<.0001 and 1 or elapsed<.0005 and 2 or elapsed<.001 and 3 or elapsed<.002 and 4 or elapsed<.005 and 5 or 6
    s.bins[i]=s.bins[i]+1
    -- Flight analysis and drawing have their own timing diagnostics. They must
    -- not consume the small background allowance or keep exports throttled.
    if background[name] then
        if elapsed>.002 then self.slow_until=(self.time or 0)+.5 end
        self.used=(self.used or 0)+elapsed
    end
    return elapsed
end
function M:page_chunk(pages,page,offset)
    local parts,bytes={},0
    -- Coalesce tiny/4 KiB report pages within the same bounded I/O slice.
    -- Cap page count as well as bytes, including empty-page inputs.
    for _=1,8 do
        local value=pages[page];if not value then break end
        local part=value:sub(offset,offset+self.bytes-bytes-1)
        parts[#parts+1]=part;bytes=bytes+#part;offset=offset+#part
        if offset>#value then page=page+1;offset=1 end
        if bytes>=self.bytes then break end
    end
    return table.concat(parts),page,offset
end
function M:diagnostic()
    local out={'RC9 PERF '..self.clock_kind}
    for _,key in ipairs({'update','analysis','popup','popup_draw','layout','report_build','report_write','export','context'}) do
        local s=self.stats[key]
        if s then
            local sum,p95=0,'>5'
            for i,n in ipairs(s.bins)do sum=sum+n;if sum>=s.count*.95 then p95=({'0.1','0.5','1','2','5','>5'})[i];break end end
            out[#out+1]=string.format('%s n=%d avg=%.3fms p95_bucket=%sms max=%.3fms',key,s.count,s.total/s.count*1000,p95,s.max*1000)
        end
    end
    return table.concat(out,' | ')
end
-- Generation yields between individual report writes. Keep bounded pages,
-- rather than concatenating the entire report in one frame.
function M:build(builder,path,revision)
    local task={revision=revision,pages={},pending={},bytes=0,total=0,writes=0}
    local function page()
        if task.bytes>0 then task.pages[#task.pages+1]=table.concat(task.pending);task.pending={};task.bytes=0 end
    end
    local function sink(value)
        local offset=1
        while offset<=#value do
            local part=value:sub(offset,offset+math.min(4096-task.bytes,#value-offset+1)-1)
            task.pending[#task.pending+1]=part;task.bytes=task.bytes+#part;task.total=task.total+#part;offset=offset+#part
            if task.bytes>=4096 then page() end
            task.writes=task.writes+1
            if task.writes>=self.rows or self.clock()-task.started>=self.budget then coroutine.yield();task.writes=0 end
        end
    end
    task.thread=coroutine.create(function()
        local ok,result=builder(path,sink)
        if not ok then error(result) end
        page();result.content=task.pages;result.length=task.total
        return result
    end)
    return task
end
function M:step(task)
    task.started=self.clock()
    local ok,result=coroutine.resume(task.thread)
    local elapsed=self:record('report_build',task.started)
    task.elapsed=(task.elapsed or 0)+elapsed
    if not ok then return 'error',result end
    if coroutine.status(task.thread)=='dead' then result.build_ms=task.elapsed*1000;return 'done',result end
    return 'pending'
end
return M

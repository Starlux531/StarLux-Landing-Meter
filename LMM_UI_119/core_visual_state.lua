-- Read-only visual telemetry. Never changes aircraft controls or recorded pilot inputs.
local M={};M.__index=M
local specs={
    bank={"sim/flightmodel/position/phi",2},reverse={"sim/flightmodel2/engines/thrust_reverser_deploy_ratio",8},
    propmode={"sim/flightmodel/engine/ENGN_propmode",16},replay={"sim/time/is_in_replay",1}}
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
function M.new()
    return setmetatable({handles={},reverse={},next_probe=0},M)
end
function M:probe(now)
    for key,s in pairs(specs) do
        if not self.handles[key] then
            local ok,h=pcall(XPLMFindDataRef,s[1])
            if ok and h then
                local good,t=pcall(XPLMGetDataRefTypes,h)
                if good and type(t)=="number" and math.floor(t/s[2])%2==1 then self.handles[key]=h end
            end
        end
    end
    self.next_probe=now+2
end
function M:read(key)
    local h=self.handles[key];if not h then return nil end
    local fn=specs[key][2]==1 and XPLMGetDatai or XPLMGetDataf
    local ok,v=pcall(fn,h);if ok and finite(v) then return v end
end
function M:update(now,identity,config,debug,count)
    for i=1,4 do self.reverse[i]=nil end
    local reset=identity~=self.identity or (self.last and (now<self.last or now-self.last>1))
    if reset then self.handles={};self.next_probe=now end
    self.identity,self.last=identity,now
    local stick=config.stick or debug;local n1=config.n1
    if not stick and not n1 then
        self.bank=nil;return
    end
    if now>=self.next_probe then self:probe(now) end
    if self:read('replay')==1 then self.bank=nil;return end
    if stick then
        self.bank=self:read('bank');if self.bank and math.abs(self.bank)>360 then self.bank=nil end
    else self.bank=nil end
    if n1 then
        local function array(key,fn)
            if not self.handles[key] then return nil end
            local ok,v=pcall(fn,self.handles[key],0,math.min(4,count or 0))
            if ok and type(v)=="table" then return v end
        end
        local doors,modes=array('reverse',XPLMGetDatavf),array('propmode',XPLMGetDatavi)
        for i=1,4 do
            local present=i<=(count or 0)
            local d=present and doors and doors[doors[0]~=nil and i-1 or i]
            local m=present and modes and modes[modes[0]~=nil and i-1 or i]
            local dv=finite(d) and d>=0 and d<=1;local mv=finite(m) and m>=0 and m<=3
            if dv or mv then self.reverse[i]=(dv and d>.01) or (mv and m==3) or false else self.reverse[i]=nil end
        end
    end
end
return M

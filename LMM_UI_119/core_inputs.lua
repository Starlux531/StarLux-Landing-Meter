-- Read-only input observation. Zero is a valid input; source changes never rewrite samples.
local M = {}; M.__index = M
local axes = {"pitch", "roll", "yaw"}
local function finite(n) return type(n)=="number" and n==n and math.abs(n)<math.huge end
function M.new(specs, api)
    local self=setmetatable({axes={},api=api,now=0,next_probe=0,sequence=0,events={},identity="",profiles={}},M)
    for _,axis in ipairs(axes) do
        local a={mode="auto",candidates={},value=0,valid=false,status="unavailable"}; self.axes[axis]=a
        for _,c in ipairs(specs[axis].candidates) do
            a.candidates[#a.candidates+1]={id=c.id,path=c.path,status="unavailable",spec=c}
        end
    end
    return self
end
function M:event(axis,old,new,reason)
    self.sequence=self.sequence+1
    self.events[#self.events+1]={seq=self.sequence,t=self.now,axis=axis,old=old or "",source=new or "",mode=self.axes[axis].mode,reason=reason}
    if #self.events>256 then table.remove(self.events,1) end -- UI history; recorder drains every observation
end
function M:probe()
    for _,axis in ipairs(axes) do
        for _,c in ipairs(self.axes[axis].candidates) do
            local ok,h=pcall(self.api.find,c.path)
            c.handle=ok and h or nil
            c.type_ok=true
            if c.handle and self.api.types then
                local good,kind=pcall(self.api.types,c.handle)
                c.type_ok=good and type(kind)=="number" and math.floor(kind/2)%2==1
            end
            c.status=not c.handle and "missing" or not c.type_ok and "type" or "waiting"
        end
    end
    self.next_probe=self.now+2
end
function M:set_custom(axis,path)
    local a=self.axes[axis]
    if not a or type(path)~="string" or #path>240 or not path:match("^[%w_./%-]+$") then return false end
    for i=#a.candidates,1,-1 do if a.candidates[i].id=="custom" then table.remove(a.candidates,i) end end
    a.candidates[#a.candidates+1]={id="custom",path=path,status="waiting"}
    self.next_probe=0; return true
end
function M:select(axis,id)
    local a=self.axes[axis]; if not a then return false end
    local candidate
    for _,c in ipairs(a.candidates) do if c.id==id then candidate=c end end
    if id~="auto" and (not candidate or not candidate.valid) then return false end
    local old=a.selected and a.selected.id
    a.mode=id
    if candidate then a.selected=candidate; a.value=candidate.value; a.valid=true end
    self:event(axis,old,candidate and candidate.id or old,"selection")
    return true
end
function M:set_identity(identity)
    if identity==self.identity then return end
    self.identity=identity
    for _,axis in ipairs(axes) do
        local a=self.axes[axis]; local old=a.selected and a.selected.id
        a.selected=nil; a.mode="auto"; a.valid=false
        for i=#a.candidates,1,-1 do
            local c=a.candidates[i]
            if c.id=="custom" then table.remove(a.candidates,i)
            else c.handle=nil; c.raw=nil; c.activity_anchor=nil; c.valid=false; c.changed_at=nil; c.status="waiting" end
        end
        local p=self.profiles[identity] and self.profiles[identity][axis]
        if p then if p.path then self:set_custom(axis,p.path) end; a.mode=p.mode end
        self:event(axis,old,nil,"aircraft")
    end
    self.next_probe=0
end
function M:update(now)
    if now<self.now then
        for _,a in pairs(self.axes) do for _,c in ipairs(a.candidates) do c.changed_at=nil; c.raw=nil; c.activity_anchor=nil end end
        self.next_probe=0
    end
    self.now=now
    if now>=self.next_probe then self:probe() end
    for _,axis in ipairs(axes) do
        local a=self.axes[axis]; local first,active
        for _,c in ipairs(a.candidates) do
            local ok,v=false,nil
            if c.handle and c.type_ok then ok,v=pcall(self.api.read,c.handle) end
            v=tonumber(v)
            c.valid=ok and finite(v) and math.abs(v)<=1.5
            c.status=not c.handle and "missing" or not c.type_ok and "type" or not ok and "read_error"
                or not c.valid and "range" or "valid"
            if c.valid then
                if c.activity_anchor and math.abs(v-c.activity_anchor)>=0.006 then c.changed_at=now; c.activity_anchor=v end
                if not c.activity_anchor then c.activity_anchor=v end
                c.raw=v; c.value=math.max(-1,math.min(1,v))
                first=first or c
                if c.changed_at and now-c.changed_at<=0.75 then active=active or c end
            end
        end
        local old=a.selected; local selected
        if a.mode=="auto" then
            selected=old and old.valid and old or first
            if active and (not selected or not selected.changed_at or now-selected.changed_at>0.75) then selected=active end
        else
            for _,c in ipairs(a.candidates) do if c.id==a.mode then selected=c end end
        end
        a.selected=selected; a.valid=selected~=nil and selected.valid or false
        a.value=a.valid and selected.value or 0
        a.status=selected and selected.status or "unavailable"
        if old~=selected then self:event(axis,old and old.id,selected and selected.id,"auto_resolve") end
    end
end
function M:capture(slot)
    for _,axis in ipairs(axes) do
        local a=self.axes[axis]
        for _,c in ipairs(a.candidates) do
            slot[axis.."_raw_"..c.id]=c.valid and c.raw or nil
        end
        slot[axis.."_input_ratio"]=a.value
        slot[axis.."_input_valid"]=a.valid
        slot[axis.."_input_source"]=a.selected and a.selected.path or ""
        slot[axis.."_input_mode"]=a.mode
    end
    slot.input_sequence=self.sequence
end
function M:remember_profile()
    local profile={}
    for _,axis in ipairs(axes) do
        local a=self.axes[axis]; profile[axis]={mode=a.mode}
        for _,c in ipairs(a.candidates) do if c.id=="custom" then profile[axis].path=c.path end end
    end
    self.profiles[self.identity]=profile
end
function M:write_profiles(file)
    local index=0
    for identity,p in pairs(self.profiles) do
        if not identity:find("[\t\r\n]") then
            for _,axis in ipairs(axes) do
                local v=p[axis]
                if v then
                    index=index+1
                    file:write("live_profile_"..index.."="..identity.."\t"..axis.."\t"..v.mode.."\t"..(v.path or "-").."\n")
                end
            end
        end
    end
end
function M:read_profile(line)
    local id,axis,mode,custom=line:match("^([^\t]+)\t(%w+)\t([%w_]+)\t(.*)$")
    if id and self.axes[axis] and (mode=="auto" or mode=="joystick" or mode=="cockpit" or mode=="flight_control" or mode=="custom") then
        self.profiles[id]=self.profiles[id] or {}
        self.profiles[id][axis]={mode=mode,path=custom~="-" and custom or nil}
    end
end
return M

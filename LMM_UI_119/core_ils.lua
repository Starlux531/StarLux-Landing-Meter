-- Geometric ILS reference, independent of tuned radios and receiver needles.
-- Sources: https://developer.x-plane.com/sdk/XPLMNavigation/
-- https://developer.x-plane.com/wp-content/uploads/2020/03/XP-NAV1150-Spec.pdf
-- https://developer.x-plane.com/article/navdata-in-x-plane-11/
-- SDK outHeight units / GS outHeading encoding are not specified by the public
-- API contract. Never interpret those as metres or a default 3-degree slope.
-- Read explicit GS angle and feet-MSL elevation from the active text layers;
-- corroborate type, exact ID, frequency and transmitter location with the SDK.
local M={}; M.__index=M
local DEG=math.pi/180
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<math.huge end
local function position(lat,lon) return finite(lat) and finite(lon) and math.abs(lat)<=90 and math.abs(lon)<=180 end
local function upper(v) return tostring(v or ""):upper():match("^%s*(.-)%s*$") end
local function wrap(v) return (v+180)%360-180 end
local function runway(v)
    local n,s=upper(v):gsub("^RWY?",""):match("^(%d%d?)([LRC]?)$")
    n=tonumber(n); if not n or n<1 or n>36 then return nil end
    return string.format("%02d%s",n,s)
end
local function xy(lat,lon,rlat,rlon)
    return wrap(lon-rlon)*111195*math.cos(rlat*DEG),(lat-rlat)*111195
end
local function project(lat,lon,rlat,rlon,course)
    local e,n=xy(lat,lon,rlat,rlon); local c,s=math.cos(course*DEG),math.sin(course*DEG)
    return n*c+e*s,e*c-n*s,math.sqrt(e*e+n*n)
end
local function base(status,airport,rwy)
    return {ils_version=1,ils_model="geometric_reference",ils_source="xp_navdata_sdk_verified",
        ils_status=status,ils_airport=airport,ils_runway=rwy,ils_scale_source="reference",
        ils_loc_deg_per_dot=1.25,ils_gs_deg_per_dot=.35,ils_max_range_nm=18,ils_max_sector_deg=35}
end
M.meta_keys={"ils_version","ils_model","ils_source","ils_status","ils_airport","ils_runway",
    "ils_loc_id","ils_loc_lat","ils_loc_lon","ils_loc_course_true","ils_loc_frequency_mhz",
    "ils_gs_lat","ils_gs_lon","ils_gs_elevation_m","ils_gs_angle_deg","ils_scale_source",
    "ils_loc_deg_per_dot","ils_gs_deg_per_dot","ils_max_range_nm","ils_max_sector_deg",
    "ils_loc_source_path","ils_gs_source_path","ils_gs_status","ils_selection"}

-- Exact JS parity: equirectangular transmitter-origin coordinates, no earth
-- curvature/refraction, raw/unclamped dots, aircraft MSL in feet, nav MSL in m.
function M.geometry(ref,s,out)
    out=out or {}; out.reference=ref; out.status=ref and ref.ils_status or "pending"
    out.loc_valid=false; out.gs_valid=false; out.loc_dots=nil; out.gs_dots=nil
    out.loc_error_deg=nil; out.gs_error_deg=nil
    if not ref or s.ground~=0 or s.replay or not position(s.lat,s.lon)
        or not position(ref.ils_loc_lat,ref.ils_loc_lon) or not finite(ref.ils_loc_course_true) then return out end
    local f,r,d=project(s.lat,s.lon,ref.ils_loc_lat,ref.ils_loc_lon,ref.ils_loc_course_true)
    local error=math.atan2(r,-f)/DEG
    if f>=0 or d<=1 or d>18*1852 or math.abs(error)>35 then return out end
    out.loc_valid=true; out.loc_error_deg=error; out.loc_dots=-error/1.25
    if not position(ref.ils_gs_lat,ref.ils_gs_lon) or not finite(ref.ils_gs_elevation_m)
        or not finite(ref.ils_gs_angle_deg) or not finite(s.msl) then return out end
    f,r,d=project(s.lat,s.lon,ref.ils_gs_lat,ref.ils_gs_lon,ref.ils_loc_course_true)
    if f>=0 or d<=1 or d>18*1852 then return out end
    out.gs_error_deg=ref.ils_gs_angle_deg-math.atan2(s.msl*.3048-ref.ils_gs_elevation_m,d)/DEG
    out.gs_valid=true; out.gs_dots=out.gs_error_deg/.35
    return out
end

-- Row 4/5 bearings in NAV1150/1200 include integer magnetic course*360.
-- GS: hundredths of angle*1000 + true bearing (325123.456 => 3.25,123.456).
function M.parse(line,version,path)
    if version~=1100 and version~=1150 and version~=1200 then return nil end
    if not line:match("^%s*[456]%s") then return nil end
    local f={}; for v in line:gmatch("%S+") do f[#f+1]=v end
    local kind=tonumber(f[1]); local lat,lon=tonumber(f[2]),tonumber(f[3])
    local elev,freq,packed=tonumber(f[4]),tonumber(f[5]),tonumber(f[7])
    local rwy=runway(f[11]); local airport=upper(f[9]); local id=upper(f[8])
    if not position(lat,lon) or not finite(elev) or not finite(freq) or freq<10800 or freq>11200
        or not finite(packed) or packed<0 or not rwy or airport=="" or airport=="ENRT" or id=="" then return nil end
    local course,angle
    if kind==6 then
        angle=math.floor(packed/1000)/100; course=packed%1000
        if angle<=0 or angle>10 or course>=360 then return nil end
    else course=packed%360 end
    return {kind=kind,lat=lat,lon=lon,elevation_m=elev*.3048,frequency=freq,course=course,
        angle=angle,id=id,airport=airport,region=upper(f[10]),runway=rwy,path=path}
end
local function navkey(n) return n.kind..":"..n.id..":"..n.airport..":"..n.region end
local function targetkey(t) return t and (t.airport..":"..t.runway..":"..string.format("%.4f:%.6f:%.6f",t.course,t.lat,t.lon)) end

function M.new(options)
    options=options or {}
    return setmetatable({root=(options.root or ""):gsub("[/\\]+$","").."/",api=options.api or _G,
        open=options.open or io.open,records={},index={},cache={},stats={bytes=0,steps=0,queries=0,selections=0},
        runtime={loc_valid=false,gs_valid=false,status="pending"},state="pending",next_scan=0,next_select=0},M)
end
function M:exists(path)
    local f=self.open(self.root..path,"rb"); if not f then return false end; f:close(); return true
end
function M:initialize()
    -- ARINC layers can override angles without moving a transmitter. Coordinate
    -- agreement alone cannot verify a text GS in these installations.
    if self:exists("Custom Data/earth_424.dat") or self:exists("Custom Data/FAACIFP18") then
        self.state="unsupported_arinc_override"; return
    end
    self.paths={self:exists("Custom Data/earth_nav.dat") and "Custom Data/earth_nav.dat" or "Resources/default data/earth_nav.dat"}
    if self:exists("Global Scenery/Global Airports/Earth nav data/earth_nav.dat") then
        self.paths[#self.paths+1]="Global Scenery/Global Airports/Earth nav data/earth_nav.dat"
    elseif self:exists("Custom Scenery/Global Airports/Earth nav data/earth_nav.dat") then
        self.paths[#self.paths+1]="Custom Scenery/Global Airports/Earth nav data/earth_nav.dat"
    end
    if self:exists("Custom Data/user_nav.dat") then self.paths[#self.paths+1]="Custom Data/user_nav.dat" end
    self.path_index=0; self.state="loading"; self.count=0
end
function M:close()
    if self.file then self.file:close(); self.file=nil end
end
function M:scan(now)
    if now<self.next_scan then return end
    self.next_scan=now+.05
    if self.state=="pending" then self:initialize() end
    if self.state~="loading" then return end
    self.stats.steps=self.stats.steps+1
    if not self.file then
        self.path_index=self.path_index+1
        if self.path_index>#self.paths then self.records={}; self.state="ready"; self.next_select=0; return end
        self.path=self.root..self.paths[self.path_index]
        self.file=self.open(self.path,"rb")
        if not self.file then self.state="navdata_unavailable"; return end
        self.buffer=""; self.line_number=0; self.version=nil; self.eof=false
    end
    -- One fixed-size read per 50 ms; 256 KiB total buffer cap for malformed data.
    local chunk
    if not self.eof and #self.buffer<32768 then
        chunk=self.file:read(32768)
        if not chunk then self.eof=true; chunk="\n" end
    end
    self.stats.bytes=self.stats.bytes+(chunk and #chunk or 0)
    self.buffer=self.buffer..(chunk or "")
    if #self.buffer>262144 then self:close(); self.state="navdata_limit"; return end
    local consumed=0
    for _=1,512 do
        local last=self.buffer:find("\n",consumed+1,true); if not last then break end
        local line=self.buffer:sub(consumed+1,last-1); consumed=last; self.line_number=self.line_number+1
        if self.line_number==2 then
            self.version=tonumber(line:match("^%s*(%d+)%s+Version"))
            if self.version~=1100 and self.version~=1150 and self.version~=1200 then
                self:close(); self.state="unsupported_navdata"; return
            end
        end
        local n=M.parse(line,self.version,self.path)
        if n then
            local key=navkey(n)
            local old=self.records[key]
            if not old then self.count=self.count+1
            else self.index[old.airport..":"..old.runway][key]=nil end
            self.records[key]=n
            local target=n.airport..":"..n.runway
            self.index[target]=self.index[target] or {}; self.index[target][key]=n
            if self.count>60000 then self:close(); self.state="navdata_limit"; return end
        end
    end
    self.buffer=self.buffer:sub(consumed+1)
    if self.eof and self.buffer:match("^%s*$") then self:close() end
end

function M:verify(n)
    if type(self.api.XPLMFindNavAid)~="function" or type(self.api.XPLMGetNavAidInfo)~="function" then return false end
    self.stats.queries=self.stats.queries+1
    local typ=n.kind==4 and 8 or n.kind==5 and 16 or 32
    local ok,ref=pcall(self.api.XPLMFindNavAid,nil,n.id,n.lat,n.lon,n.frequency,typ)
    if not ok or not finite(ref) or ref<0 then return false end
    local got,k,lat,lon,_,freq,course,id=pcall(self.api.XPLMGetNavAidInfo,ref)
    if not got or k~=typ or upper(id)~=n.id or freq~=n.frequency or not position(lat,lon) then return false end
    local e,no=xy(lat,lon,n.lat,n.lon)
    if e*e+no*no>15*15 then return false end
    -- Float roundoff in the SDK can lose some of the packed bearing precision.
    if n.kind~=6 and (not finite(course) or math.abs(wrap(course%360-n.course))>.1) then return false end
    return true
end
function M:resolve(t)
    local key=targetkey(t); if self.cache[key] then return self.cache[key] end
    local ref=base("no_ils",t.airport,t.runway)
    if self.state~="ready" then ref.ils_status=self.state; return ref end
    local candidates={}; local records=self.index[t.airport..":"..t.runway] or {}
    for _,n in pairs(records) do
        if n.kind~=6 and math.abs(wrap(n.course-t.course))<=10 then
            local f,r,d=project(n.lat,n.lon,t.lat,t.lon,t.course)
            if f>0 and d<=15000 and math.abs(r)<=1500 then candidates[#candidates+1]=n end
        end
    end
    if #candidates>1 then ref.ils_status="ambiguous_localizer"
    elseif #candidates==1 then
        local loc=candidates[1]
        if not self:verify(loc) then ref.ils_status="sdk_mismatch"
        else
            ref.ils_status="loc_only"; ref.ils_loc_id=loc.id; ref.ils_loc_lat=loc.lat; ref.ils_loc_lon=loc.lon
            ref.ils_loc_course_true=loc.course; ref.ils_loc_frequency_mhz=loc.frequency/100; ref.ils_loc_source_path=loc.path
            ref.ils_gs_status="unavailable"
            local gs={}
            if loc.kind==4 then
                for _,n in pairs(records) do
                    if n.kind==6 and n.id==loc.id and n.region==loc.region and n.frequency==loc.frequency
                        and math.abs(wrap(n.course-loc.course))<=.1 then
                        local f,r,d=project(n.lat,n.lon,t.lat,t.lon,t.course)
                        if f>=-300 and f<=math.max(2000,t.length or 0) and d<=10000 and math.abs(r)<=1000 then gs[#gs+1]=n end
                    end
                end
            end
            if #gs==1 and self:verify(gs[1]) then
                local n=gs[1]; ref.ils_status="ils"; ref.ils_gs_status="verified"
                ref.ils_gs_lat=n.lat; ref.ils_gs_lon=n.lon; ref.ils_gs_angle_deg=n.angle
                ref.ils_gs_elevation_m=n.elevation_m; ref.ils_gs_source_path=n.path
            elseif #gs>0 then ref.ils_gs_status="sdk_mismatch_or_ambiguous" end
        end
    end
    self.cache_count=(self.cache_count or 0)+1
    if self.cache_count>128 then self.cache={}; self.cache_count=1 end
    self.cache[key]=ref; return ref
end

function M.target(airport,r,direction)
    if not r or not position(r.lat1,r.lon1) or not position(r.lat2,r.lon2) then return nil end
    local reverse=runway(direction)==runway(r.end2); local rw=runway(direction)
    if not rw or (rw~=runway(r.end1) and not reverse) then return nil end
    local lat,lon=reverse and r.lat2 or r.lat1,reverse and r.lon2 or r.lon1
    local endlat,endlon=reverse and r.lat1 or r.lat2,reverse and r.lon1 or r.lon2
    local e,n=xy(endlat,endlon,lat,lon); local length=math.sqrt(e*e+n*n)
    if length<100 then return nil end
    return {airport=upper(airport),runway=rw,lat=lat,lon=lon,length=length,course=math.atan2(e,n)/DEG%360}
end
function M.choose(s,cache)
    if s.ground~=0 or not position(s.lat,s.lon) or not finite(s.true_heading) then return nil end
    local best,second; local count=0
    for airport,cached in pairs(cache or {}) do
        for _,r in ipairs(cached.runways or {}) do
            count=count+1; if count>256 then return nil end
            for _,direction in ipairs({r.end1,r.end2}) do
                local metadata=cached.metadata or {}
                local t=M.target(metadata.icao_code or metadata.icao_id or airport,r,direction)
                if t then
                    local f,right,d=project(s.lat,s.lon,t.lat,t.lon,t.course)
                    local hd=math.abs(wrap(s.true_heading-t.course))
                    if f<=300 and d<=18*1852 and hd<=45 and math.abs(right)<=math.max(150,math.max(0,-f)*math.tan(15*DEG)) then
                        t.score=math.abs(right)+hd*20
                        if not best or t.score<best.score then second=best; best=t
                        elseif not second or t.score<second.score then second=t end
                    end
                end
            end
        end
    end
    if best and (not second or second.score-best.score>=150) then return best end
end
function M:update(s,cache,confirmed)
    if not finite(s.t) then return M.geometry(nil,s,self.runtime) end
    local jumped=false
    if position(s.lat,s.lon) and position(self.last_lat,self.last_lon) and self.last_t then
        local e,n=xy(s.lat,s.lon,self.last_lat,self.last_lon)
        jumped=math.sqrt(e*e+n*n)>math.max(500,(s.gs or 0)*.514445*math.max(0,s.t-self.last_t)*3)
    end
    if self.last_t and (s.t<self.last_t or s.identity~=self.identity or jumped) then
        self.selected_target=nil; self.reference=nil; self.next_select=0; self.next_scan=0
        confirmed=nil
    end
    self.last_t=s.t; self.identity=s.identity; self.last_lat=s.lat; self.last_lon=s.lon
    if s.replay then self.selected_target=nil; self.reference=nil; return M.geometry(nil,s,self.runtime) end
    self:scan(s.t)
    if s.t>=self.next_select or (confirmed and targetkey(confirmed)~=targetkey(self.selected_target)) then
        self.next_select=s.t+1; self.stats.selections=self.stats.selections+1
        if confirmed then self.selected_target=confirmed
        elseif s.ground==0 then self.selected_target=M.choose(s,cache) end
        self.reference=self.selected_target and self:resolve(self.selected_target) or base("runway_unavailable")
        self.reference.ils_selection=confirmed and "touchdown" or "approach_geometry"
    end
    return M.geometry(self.reference,s,self.runtime)
end
return M

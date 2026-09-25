-- Advisory only. HTTPS runs in a hidden, bounded Windows worker, never in a draw callback.
local M={};M.__index=M
local function version(s)
    if type(s)~='string' then return end
    s=s:gsub('^v','')
    local a,b,c,tail=s:match('^(%d+)%.(%d+)%.(%d+)(.*)$')
    if not a then return end
    local rank,n=3,0
    if tail~='' then
        local stage,digit=tail:match('^%-?(%a+)(%d+)$')
        if not stage or not ({alpha=true,beta=true,rc=true})[stage] then return end
        rank=({alpha=0,beta=1,rc=2})[stage];n=tonumber(digit)
        -- Project maintenance naming: bare 1.1.9rc2+ follows the original 1.1.9.
        if a=='1' and b=='1' and c=='9' and tail:match('^rc%d+$') and n>=2 then rank=4 end
    end
    return {tonumber(a),tonumber(b),tonumber(c),rank,n}
end
function M.newer(a,b)
    local x,y=version(a),version(b);if not x or not y then return false end
    for i=1,5 do if x[i]~=y[i] then return x[i]>y[i] end end
    return false
end
local function quote(s)return "'"..s:gsub("'","''").."'" end
function M.script(path,variant)
    assert(variant=='Standard' or variant=='Compatibility')
    return [[
$ErrorActionPreference='Stop'
try {
 [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
 $r=Invoke-RestMethod -Uri 'https://api.github.com/repos/Starlux531/StarLux-Landing-Meter/releases?per_page=100' -Headers @{'User-Agent'='StarLux-LMM-Update-Check';'Accept'='application/vnd.github+json'} -TimeoutSec 15
 $versions=@($r | Where-Object { !$_.draft -and !$_.prerelease -and $_.tag_name -match '^v?\d+\.\d+\.\d+(rc\d+)?$' -and @($_.assets | Where-Object { $_.name -like 'StarLux_LMM_v*-]]..variant..[[-*.zip' }).Count -gt 0 } | ForEach-Object { $_.tag_name })
 $out=]]..quote(path)..";\n"..[[
 $text=([DateTimeOffset]::UtcNow.ToUnixTimeSeconds().ToString())+"`n"+($versions -join "`n")
 [IO.File]::WriteAllText($out+'.tmp',$text,[Text.UTF8Encoding]::new($false))
 Move-Item -LiteralPath ($out+'.tmp') -Destination $out -Force
} catch { exit 1 }
]]
end
local function launch(script,path)
    if SYSTEM~='IBM' then return false end
    local ffi=require('ffi')
    if not pcall(ffi.typeof,'LMM119U_PROCESS_INFORMATION') then ffi.cdef[[
        typedef unsigned short LMM119U_WCHAR;
        typedef struct {
            unsigned long cb; LMM119U_WCHAR *lpReserved,*lpDesktop,*lpTitle;
            unsigned long dwX,dwY,dwXSize,dwYSize,dwXCountChars,dwYCountChars,dwFillAttribute,dwFlags;
            unsigned short wShowWindow,cbReserved2; unsigned char *lpReserved2;
            void *hStdInput,*hStdOutput,*hStdError;
        } LMM119U_STARTUPINFO;
        typedef struct { void *hProcess,*hThread; unsigned long dwProcessId,dwThreadId; } LMM119U_PROCESS_INFORMATION;
        int MultiByteToWideChar(unsigned int, unsigned long, const char*, int, LMM119U_WCHAR*, int);
        int CreateProcessW(const LMM119U_WCHAR*,LMM119U_WCHAR*,void*,void*,int,unsigned long,void*,const LMM119U_WCHAR*,LMM119U_STARTUPINFO*,LMM119U_PROCESS_INFORMATION*);
        int CloseHandle(void*);
    ]] end
    local kernel=ffi.load('kernel32')
    local function wide(s)
        local n=kernel.MultiByteToWideChar(65001,0,s,#s,nil,0);assert(n>0)
        local buf=ffi.new('LMM119U_WCHAR[?]',n+1);kernel.MultiByteToWideChar(65001,0,s,#s,buf,n);return buf
    end
    -- UTF-16LE encoded command avoids both shell interpolation and Unicode path loss.
    local w=wide(script);local bytes=ffi.string(w,(ffi.sizeof(w)-2))
    local alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    local encoded={}
    for i=1,#bytes,3 do
        local a,b,c=bytes:byte(i,i+2);local n=a*65536+(b or 0)*256+(c or 0)
        for j=3,0,-1 do
            local index=math.floor(n/2^(j*6))%64
            encoded[#encoded+1]=(j==1 and not b or j==0 and not c) and '=' or alphabet:sub(index+1,index+1)
        end
    end
    local args='-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand '..table.concat(encoded)
    local exe=assert(os.getenv('SystemRoot'))..'\\System32\\WindowsPowerShell\\v1.0\\powershell.exe'
    local si=ffi.new('LMM119U_STARTUPINFO[1]');si[0].cb=ffi.sizeof(si[0]);si[0].dwFlags=1;si[0].wShowWindow=0
    local pi=ffi.new('LMM119U_PROCESS_INFORMATION[1]')
    -- CREATE_NO_WINDOW: no shell association lookup, console or wait on the worker.
    local ok=kernel.CreateProcessW(wide(exe),wide('"'..exe..'" '..args),nil,nil,0,0x08000000,nil,nil,si,pi)~=0
    if ok then kernel.CloseHandle(pi[0].hThread);kernel.CloseHandle(pi[0].hProcess) end
    return ok
end
function M.new(options)
    local self=setmetatable({current=options.current,path=options.path,variant=options.variant or 'Standard',
        clock=options.clock or os.time,launch=options.launch or launch,available=false,next_check=0},M)
    return self
end
function M:read(now)
    local f=io.open(self.path,'rb');if not f then return end
    local text=f:read(8193);f:close();if not text or #text>8192 then return end
    local stamp=tonumber(text:match('^(%d+)\r?\n'));if not stamp or stamp>now+60 then return end
    local best
    for tag in text:gmatch('[^\r\n]+') do
        if version(tag) and (not best or M.newer(tag,best)) then best=tag:gsub('^v','') end
    end
    self.latest=best;self.available=best~=nil and M.newer(best,self.current)
    if self.available and self.announced~=self.latest then self.announced=self.latest;self.toast_until=now+30 end
    if self.pending and stamp>=self.started then self.pending=false;self.next_check=now+21600 end
    if not self.initialized then self.initialized=true;if stamp>now-21600 then self.next_check=stamp+21600 end end
end
function M:tick()
    local now=self.clock();self:read(now)
    if self.pending then
        if now-self.started>45 then self.pending=false;self.next_check=now+900 end
        return
    end
    if now<self.next_check then return end
    self.started=now;self.next_check=now+900
    local ok,result=pcall(self.launch,M.script(self.path,self.variant),self.path)
    self.pending=ok and result==true
end
return M

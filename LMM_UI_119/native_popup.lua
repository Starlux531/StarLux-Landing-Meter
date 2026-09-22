-- StarLux LMM 1.1.9: SDK 440 Panel Graphics host for FlyWithLua/LuaJIT.
-- ABI checked against XPSDK440b1.zip headers, not the staging Lua-flavoured
-- signature (which incorrectly calls int visible a bool and contentType
-- windowContentType). Never call Panel Graphics from do_every_draw directly.
local M = {}
local ffi = require("ffi")
local layout = dofile((... or "") .. "layout.lua")
M.resize_edges=layout.resize_edges
M.resize_factor=layout.resize_factor
M.resize_position=layout.resize_position
local dialogs = assert(loadfile((... or "") .. "dialog.lua"))(... or "")

if not pcall(ffi.typeof, "LMM118_WindowSpec") then
    ffi.cdef[[
    typedef void (*LMM118_Draw)(void *, void *);
    typedef int (*LMM118_Mouse)(void *, int, int, int, void *);
    typedef void (*LMM118_Key)(void *, char, int, char, void *, int);
    typedef int (*LMM118_Cursor)(void *, int, int, void *);
    typedef int (*LMM118_Wheel)(void *, int, int, int, int, void *);
    typedef struct {
        int structSize, left, top, right, bottom, visible;
        LMM118_Draw drawWindowFunc;
        LMM118_Mouse handleMouseClickFunc;
        LMM118_Key handleKeyFunc;
        LMM118_Cursor handleCursorFunc;
        LMM118_Wheel handleMouseWheelFunc;
        void *refcon;
        int decorateAsFloatingWindow, layer;
        LMM118_Mouse handleRightClickFunc;
        int contentType;
        void *browserLoadFinishedFunc, *browserLoadErrorFunc;
    } LMM118_WindowSpec;
    typedef struct { int structSize; float lineHeight, lineAscent, lineDescent; } LMM118_Metrics;
    typedef struct { float x, y; } LMM118_Vertex;
    void XPLMGetVersions(int *, int *, int *);
    void *XPLMCreateWindowEx(const LMM118_WindowSpec *);
    void XPLMDestroyWindow(void *);
    void XPLMSetWindowIsVisible(void *, int);
    void XPLMSetWindowGeometry(void *, int, int, int, int);
    void XPLMGetScreenBoundsGlobal(int *, int *, int *, int *);
    void XPLMGetMouseLocationGlobal(int *, int *);
    void XPLMGetWindowGeometry(void *, int *, int *, int *, int *);
    int XPLMGetWindowIsVisible(void *);
    void XPLMSetWindowTitle(void *, const char *);
    void XPLMSetWindowResizingLimits(void *, int, int, int, int);
    void *XPLMCreateFont(int);
    void XPLMDestroyFont(void *);
    int XPLMFontAddFace(void *, const char *);
    void XPLMFontGetMetrics(void *, float, LMM118_Metrics *);
    float XPLMFontMeasureString(void *, float, const char *);
    void XPLMFontDrawString(void *, uint32_t, float, float, float, const char *, int);
    void XPLMPolygon(uint32_t, const LMM118_Vertex *, int);
    ]]
end

-- Also declare the optional cursor helper after a reload from an older build
-- whose cached FFI window type already exists.
pcall(ffi.cdef,"void XPLMGetMouseLocationGlobal(int *, int *);")
local required = {"XPLMGetVersions", "XPLMCreateWindowEx", "XPLMDestroyWindow",
    "XPLMSetWindowIsVisible", "XPLMSetWindowGeometry", "XPLMGetScreenBoundsGlobal",
    "XPLMCreateFont", "XPLMDestroyFont", "XPLMFontAddFace", "XPLMFontGetMetrics",
    "XPLMFontMeasureString", "XPLMFontDrawString", "XPLMPolygon"}

local function pack(r, g, b, a)
    local function byte(v) return math.floor(math.max(0, math.min(1, v)) * 255 + 0.5) end
    return byte(r) + byte(g) * 256 + byte(b) * 65536 + byte(a) * 16777216
end

function M:rect(x, y, w, h, color)
    local v = self.vertices
    v[0].x, v[0].y = x, y
    v[1].x, v[1].y = x + w, y
    v[2].x, v[2].y = x + w, y + h
    v[3].x, v[3].y = x, y + h
    self.api.XPLMPolygon(color, v, 4)
end

function M:draw()
    if not self.ready or not self.visible or not self.frame then return end
    local f, l = self.frame, self.layout
    local x, y, w, h = self.x, self.y, l.width, l.height
    local r, g, b = unpack(f.color)
    self:rect(x, y, w, h, pack(r, g, b, f.alpha))
    if f.vertical then
        self:rect(x, y + h - l.accent, w, l.accent, pack(r, g, b, 0.96))
    else
        self:rect(x, y, l.accent, h, pack(r, g, b, 0.96))
    end
    local border = pack(r, g, b, 0.78)
    self:rect(x, y, w, 1, border)
    self:rect(x, y + h - 1, w, 1, border)
    self:rect(x, y, 1, h, border)
    self:rect(x + w - 1, y, 1, h, border)
    local text_color = pack(f.text_color[1], f.text_color[2], f.text_color[3], 0.98)
    local font = self.fonts[f.weight] or self.fonts.normal
    for i, row in ipairs(l.rows) do
        -- Blink visibility does not enter the layout key, so all three flashes
        -- keep their reserved space without loading fonts or resizing the box.
        if row.source ~= f.hidden_line then
            self.api.XPLMFontDrawString(font, text_color, l.size, x + l.left,
                y + h - l.top - l.ascent - (i - 1) * l.gap, row.text, 0)
        end
    end
    if f.on_resize then
        self:rect(x+w-10,y+3,7,1,border)
        self:rect(x+w-4,y+3,1,7,border)
    end
end

function M:hide()
    self.drag=nil
    if self.window and self.visible then self.api.XPLMSetWindowIsVisible(self.window, 0) end
    self.visible = false
end

function M:destroy()
    self.ready = false
    for _, dialog in pairs(self.dialogs or {}) do dialog:destroy() end
    self.dialogs = {}
    -- Unregister the native callbacks before releasing LuaJIT trampolines.
    if self.window then
        self.api.XPLMDestroyWindow(self.window)
        self.window = nil
    end
    for _, callback in ipairs(self.callbacks or {}) do callback:free() end
    self.callbacks = {}
    for _, font in pairs(self.fonts or {}) do self.api.XPLMDestroyFont(font) end
    self.fonts, self.frame, self.visible = {}, nil, false
end

function M:measure(text, size)
    local max_width = 0
    for _, font in pairs(self.fonts) do
        local width = tonumber(self.api.XPLMFontMeasureString(font, size, text))
        assert(width and width == width and width >= 0 and width < 1000000, "Invalid font width")
        max_width = math.max(max_width, width)
    end
    return max_width
end

function M:metrics(size)
    local ascent, descent, height = 0, 0, 0
    for _, font in pairs(self.fonts) do
        local m = self.font_metrics
        m[0].structSize = ffi.sizeof("LMM118_Metrics")
        self.api.XPLMFontGetMetrics(font, size, m)
        assert(m[0].lineHeight > 0 and m[0].lineHeight < size * 5
            and m[0].lineAscent > 0 and m[0].lineDescent >= 0, "Invalid font metrics")
        ascent, descent, height = math.max(ascent, m[0].lineAscent),
            math.max(descent, m[0].lineDescent), math.max(height, m[0].lineHeight)
    end
    return ascent, descent, height
end

function M:present(frame, resizing, finished)
    assert(self.ready, self.error or "Native popup unavailable")
    local bounds = self.bounds
    self.api.XPLMGetScreenBoundsGlobal(bounds, bounds + 1, bounds + 2, bounds + 3)
    local left, top, right, bottom = tonumber(bounds[0]), tonumber(bounds[1]),
        tonumber(bounds[2]), tonumber(bounds[3])
    local sw, sh = right - left, top - bottom
    assert(sw > 0 and sh > 0, "Invalid desktop bounds")
    local key = table.concat(frame.lines, "\30") .. "\31" .. frame.size .. ":" .. sw .. ":" .. sh
        .. ":" .. tostring(frame.vertical)
    if key ~= self.layout_key then
        self.layout = layout.build(frame.lines, frame.size, math.max(1, sw - 20),
            math.max(1, sh - 20), frame.vertical,
            function(px) return self:metrics(px) end,
            function(text, px) return self:measure(text, px) end)
        self.layout_key = key
    end
    local x, y
    if resizing then
        local px,py=layout.resize_position(resizing,self.layout.width,self.layout.height,left,top,right,bottom)
        frame.on_move((px-left)/math.max(1,sw-self.layout.width),
            (py-bottom)/math.max(1,sh-self.layout.height),finished)
        x,y=px-left,py-bottom
    else x,y=frame.position(sw,sh,self.layout.width,self.layout.height) end
    self.x, self.y, self.frame = left + x, bottom + y, frame
    local geometry = table.concat({self.x, self.y, self.layout.width, self.layout.height}, ":")
    if geometry ~= self.geometry then
        self.api.XPLMSetWindowGeometry(self.window, self.x, self.y + self.layout.height,
            self.x + self.layout.width, self.y)
        self.geometry = geometry
    end
    if not self.visible then self.api.XPLMSetWindowIsVisible(self.window, 1) end
    self.visible = true
end

function M:mouse(x,y,status)
    if not self.visible or not self.frame or not self.frame.on_move then return 0 end
    if status==1 then
        if x<self.x or x>self.x+self.layout.width or y<self.y or y>self.y+self.layout.height then return 0 end
        local hx,hy=layout.resize_edges(x,y,self.x,self.y,self.layout.width,self.layout.height)
        self.drag={x=x,y=y,left=self.x,bottom=self.y,w=self.layout.width,h=self.layout.height,
            hx=hx,hy=hy,size=self.frame.size,resize=self.frame.on_resize and (hx~=0 or hy~=0)}
    elseif (status==2 or status==3) and self.drag then
        local b=self.bounds; local left,top,right,bottom=tonumber(b[0]),tonumber(b[1]),tonumber(b[2]),tonumber(b[3])
        if self.drag.resize then
            local frame=self.frame
            local size=layout.clamp_size(self.drag.size*layout.resize_factor(self.drag,x,y))
            frame.size=size
            frame.on_resize(size,status==3)
            self:present(frame,self.drag,status==3)
            if status==3 then self.drag=nil end
            return 1
        end
        local width,height=math.max(1,right-left-self.layout.width),math.max(1,top-bottom-self.layout.height)
        local nx=math.max(0,math.min(1,(self.drag.left+x-self.drag.x-left)/width))
        local ny=math.max(0,math.min(1,(self.drag.bottom+y-self.drag.y-bottom)/height))
        self.frame.on_move(nx,ny,status==3)
        if status==3 then self.drag=nil end
    else return 0 end
    return 1
end

function M:initialize(options)
    local name = options.system == "IBM" and "XPLM_64"
        or (options.system == "APL" and options.root .. "Resources/plugins/XPLM.framework/XPLM")
        or (options.system == "LIN" and options.root .. "Resources/plugins/XPLM_64.so")
    assert(name, "Unsupported platform")
    self.api = ffi.load(name)
    -- Probe every symbol before creating fonts, windows, or callbacks.
    for _, symbol in ipairs(required) do assert(self.api[symbol], "Missing SDK symbol: " .. symbol) end
    local versions = ffi.new("int[3]")
    self.api.XPLMGetVersions(versions, versions + 1, versions + 2)
    self.version_info = string.format("XP API=%d; SDK=%d", versions[0], versions[1])
    -- GetVersions is NOT Log.txt's build number (e.g. 124410). Capability
    -- symbols plus SDK version gate the new ABI; never compare XP to a build ID.
    assert(versions[1] >= 440, "Requires SDK 440; " .. self.version_info)
    for _, weight in ipairs({"normal", "medium", "bold"}) do
        local font = self.api.XPLMCreateFont(2) -- on-demand Unicode glyphs
        assert(font ~= nil, "Cannot create Unicode font")
        self.fonts[weight] = font
        local filename = ({normal = "Regular", medium = "Medium", bold = "Bold"})[weight]
        local path = options.assets .. "fonts/LMMUI-" .. filename .. ".otf"
        assert(self.api.XPLMFontAddFace(font, path) == 1, "Cannot load font: " .. path)
        -- Full XP CJK fallback covers text outside the bundled UI subset.
        -- Never copy or redistribute the simulator's own font files.
        self.api.XPLMFontAddFace(font, options.root .. "Resources/fonts/NotoSansCJK-SC-Regular.otf")
    end
    self.vertices = ffi.new("LMM118_Vertex[4]")
    self.bounds = ffi.new("int[4]")
    self.font_metrics = ffi.new("LMM118_Metrics[1]")
    self:metrics(14)
    self:measure("StarLux 落地报告已生成", 14)
    local function keep(ctype, fn)
        local callback = ffi.cast(ctype, fn)
        self.callbacks[#self.callbacks + 1] = callback
        return callback
    end
    local spec = ffi.new("LMM118_WindowSpec")
    spec.structSize = ffi.sizeof(spec)
    spec.left, spec.top, spec.right, spec.bottom = 0, 100, 100, 0
    spec.visible, spec.decorateAsFloatingWindow, spec.layer, spec.contentType = 0, 0, 0, 1
    spec.drawWindowFunc = keep("LMM118_Draw", function()
        local ok, err = pcall(self.draw, self)
        if not ok then
            -- Do not destroy the window or free its callback while inside it.
            self.ready, self.error = false, tostring(err)
        end
    end)
    spec.handleMouseClickFunc = keep("LMM118_Mouse", function(_,x,y,status)
        local ok,result=pcall(self.mouse,self,x,y,status); return ok and result or 0
    end)
    spec.handleRightClickFunc = keep("LMM118_Mouse", function() return 0 end)
    spec.handleKeyFunc = keep("LMM118_Key", function() end)
    spec.handleCursorFunc = keep("LMM118_Cursor", function() return 0 end)
    spec.handleMouseWheelFunc = keep("LMM118_Wheel", function() return 0 end)
    self.window = self.api.XPLMCreateWindowEx(spec)
    assert(self.window ~= nil, "Panel Graphics window creation failed")
    self.ready = true
end

function M.new(options)
    local self = setmetatable({fonts = {}, callbacks = {}}, {__index = M})
    local ok, err = pcall(self.initialize, self, options)
    if not ok then
        self.error = tostring(err)
        self:destroy()
    end
    return self
end

function M:open_dialog(id, builder, title, width, height)
    self.dialogs = self.dialogs or {}
    if self.dialogs[id] then self.dialogs[id]:destroy(); self.dialogs[id] = nil end
    self.dialogs[id] = dialogs.new(self, ffi, builder, title, width, height)
end

function M:update_dialogs()
    local ids = {}
    for id in pairs(self.dialogs or {}) do ids[#ids+1] = id end
    for _, id in ipairs(ids) do
        local dialog = self.dialogs[id]
        if not dialog:tick() then
            dialog:destroy()
            self.dialogs[id] = nil
        end
    end
end

-- LuaJIT must never compile a C call which may synchronously re-enter Lua.
-- This only disables JIT for this tiny UI module, not for the landing recorder.
if jit then for _, fn in pairs(M) do if type(fn) == "function" then jit.off(fn, true) end end end
return M

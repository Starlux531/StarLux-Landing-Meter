-- StarLux 落地率插件 v0.7 相对稳定测试版
-- 适用于 X-Plane 12 + FlyWithLua
-- v0.7 通过初步实飞测试，整合独立设置窗口、布局/透明度选项和延迟存档。

-- =========================
-- 用户设置
-- =========================

local POPUP_MODE = "touchdown"
-- "touchdown" = 触地并完成 G 值采集后显示
-- "taxi"      = 地速降低到 30 节以下时显示

local DISPLAY_SECONDS = 30
-- 较短的 G 值采集窗口可减小触地后起落架压缩和滑跑振动的影响。
local G_CAPTURE_SECONDS = 0.22
local TAXI_POPUP_SPEED_KT = 30

-- 紧凑型数据窗；设置窗口提供九种屏幕位置。
local POPUP_POSITION = "middle_left"
local POPUP_LAYOUT = "horizontal"
-- "horizontal" = 横向数据窗，状态色粗边位于左侧
-- "vertical"   = 竖向数据窗，状态色粗边位于上方
local HORIZONTAL_PANEL_W = 340
local HORIZONTAL_PANEL_H = 112
local VERTICAL_PANEL_W = 215
local VERTICAL_PANEL_H = 168
local ACCENT_THICKNESS = 12
local BORDER_ALPHA = 0.78
local PANEL_OPACITY_LEVEL = 25
-- 25 档为默认浅透明效果；50 档保持 v0.6.3 的视觉效果；100 档强度最高。
local PANEL_ALPHA_LEVELS = {
    [25] = 0.18,
    [50] = 0.30,
    [100] = 0.60
}

-- TXT 写入延后到弹窗出现之后，避免在触地关键帧执行磁盘和日志操作。
local LOG_WRITE_DELAY_SECONDS = 1.5

local PATH_SEPARATOR = package.config:sub(1, 1)
local LMM_BASE_DIRECTORY = SCRIPT_DIRECTORY or "."

local function join_path(base, name)
    local last_char = base:sub(-1)
    if last_char == "/" or last_char == "\\" then
        return base .. name
    end
    return base .. PATH_SEPARATOR .. name
end

local SETTINGS_FILE_PATH = join_path(LMM_BASE_DIRECTORY, "LMM_Settings.cfg")
local LOG_DIRECTORY_PATH = join_path(LMM_BASE_DIRECTORY, "LMM_Log")

-- 接地率采集逻辑。
-- "minimum_final" = 使用触地前短时间窗口内最大的向下垂直速度。
-- "last_frame"    = 使用离地状态最后一帧的垂直速度。
local FPM_CAPTURE_MODE = "minimum_final"
local VS_SAMPLE_WINDOW_SECONDS = 0.85
local VS_SAMPLE_MAX_AGL_FT = 120

-- G 值评分方式。
-- true  = 使用触地后短时间窗口内的峰值 G。
-- false = 只使用触地帧的 G 值。
local USE_PEAK_G_FOR_SCORE = true

-- G 值稳健处理逻辑。
-- 触地后起落架压缩、弹跳、机轮加速或较大的俯仰/横滚输入，都可能造成原始 G 值尖峰。
-- 因此最终显示和评分使用短窗口稳健 G 值，并可由简化的 FPM/G 物理一致性保护进行限幅。
local G_ROBUST_PERCENTILE = 0.85
local ENABLE_G_FPM_LOGIC_GUARD = true
local G_FPM_DECEL_TIME_SECONDS = 0.42
local G_LOGIC_MARGIN_SOFT = 0.10
local G_LOGIC_MARGIN_NORMAL = 0.14
local G_LOGIC_MARGIN_HARD = 0.20

-- 评分阈值
local FPM_STABLE_MAX = 220
local FPM_ATTENTION_MAX = 350

local G_STABLE_MAX = 1.30
local G_ATTENTION_MAX = 1.45

-- 预留的外部评分接口。
-- 当前保持为 nil，以后可在这里接入其他计算得到的着陆质量指标。
-- 可接受的值：nil、"STABLE"、"ATTENTION" 或 "UNSTABLE"。
local EXTERNAL_SCORE_HINT = nil

-- 调试数据显示，可在设置窗口中开关。
local DEBUG_MODE = false

-- =========================
-- DataRef 数据读取
-- =========================

-- 直接使用 XPLM 句柄不会占用 FlyWithLua 的 DataRef 表槽位。
-- 当用户同时运行许多注册了大量 DataRef 的脚本时，这种方式更加稳定。
local LMM_DATAREF_SPECS = {
    { key = "vs_fpm", path = "sim/flightmodel/position/vh_ind_fpm", kind = "float" },
    { key = "y_agl_m", path = "sim/flightmodel/position/y_agl", kind = "float" },
    { key = "on_ground", path = "sim/flightmodel/failures/onground_any", kind = "int" },
    { key = "g_normal", path = "sim/flightmodel/forces/g_nrml", kind = "float" },
    { key = "roll_deg", path = "sim/flightmodel/position/phi", kind = "float" },
    { key = "groundspeed_mps", path = "sim/flightmodel/position/groundspeed", kind = "float" },
    { key = "running_time_sec", path = "sim/time/total_running_time_sec", kind = "float" },
    { key = "ias_kts", path = "sim/cockpit2/gauges/indicators/airspeed_kts_pilot", kind = "float" },
    { key = "tas_kts", path = "sim/cockpit2/gauges/indicators/true_airspeed_kts_pilot", kind = "float" },
    { key = "aoa_deg", path = "sim/flightmodel/position/alpha", kind = "float" },
    { key = "wind_speed_kts", path = "sim/cockpit2/gauges/indicators/wind_speed_kts", kind = "float" },
    { key = "wind_heading_deg_mag", path = "sim/cockpit2/gauges/indicators/wind_heading_deg_mag", kind = "float" },
    { key = "heading_deg_mag", path = "sim/flightmodel/position/mag_psi", kind = "float" }
}

local LMM_DATAREFS = {}
local lmm_missing_datarefs = {}

for i = 1, #LMM_DATAREF_SPECS do
    local spec = LMM_DATAREF_SPECS[i]
    local handle = XPLMFindDataRef(spec.path)
    LMM_DATAREFS[spec.key] = handle
    if handle == nil then
        table.insert(lmm_missing_datarefs, spec.path)
    end
end

local function lmm_get_float(key)
    local handle = LMM_DATAREFS[key]
    if handle == nil then return 0 end
    return XPLMGetDataf(handle)
end

local function lmm_get_int(key)
    local handle = LMM_DATAREFS[key]
    if handle == nil then return 0 end
    return XPLMGetDatai(handle)
end

if #lmm_missing_datarefs > 0 and logMsg then
    logMsg("[StarLux LMM] Missing required DataRefs: " .. table.concat(lmm_missing_datarefs, ", "))
end

-- =========================
-- 内部状态
-- =========================

local armed = false
local was_on_ground = 1

local vs_samples = {}

-- 将相关数值集中到表中，使回调函数低于 Lua 5.1 单函数 60 个 upvalue 的限制。
-- 旧版使用大量平铺局部变量，导致主更新回调捕获超过 60 个值并在执行前编译失败。
local approach_data = {
    vs_fpm = 0,
    selected_vs_fpm = 0,
    ias_kts = 0,
    tas_kts = 0,
    gs_kts = 0,
    aoa_deg = 0,
    roll_deg = 0,
    wind_speed_kts = 0,
    wind_heading_deg = 0,
    heading_deg = 0
}

local landing_active = false
local landing_complete = false
local g_capture_until = 0
local g_samples = {}

local landing_fpm = 0
local landing_touch_g = 1.00
local landing_peak_g = 1.00
local landing_g = 1.00
local landing_ias_kts = 0
local landing_tas_kts = 0
local landing_gs_kts = 0
local landing_aoa_deg = 0
local landing_roll_deg = 0
local landing_wind_speed_kts = 0
local landing_wind_heading_deg = 0
local landing_heading_deg = 0
local landing_wind_relative_text = ""
local landing_status = "STABLE"
local landing_timestamp = ""

local debug_data = {
    last_frame_fpm = 0,
    selected_fpm = 0,
    touch_g = 0,
    peak_g = 0,
    robust_g = 0,
    expected_max_g = 0,
    used_g = 0
}

local show_until = 0
local taxi_popup_done = false
local settings_window = nil
local landing_log_pending = false
local landing_log_write_after = 0

local POSITION_OPTIONS = {
    { id = "top_left", label = "Top left" },
    { id = "top_center", label = "Top center" },
    { id = "top_right", label = "Top right" },
    { id = "middle_left", label = "Middle left" },
    { id = "center", label = "Center" },
    { id = "middle_right", label = "Middle right" },
    { id = "bottom_left", label = "Bottom left" },
    { id = "bottom_center", label = "Bottom center" },
    { id = "bottom_right", label = "Bottom right" }
}

-- =========================
-- 工具函数
-- =========================

local function round_num(n)
    if n >= 0 then
        return math.floor(n + 0.5)
    else
        return math.ceil(n - 0.5)
    end
end

local function mps_to_kt(mps)
    return mps * 1.943844
end

local function meters_to_feet(m)
    return m * 3.28084
end

local function abs_value(v)
    if v < 0 then return -v end
    return v
end

local function normalize_deg(deg)
    local d = deg % 360
    if d < 0 then d = d + 360 end
    return d
end

local function angular_diff_180(from_deg, to_deg)
    -- 返回飞机航向到来风方向之间带正负号的最短角度差。
    -- 负值表示风从左侧吹来，正值表示风从右侧吹来。
    local diff = normalize_deg(from_deg - to_deg)
    if diff > 180 then diff = diff - 360 end
    return diff
end

local function build_wind_relative_text(wind_from_deg, wind_speed_kts, aircraft_heading_deg)
    -- X-Plane 的风向表示风吹来的方向。
    -- 使用六种相对风类别，让落地数据显示得更准确：
    -- 顶风 / 左前侧风 / 右前侧风 / 左后侧风 / 右后侧风 / 顺风
    local diff = angular_diff_180(wind_from_deg, aircraft_heading_deg)
    local abs_diff = abs_value(diff)
    local side = "顶风"

    if abs_diff <= 20 then
        side = "顶风"
    elseif abs_diff >= 160 then
        side = "顺风"
    elseif diff < 0 and abs_diff <= 90 then
        side = "左前侧风"
    elseif diff > 0 and abs_diff <= 90 then
        side = "右前侧风"
    elseif diff < 0 then
        side = "左后侧风"
    else
        side = "右后侧风"
    end

    return string.format("风 %03d/%dkt %s", round_num(normalize_deg(wind_from_deg)), round_num(wind_speed_kts), side)
end

local function format_roll_text(roll_deg)
    -- X-Plane 的 phi 通常右倾为正、左倾为负。
    -- 很小的数值按水平处理，避免出现干扰视线的 +/-0.1° 跳动。
    local abs_roll = abs_value(roll_deg)
    if abs_roll < 0.05 then
        return "横滚 LEVEL 0.0°"
    elseif roll_deg < 0 then
        return string.format("横滚 L %.1f°", abs_roll)
    else
        return string.format("横滚 R %.1f°", abs_roll)
    end
end

local function classify_landing(fpm, g, external_hint)
    local abs_fpm = abs_value(fpm)
    local level = 0
    -- 0 = 稳定，1 = 需注意，2 = 不稳定

    if abs_fpm > FPM_ATTENTION_MAX or g > G_ATTENTION_MAX then
        level = 2
    elseif abs_fpm > FPM_STABLE_MAX or g > G_STABLE_MAX then
        level = 1
    end

    -- 为以后使用预留的外部评分接口。
    if external_hint == "UNSTABLE" then
        level = math.max(level, 2)
    elseif external_hint == "ATTENTION" then
        level = math.max(level, 1)
    end

    if level == 2 then
        return "UNSTABLE"
    elseif level == 1 then
        return "ATTENTION"
    else
        return "STABLE"
    end
end

local function status_color(status)
    if status == "UNSTABLE" then
        return 0.72, 0.10, 0.12
    elseif status == "ATTENTION" then
        return 0.78, 0.52, 0.06
    else
        return 0.08, 0.50, 0.24
    end
end

local function status_short(status)
    if status == "UNSTABLE" then
        return "UNSTABLE"
    elseif status == "ATTENTION" then
        return "ATTENTION"
    else
        return "STABLE"
    end
end

local function panel_alpha()
    return PANEL_ALPHA_LEVELS[PANEL_OPACITY_LEVEL] or PANEL_ALPHA_LEVELS[25]
end

local function clear_vs_samples()
    vs_samples = {}
end

local function add_vs_sample(now, vs_fpm)
    table.insert(vs_samples, { t = now, vs = vs_fpm })

    local cutoff = now - VS_SAMPLE_WINDOW_SECONDS
    while #vs_samples > 0 and vs_samples[1].t < cutoff do
        table.remove(vs_samples, 1)
    end
end

local function select_final_vs_fpm()
    if #vs_samples == 0 then
        return approach_data.vs_fpm
    end

    if FPM_CAPTURE_MODE == "last_frame" then
        return approach_data.vs_fpm
    end

    -- 使用最后采样窗口内最大的向下速度。
    -- 在 X-Plane 中，这通常比离地状态最后一帧更能对应触地 G 值，
    -- 因为最后一帧可能已经受到机轮接触或 DataRef 平滑处理的影响。
    local min_vs = vs_samples[1].vs
    for i = 2, #vs_samples do
        if vs_samples[i].vs < min_vs then
            min_vs = vs_samples[i].vs
        end
    end

    return min_vs
end

local function clear_g_samples()
    g_samples = {}
end

local function sanitize_g(g)
    -- 正常触地 G 值应为正数并处于合理范围内。
    -- 不使用 abs(g)，避免异常负向尖峰被转换成重着陆数值。
    if g == nil then return nil end
    if g > 0.5 and g < 3.0 then
        return g
    end
    return nil
end

local function add_g_sample(now, g)
    local clean_g = sanitize_g(g)
    if clean_g == nil then return end

    table.insert(g_samples, { t = now, g = clean_g })

    local cutoff = now - G_CAPTURE_SECONDS
    while #g_samples > 0 and g_samples[1].t < cutoff do
        table.remove(g_samples, 1)
    end
end

local function select_robust_g()
    if #g_samples == 0 then
        return landing_touch_g
    end

    local values = {}
    for i = 1, #g_samples do
        values[i] = g_samples[i].g
    end
    table.sort(values)

    -- 样本数量过少时无法得到有意义的百分位数，此时直接使用最大值。
    if #values < 4 then
        return values[#values]
    end

    local index = math.ceil(#values * G_ROBUST_PERCENTILE)
    if index < 1 then index = 1 end
    if index > #values then index = #values end

    return values[index]
end

local function estimate_g_from_fpm(fpm)
    -- 简化的物理合理性估算：
    -- 触地载荷大致取决于下沉速度能量在起落架和减震支柱作用时间内被吸收的过程。
    -- 该估算不会替代实测 G 值，只用于排除明显不合理的 FPM/G 组合。
    local sink_mps = abs_value(fpm) * 0.00508
    local extra_g = sink_mps / (G_FPM_DECEL_TIME_SECONDS * 9.80665)
    return 1.0 + extra_g
end

local function max_logical_g_from_fpm(fpm)
    local abs_fpm = abs_value(fpm)
    local margin = G_LOGIC_MARGIN_HARD

    if abs_fpm <= 150 then
        margin = G_LOGIC_MARGIN_SOFT
    elseif abs_fpm <= 300 then
        margin = G_LOGIC_MARGIN_NORMAL
    end

    return estimate_g_from_fpm(fpm) + margin
end

local function compute_landing_g(fpm)
    local robust_g = select_robust_g()
    local logical_cap_g = max_logical_g_from_fpm(fpm)
    local used_g = robust_g

    if ENABLE_G_FPM_LOGIC_GUARD == true and used_g > logical_cap_g then
        used_g = logical_cap_g
    end

    if used_g < 1.0 then
        used_g = 1.0
    end

    return used_g, robust_g, logical_cap_g
end

local function draw_panel_border(x, y, w, h, r, g, b)
    glColor4f(r, g, b, BORDER_ALPHA)
    glRectf(x, y + h - 1, x + w, y + h)
    glRectf(x, y, x + w, y + 1)
    glRectf(x, y, x + 1, y + h)
    glRectf(x + w - 1, y, x + w, y + h)
end

local function current_sim_time()
    local sim_time = lmm_get_float("running_time_sec")
    if sim_time > 0 then
        return sim_time
    end
    return os.clock()
end

local function is_valid_position(position_id)
    for i = 1, #POSITION_OPTIONS do
        if POSITION_OPTIONS[i].id == position_id then
            return true
        end
    end
    return false
end

local function position_label(position_id)
    for i = 1, #POSITION_OPTIONS do
        if POSITION_OPTIONS[i].id == position_id then
            return POSITION_OPTIONS[i].label
        end
    end
    return "Middle left"
end

local function calculate_popup_position(screen_w, screen_h, panel_w, panel_h)
    local margin = 30
    local x = margin
    local y = math.floor((screen_h - panel_h) / 2)

    if POPUP_POSITION == "top_left" or POPUP_POSITION == "top_center" or POPUP_POSITION == "top_right" then
        y = screen_h - panel_h - margin
    elseif POPUP_POSITION == "bottom_left" or POPUP_POSITION == "bottom_center" or POPUP_POSITION == "bottom_right" then
        y = margin
    end

    if POPUP_POSITION == "top_center" or POPUP_POSITION == "center" or POPUP_POSITION == "bottom_center" then
        x = math.floor((screen_w - panel_w) / 2)
    elseif POPUP_POSITION == "top_right" or POPUP_POSITION == "middle_right" or POPUP_POSITION == "bottom_right" then
        x = screen_w - panel_w - margin
    end

    if x < 0 then x = 0 end
    if y < 0 then y = 0 end
    if x + panel_w > screen_w then x = math.max(0, screen_w - panel_w) end
    if y + panel_h > screen_h then y = math.max(0, screen_h - panel_h) end

    return x, y
end

local settings_save_ok = true

local function save_settings()
    local file, err = io.open(SETTINGS_FILE_PATH, "w")
    if file == nil then
        settings_save_ok = false
        if logMsg then
            logMsg("[StarLux LMM] Unable to save settings: " .. tostring(err))
        end
        return false
    end

    file:write("# StarLux Landing Meter settings\n")
    file:write("popup_mode=" .. POPUP_MODE .. "\n")
    file:write("display_seconds=" .. tostring(DISPLAY_SECONDS) .. "\n")
    file:write("popup_position=" .. POPUP_POSITION .. "\n")
    file:write("popup_layout=" .. POPUP_LAYOUT .. "\n")
    file:write("panel_opacity=" .. tostring(PANEL_OPACITY_LEVEL) .. "\n")
    file:write("debug_mode=" .. tostring(DEBUG_MODE) .. "\n")
    file:close()
    settings_save_ok = true
    return true
end

local function load_settings()
    local file = io.open(SETTINGS_FILE_PATH, "r")
    if file == nil then
        save_settings()
        return
    end

    for line in file:lines() do
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key == "popup_mode" and (value == "touchdown" or value == "taxi") then
            POPUP_MODE = value
        elseif key == "display_seconds" then
            local seconds = tonumber(value)
            if seconds == 30 or seconds == 60 or seconds == 120 then
                DISPLAY_SECONDS = seconds
            end
        elseif key == "popup_position" and is_valid_position(value) then
            POPUP_POSITION = value
        elseif key == "popup_layout" and (value == "horizontal" or value == "vertical") then
            POPUP_LAYOUT = value
        elseif key == "panel_opacity" then
            local opacity = tonumber(value)
            if opacity == 25 or opacity == 50 or opacity == 100 then
                PANEL_OPACITY_LEVEL = opacity
            end
        elseif key == "debug_mode" then
            DEBUG_MODE = value == "true"
        end
    end
    file:close()
end

local function ensure_log_directory()
    local command
    if PATH_SEPARATOR == "\\" then
        command = 'mkdir "' .. LOG_DIRECTORY_PATH .. '" >NUL 2>NUL'
    else
        command = 'mkdir -p "' .. LOG_DIRECTORY_PATH .. '" >/dev/null 2>&1'
    end
    os.execute(command)
end

local function status_explanation(status)
    if status == "UNSTABLE" then
        return "不稳定：下降率或过载超过不稳定阈值"
    elseif status == "ATTENTION" then
        return "需注意：下降率或过载超过稳定阈值"
    end
    return "稳定：下降率和过载均在稳定阈值内"
end

local function roll_log_text(roll_deg)
    local abs_roll = abs_value(roll_deg)
    if abs_roll < 0.05 then
        return "水平（0.0 deg）"
    elseif roll_deg < 0 then
        return string.format("左倾 %.1f deg", abs_roll)
    end
    return string.format("右倾 %.1f deg", abs_roll)
end

local function vertical_speed_log_text(fpm)
    if fpm <= 0 then
        return string.format("%d fpm（向下 %d fpm）", fpm, abs_value(fpm))
    end
    return string.format("+%d fpm（向上）", fpm)
end

local function position_log_label(position_id)
    local labels = {
        top_left = "左上",
        top_center = "上方居中",
        top_right = "右上",
        middle_left = "左侧居中",
        center = "屏幕中央",
        middle_right = "右侧居中",
        bottom_left = "左下",
        bottom_center = "下方居中",
        bottom_right = "右下"
    }
    return labels[position_id] or "左侧居中"
end

local function next_log_file_path()
    local base_name = "LMM_" .. os.date("%Y-%m-%d_%H-%M-%S")
    local suffix = 0

    while suffix < 1000 do
        local file_name
        if suffix == 0 then
            file_name = base_name .. ".txt"
        else
            file_name = string.format("%s_%02d.txt", base_name, suffix)
        end

        local path = join_path(LOG_DIRECTORY_PATH, file_name)
        local existing = io.open(path, "r")
        if existing == nil then
            return path
        end
        existing:close()
        suffix = suffix + 1
    end

    return join_path(LOG_DIRECTORY_PATH, base_name .. "_extra.txt")
end

local function log_landing_summary()
    if logMsg then
        logMsg(string.format(
            "[StarLux LMM] FPM last=%d selected=%d | G touch=%.2f rawPeak=%.2f robust=%.2f cap=%.2f used=%.2f | IAS=%.0f GS=%.0f AoA=%.1f Roll=%.1f | Wind=%03d/%dkt | WindRel=%s | Mode=%s | Layout=%s",
            debug_data.last_frame_fpm,
            debug_data.selected_fpm,
            landing_touch_g,
            landing_peak_g,
            debug_data.robust_g,
            debug_data.expected_max_g,
            landing_g,
            landing_ias_kts,
            landing_gs_kts,
            landing_aoa_deg,
            landing_roll_deg,
            round_num(normalize_deg(landing_wind_heading_deg)),
            round_num(landing_wind_speed_kts),
            landing_wind_relative_text,
            POPUP_MODE,
            POPUP_LAYOUT
        ))
    end
end

local function write_landing_log()
    -- 日志目录已在脚本加载阶段创建；落地时不再调用 os.execute，避免瞬时卡顿。
    local log_path = next_log_file_path()
    local file, err = io.open(log_path, "w")
    if file == nil then
        if logMsg then
            logMsg("[StarLux LMM] Unable to write landing log: " .. tostring(err))
        end
        return false
    end

    file:write("\239\187\191")
    file:write("StarLux 落地率插件 - 单次落地记录\n")
    file:write("============================================================\n")
    file:write("落地时间（本地时间）: " .. landing_timestamp .. "\n")
    file:write("落地评价: " .. landing_status .. "\n")
    file:write("评价说明: " .. status_explanation(landing_status) .. "\n\n")

    file:write("触地数据\n")
    file:write("------------------------------------------------------------\n")
    file:write("触地垂直速度: " .. vertical_speed_log_text(landing_fpm) .. "\n")
    file:write(string.format("最终过载: %.2f G\n", landing_g))
    file:write(string.format("指示空速（IAS）: %.0f kt\n", landing_ias_kts))
    file:write(string.format("真空速（TAS）: %.0f kt\n", landing_tas_kts))
    file:write(string.format("地速（GS）: %.0f kt\n", landing_gs_kts))
    file:write(string.format("迎角: %.1f deg\n", landing_aoa_deg))
    file:write("横滚角: " .. roll_log_text(landing_roll_deg) .. "\n")
    file:write(string.format("飞机磁航向: %03d deg\n", round_num(normalize_deg(landing_heading_deg))))
    file:write(string.format("风向和风速: 来自 %03d deg，%d kt\n", round_num(normalize_deg(landing_wind_heading_deg)), round_num(landing_wind_speed_kts)))
    file:write("相对风: " .. landing_wind_relative_text .. "\n\n")

    file:write("测量明细\n")
    file:write("------------------------------------------------------------\n")
    file:write(string.format("触地帧过载: %.2f G\n", landing_touch_g))
    file:write(string.format("短窗口原始峰值: %.2f G\n", landing_peak_g))
    file:write(string.format("稳健采样值: %.2f G\n", debug_data.robust_g))
    file:write(string.format("FPM/G 一致性上限: %.2f G\n", debug_data.expected_max_g))
    file:write(string.format("最终显示和评分值: %.2f G\n\n", landing_g))

    file:write("评分阈值\n")
    file:write("------------------------------------------------------------\n")
    file:write(string.format("稳定上限: 下降率不大于 %d fpm，过载不大于 %.2f G\n", FPM_STABLE_MAX, G_STABLE_MAX))
    file:write(string.format("注意上限: 下降率不大于 %d fpm，过载不大于 %.2f G\n", FPM_ATTENTION_MAX, G_ATTENTION_MAX))
    file:write("超过任意注意上限时，评价为 UNSTABLE。\n\n")

    file:write("本次使用的显示设置\n")
    file:write("------------------------------------------------------------\n")
    file:write("弹窗时机: " .. (POPUP_MODE == "touchdown" and "触地时" or "地速低于 30 kt 时") .. "\n")
    file:write("显示时长: " .. tostring(DISPLAY_SECONDS) .. " 秒\n")
    file:write("屏幕位置: " .. position_log_label(POPUP_POSITION) .. "\n")
    file:write("窗口布局: " .. (POPUP_LAYOUT == "vertical" and "竖向" or "横向") .. "\n")
    file:write("背景透明度档位: " .. tostring(PANEL_OPACITY_LEVEL) .. "%\n")
    file:close()

    if logMsg then
        logMsg("[StarLux LMM] Landing log saved: " .. log_path)
    end
    return true
end

local storage_init_ok, storage_init_error = pcall(function()
    ensure_log_directory()
    load_settings()
end)

if not storage_init_ok then
    settings_save_ok = false
    if logMsg then
        logMsg("[StarLux LMM] Storage initialization failed; the meter will continue without persistence: " .. tostring(storage_init_error))
    end
end

-- =========================
-- 设置窗口
-- =========================

function ma_settings_window_closed(wnd)
    settings_window = nil
end

function ma_open_settings_window()
    if not SUPPORTS_FLOATING_WINDOWS then
        if logMsg then
            logMsg("[StarLux LMM] This FlyWithLua version does not support floating windows.")
        end
        return
    end

    if settings_window ~= nil then
        return
    end

    settings_window = float_wnd_create(520, 555, 1, true)
    float_wnd_set_title(settings_window, "StarLux Landing Meter - Settings")
    float_wnd_set_imgui_builder(settings_window, "ma_build_settings_window")
    float_wnd_set_onclose(settings_window, "ma_settings_window_closed")

    local screen_w = SCREEN_WIDTH or 1920
    local screen_h = SCREEN_HIGHT or 1080
    float_wnd_set_position(settings_window, math.floor((screen_w - 520) / 2), math.floor((screen_h - 555) / 2))
end

function ma_build_settings_window(wnd, x, y)
    imgui.TextUnformatted("Landing data popup timing")
    if imgui.RadioButton("Show at touchdown", POPUP_MODE == "touchdown") then
        POPUP_MODE = "touchdown"
        save_settings()
    end
    if imgui.RadioButton("Show after slowing below 30 kt", POPUP_MODE == "taxi") then
        POPUP_MODE = "taxi"
        save_settings()
    end

    imgui.Separator()
    imgui.TextUnformatted("Popup duration")
    if imgui.RadioButton("30 seconds", DISPLAY_SECONDS == 30) then
        DISPLAY_SECONDS = 30
        save_settings()
    end
    imgui.SameLine()
    if imgui.RadioButton("60 seconds", DISPLAY_SECONDS == 60) then
        DISPLAY_SECONDS = 60
        save_settings()
    end
    imgui.SameLine()
    if imgui.RadioButton("120 seconds (maximum)", DISPLAY_SECONDS == 120) then
        DISPLAY_SECONDS = 120
        save_settings()
    end

    imgui.Separator()
    imgui.TextUnformatted("Popup position")
    if imgui.BeginCombo("Screen position##lmm_position", position_label(POPUP_POSITION)) then
        for i = 1, #POSITION_OPTIONS do
            local option = POSITION_OPTIONS[i]
            if imgui.Selectable(option.label, POPUP_POSITION == option.id) then
                POPUP_POSITION = option.id
                save_settings()
            end
        end
        imgui.EndCombo()
    end

    imgui.Separator()
    imgui.TextUnformatted("Popup layout")
    if imgui.RadioButton("Horizontal - accent on the left", POPUP_LAYOUT == "horizontal") then
        POPUP_LAYOUT = "horizontal"
        save_settings()
    end
    if imgui.RadioButton("Vertical - accent on the top", POPUP_LAYOUT == "vertical") then
        POPUP_LAYOUT = "vertical"
        save_settings()
    end

    imgui.Separator()
    imgui.TextUnformatted("Background opacity")
    if imgui.RadioButton("25%", PANEL_OPACITY_LEVEL == 25) then
        PANEL_OPACITY_LEVEL = 25
        save_settings()
    end
    imgui.SameLine()
    if imgui.RadioButton("50%", PANEL_OPACITY_LEVEL == 50) then
        PANEL_OPACITY_LEVEL = 50
        save_settings()
    end
    imgui.SameLine()
    if imgui.RadioButton("100%", PANEL_OPACITY_LEVEL == 100) then
        PANEL_OPACITY_LEVEL = 100
        save_settings()
    end

    imgui.Separator()
    local changed, new_debug_value = imgui.Checkbox("Show measurement debug details", DEBUG_MODE)
    if changed then
        DEBUG_MODE = new_debug_value
        save_settings()
    end

    if imgui.Button("Preview popup for 5 seconds", 220, 28) then
        show_until = current_sim_time() + 5
    end

    imgui.Separator()
    if settings_save_ok then
        imgui.TextUnformatted("Settings are saved automatically.")
    else
        imgui.TextUnformatted("Warning: settings could not be saved. Check FlyWithLua Log.txt.")
    end
    imgui.TextUnformatted("Each completed landing is saved as a TXT file in:")
    imgui.TextUnformatted(LOG_DIRECTORY_PATH)
end

add_macro("StarLux Landing Meter | Open Settings", "ma_open_settings_window()")
create_command(
    "starlux/lmm/open_settings",
    "Open StarLux Landing Meter settings",
    "ma_open_settings_window()",
    "",
    ""
)

-- =========================
-- 核心逻辑
-- =========================

function ma_landing_meter_update()
    local now = current_sim_time()

    -- 每帧通过 XPLM 句柄读取一次所有必需数据，避免重复读取。
    local vs_fpm = lmm_get_float("vs_fpm")
    local y_agl_m = lmm_get_float("y_agl_m")
    local on_ground = lmm_get_int("on_ground")
    local current_g = lmm_get_float("g_normal")
    local roll_deg = lmm_get_float("roll_deg")
    local groundspeed_mps = lmm_get_float("groundspeed_mps")
    local ias_kts = lmm_get_float("ias_kts")
    local tas_kts = lmm_get_float("tas_kts")
    local aoa_deg = lmm_get_float("aoa_deg")
    local wind_speed_kts = lmm_get_float("wind_speed_kts")
    local wind_heading_deg_mag = lmm_get_float("wind_heading_deg_mag")
    local heading_deg_mag = lmm_get_float("heading_deg_mag")

    local radio_alt_ft = meters_to_feet(y_agl_m)
    local gs_kt = mps_to_kt(groundspeed_mps)

    -- 只有飞机达到一定离地高度和速度后才进入待触发状态。
    -- 这样可以避免载入已经停在地面的飞机时误弹出数据窗。
    if on_ground == 0 and radio_alt_ft > 20 and gs_kt > 50 then
        if armed == false then
            clear_vs_samples()
            clear_g_samples()
        end
        armed = true
        landing_complete = false
        taxi_popup_done = false
    end

    -- 在近地进近阶段持续保存最后的飞行数据快照。
    -- 垂直速度采样缓冲区只在较低离地高度内工作。
    if on_ground == 0 and armed == true and radio_alt_ft < 500 then
        approach_data.vs_fpm = vs_fpm
        approach_data.ias_kts = ias_kts
        approach_data.tas_kts = tas_kts
        approach_data.gs_kts = gs_kt
        approach_data.aoa_deg = aoa_deg
        approach_data.roll_deg = roll_deg
        approach_data.wind_speed_kts = wind_speed_kts
        approach_data.wind_heading_deg = wind_heading_deg_mag
        approach_data.heading_deg = heading_deg_mag

        if radio_alt_ft <= VS_SAMPLE_MAX_AGL_FT then
            add_vs_sample(now, vs_fpm)
        end
    end

    -- 触地检测：状态从离地变为接地。
    if armed == true and was_on_ground == 0 and on_ground == 1 and gs_kt > 35 then
        landing_active = true
        landing_complete = false
        landing_timestamp = os.date("%Y-%m-%d %H:%M:%S")

        approach_data.selected_vs_fpm = select_final_vs_fpm()
        landing_fpm = round_num(approach_data.selected_vs_fpm)

        clear_g_samples()
        local clean_touch_g = sanitize_g(current_g)
        if clean_touch_g == nil then
            clean_touch_g = 1.00
        end

        landing_touch_g = clean_touch_g
        landing_peak_g = clean_touch_g
        landing_g = clean_touch_g
        add_g_sample(now, clean_touch_g)

        landing_ias_kts = approach_data.ias_kts
        landing_tas_kts = approach_data.tas_kts
        landing_gs_kts = approach_data.gs_kts
        landing_aoa_deg = approach_data.aoa_deg
        landing_roll_deg = approach_data.roll_deg
        landing_wind_speed_kts = approach_data.wind_speed_kts
        landing_wind_heading_deg = approach_data.wind_heading_deg
        landing_heading_deg = approach_data.heading_deg
        landing_wind_relative_text = build_wind_relative_text(
            landing_wind_heading_deg,
            landing_wind_speed_kts,
            landing_heading_deg
        )

        debug_data.last_frame_fpm = round_num(approach_data.vs_fpm)
        debug_data.selected_fpm = landing_fpm
        debug_data.touch_g = landing_touch_g
        debug_data.peak_g = landing_peak_g
        debug_data.robust_g = landing_touch_g
        debug_data.expected_max_g = max_logical_g_from_fpm(landing_fpm)
        debug_data.used_g = landing_g

        g_capture_until = now + G_CAPTURE_SECONDS

    end

    -- 在触地后的短时间内采集 G 值峰值。
    if landing_active == true then
        -- 只收集合理范围内的 G 值样本。原始峰值仍会保留用于调试，
        -- 但不会再被直接用于评分或显示。
        local clean_current_g = sanitize_g(current_g)
        if clean_current_g ~= nil then
            add_g_sample(now, clean_current_g)
            if clean_current_g > landing_peak_g then
                landing_peak_g = clean_current_g
            end
        end

        debug_data.peak_g = landing_peak_g

        if now >= g_capture_until then
            if USE_PEAK_G_FOR_SCORE then
                landing_g, debug_data.robust_g, debug_data.expected_max_g = compute_landing_g(landing_fpm)
            else
                landing_g = landing_touch_g
                debug_data.robust_g = landing_touch_g
                debug_data.expected_max_g = max_logical_g_from_fpm(landing_fpm)
            end
            debug_data.used_g = landing_g

            landing_status = classify_landing(landing_fpm, landing_g, EXTERNAL_SCORE_HINT)
            landing_active = false
            landing_complete = true
            armed = false
            clear_vs_samples()
            clear_g_samples()

            -- 等 G 值和最终评级全部计算完成后才显示窗口，
            -- 避免先显示触地帧的绿色 STABLE，再快速变成黄/红色。
            if POPUP_MODE == "touchdown" then
                show_until = now + DISPLAY_SECONDS
            end

            -- 触地关键帧只完成计算和显示；日志输出及 TXT 写入延后执行。
            landing_log_pending = true
            landing_log_write_after = now + LOG_WRITE_DELAY_SECONDS
        end
    end

    -- 低速弹窗模式：落地后地速低于 30 节时显示。
    if POPUP_MODE == "taxi" and landing_complete == true and taxi_popup_done == false then
        if gs_kt <= TAXI_POPUP_SPEED_KT then
            show_until = now + DISPLAY_SECONDS
            taxi_popup_done = true
        end
    end

    -- 在弹窗已经稳定显示后再保存日志，避免系统命令和磁盘 I/O 与触地首帧重叠。
    if landing_log_pending == true and now >= landing_log_write_after then
        landing_log_pending = false
        log_landing_summary()
        local log_ok, log_error = pcall(write_landing_log)
        if not log_ok and logMsg then
            logMsg("[StarLux LMM] Landing log failed, but flight monitoring will continue: " .. tostring(log_error))
        end
    end

    was_on_ground = on_ground
end

-- =========================
-- 数据窗绘制
-- =========================

function ma_landing_meter_draw()
    local now = current_sim_time()

    if show_until <= 0 or now > show_until then
        return
    end

    local screen_w = SCREEN_WIDTH or 1920
    local screen_h = SCREEN_HIGHT or 1080

    local panel_w = HORIZONTAL_PANEL_W
    local panel_h = HORIZONTAL_PANEL_H
    if POPUP_LAYOUT == "vertical" then
        panel_w = VERTICAL_PANEL_W
        panel_h = VERTICAL_PANEL_H
    end

    local x, y = calculate_popup_position(screen_w, screen_h, panel_w, panel_h)

    local r, g, b = status_color(landing_status)

    -- 恢复浅色半透明状态底板。拖影问题改由移出触地关键帧的日志写入解决，
    -- 不再用深色不透明色块遮挡驾驶舱画面。
    XPLMSetGraphicsState(0, 0, 0, 1, 1, 0, 0)
    glColor4f(r, g, b, panel_alpha())
    glRectf(x, y, x + panel_w, y + panel_h)

    glColor4f(r, g, b, 0.96)
    if POPUP_LAYOUT == "vertical" then
        glRectf(x, y + panel_h - ACCENT_THICKNESS, x + panel_w, y + panel_h)
    else
        glRectf(x, y, x + ACCENT_THICKNESS, y + panel_h)
    end
    draw_panel_border(x, y, panel_w, panel_h, r, g, b)

    local line1 = string.format("%+d fpm | +%.2fG", landing_fpm, landing_g)
    local line2 = string.format("IAS %.0fkt | GS %.0fkt", landing_ias_kts, landing_gs_kts)
    local line3 = string.format("迎角 %.1f° | %s", landing_aoa_deg, format_roll_text(landing_roll_deg))
    local line4 = landing_wind_relative_text
    local line5 = status_short(landing_status)

    local text_x = x + ACCENT_THICKNESS + 10
    -- 横向布局使用 90/70/50/30/10 的等距基线，使上下留白更加均衡。
    local line_y1 = y + 90
    local line_gap = 20
    if POPUP_LAYOUT == "vertical" then
        -- 竖向布局已经协调，不随横向布局的基线调整而改变。
        text_x = x + 14
        line_y1 = y + 133
        line_gap = 27
    end

    -- 文字只绘制一次，不使用阴影，避免小字号出现重影和模糊感。
    glColor4f(1, 1, 1, 0.98)
    draw_string(text_x, line_y1, line1)
    draw_string(text_x, line_y1 - line_gap, line2)
    draw_string(text_x, line_y1 - line_gap * 2, line3)
    draw_string(text_x, line_y1 - line_gap * 3, line4)
    draw_string(text_x, line_y1 - line_gap * 4, line5)

    if DEBUG_MODE == true then
        glColor4f(1, 1, 1, 0.86)
        local debug_line1 = string.format("DBG FPM last:%d sel:%d", debug_data.last_frame_fpm, debug_data.selected_fpm)
        local debug_line2 = string.format("DBG G touch:%.2f rawPk:%.2f", debug_data.touch_g, debug_data.peak_g)
        local debug_line3 = string.format("DBG G rb:%.2f cap:%.2f used:%.2f", debug_data.robust_g, debug_data.expected_max_g, debug_data.used_g)
        local debug_x = x + panel_w + 12
        if debug_x + 270 > screen_w then
            debug_x = math.max(0, x - 282)
        end
        draw_string(debug_x, y + 70, debug_line1)
        draw_string(debug_x, y + 48, debug_line2)
        draw_string(debug_x, y + 26, debug_line3)
    end
end

do_every_frame("ma_landing_meter_update()")
do_every_draw("ma_landing_meter_draw()")

if logMsg then
    logMsg(string.format(
        "[StarLux LMM] v0.7 loaded successfully with %d direct XPLM DataRefs.",
        #LMM_DATAREF_SPECS
    ))
end

-- StarLux 落地率插件 v0.7.2 正式版
-- 适用于 X-Plane 12 + FlyWithLua
-- v0.7.2 新增四级评分、冲量一致性分析、低频道面监测，并将跑道号写入报告文件名。

-- =========================
-- 用户设置
-- =========================

local POPUP_MODE = "immediate"
-- "immediate" = 落地分析完成后立即显示
-- "taxi"      = 地速降低到 30 节以下时显示

local DISPLAY_SECONDS = 30
-- 第一次起落架压缩最多采集 0.35 秒；满足停止或反弹条件时会提前结束。
local IMPACT_CAPTURE_MAX_SECONDS = 0.35
local PRE_TOUCH_BUFFER_SECONDS = 0.50
-- 触地状态可能比实际接触晚一至数帧；使用触地前 250 毫秒物理速度的第 25 百分位，避开末端接近零的滞后样本。
local PHYSICAL_FPM_WINDOW_SECONDS = 0.25
local PHYSICAL_FPM_SHORT_WINDOW_SECONDS = 0.08
local PHYSICAL_FPM_PERCENTILE = 0.25
local VVI_DIAGNOSTIC_WINDOW_SECONDS = 0.85
local G_BASELINE_WINDOW_SECONDS = 0.20
local IMPACT_STOP_VY_MPS = -0.05
local IMPACT_STOP_STABLE_FRAMES = 3
local TAXI_POPUP_SPEED_KT = 30

-- 紧凑型数据窗；设置窗口提供九种屏幕位置。
local POPUP_POSITION = "middle_left"
local POPUP_LAYOUT = "horizontal"
-- "horizontal" = 横向数据窗，状态色粗边位于左侧
-- "vertical"   = 竖向数据窗，状态色粗边位于上方
local HORIZONTAL_PANEL_W = 365
local HORIZONTAL_PANEL_H = 132
local VERTICAL_PANEL_W = 235
local VERTICAL_PANEL_H = 195
local ACCENT_THICKNESS = 12
local BORDER_ALPHA = 0.78
local PANEL_OPACITY_LEVEL = 25
-- 25 档为默认浅透明效果；50 档保持 v0.6.3 的视觉效果；100 档强度最高。
local PANEL_ALPHA_LEVELS = {
    [25] = 0.18,
    [50] = 0.30,
    [100] = 0.60
}

-- 机场识别与 TXT 写入分阶段延后，避免触地关键阶段执行导航查询和磁盘操作。
local CONTEXT_RESOLVE_DELAY_SECONDS = 3.0
local LOG_WRITE_DELAY_SECONDS = 8.0
local REPORT_NOTICE_SECONDS = 6.0
local MAX_AIRPORT_DISTANCE_KM = 15.0

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

local VS_SAMPLE_MAX_AGL_FT = 120

-- 冲量一致性算法参数。
local SAMPLE_BUFFER_SIZE = 256
local G_CURVE_PERCENTILE = 0.75
local HIGH_G_DURATION_MIN_SECONDS = 0.030
local CONSISTENCY_HIGH_MAX_ERROR = 0.25
local CONSISTENCY_MEDIUM_MAX_ERROR = 0.60
local MAX_VALID_SAMPLE_GAP_SECONDS = 0.050
local G_FPM_DECEL_TIME_SECONDS = 0.42
local G_FALLBACK_MARGIN_NICE = 0.08
local G_FALLBACK_MARGIN_STABLE = 0.12
local G_FALLBACK_MARGIN_ATTENTION = 0.16
local G_FALLBACK_MARGIN_UNSTABLE = 0.22

-- 四级评分阈值。FPM 与 G 分别判断，最终取两项中较严重的等级。
local FPM_NICE_MAX = 100
local FPM_STABLE_MAX = 250
local FPM_ATTENTION_MAX = 300

local G_NICE_MAX = 1.20
local G_STABLE_MAX = 1.50
local G_ATTENTION_MAX = 1.80

-- 触地前道面状态监测。只在低于 1500 英尺 AGL 时每 5 秒采样一次。
local WEATHER_SAMPLE_INTERVAL_SECONDS = 5.0
local WEATHER_MONITOR_MAX_AGL_FT = 1500
local SURFACE_LOOKBACK_SECONDS = 180.0
local PRECIPITATION_DETECTION_THRESHOLD = 0.05
local PRECIPITATION_CONFIRM_SAMPLES = 2
local RUNWAY_FRICTION_WET_MIN = 1.0

-- 预留的外部评分接口。
-- 当前保持为 nil，以后可在这里接入其他计算得到的着陆质量指标。
-- 可接受的值：nil、"NICE"、"STABLE"、"ATTENTION" 或 "UNSTABLE"。
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
    { key = "local_vy_mps", path = "sim/flightmodel/position/local_vy", kind = "float" },
    { key = "y_agl_m", path = "sim/flightmodel/position/y_agl", kind = "float" },
    { key = "on_ground", path = "sim/flightmodel/failures/onground_any", kind = "int" },
    { key = "g_normal", path = "sim/flightmodel/forces/g_nrml", kind = "float" },
    { key = "roll_deg", path = "sim/flightmodel/position/phi", kind = "float" },
    { key = "pitch_deg", path = "sim/flightmodel/position/theta", kind = "float" },
    { key = "groundspeed_mps", path = "sim/flightmodel/position/groundspeed", kind = "float" },
    { key = "running_time_sec", path = "sim/time/total_running_time_sec", kind = "float" },
    { key = "ias_kts", path = "sim/cockpit2/gauges/indicators/airspeed_kts_pilot", kind = "float" },
    { key = "tas_kts", path = "sim/cockpit2/gauges/indicators/true_airspeed_kts_pilot", kind = "float" },
    { key = "aoa_deg", path = "sim/flightmodel/position/alpha", kind = "float" },
    { key = "wind_speed_kts", path = "sim/cockpit2/gauges/indicators/wind_speed_kts", kind = "float" },
    { key = "wind_heading_deg_mag", path = "sim/cockpit2/gauges/indicators/wind_heading_deg_mag", kind = "float" },
    { key = "heading_deg_mag", path = "sim/flightmodel/position/mag_psi", kind = "float" },
    { key = "latitude_deg", path = "sim/flightmodel/position/latitude", kind = "double" },
    { key = "longitude_deg", path = "sim/flightmodel/position/longitude", kind = "double" },
    { key = "aircraft_precipitation_ratio", path = "sim/weather/aircraft/precipitation_on_aircraft_ratio", kind = "float" },
    { key = "region_runway_friction", path = "sim/weather/region/runway_friction", kind = "float" }
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

local function lmm_get_double(key)
    local handle = LMM_DATAREFS[key]
    if handle == nil then return 0 end
    return XPLMGetDatad(handle)
end

if #lmm_missing_datarefs > 0 and logMsg then
    logMsg("[StarLux LMM] Missing required DataRefs: " .. table.concat(lmm_missing_datarefs, ", "))
end

-- =========================
-- 内部状态
-- =========================

local armed = false
local was_on_ground = 1

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
    pitch_deg = 0,
    wind_speed_kts = 0,
    wind_heading_deg = 0,
    heading_deg = 0
}

local landing_complete = false

-- 固定长度环形缓冲区在脚本加载时一次性分配，触地阶段不再创建逐帧小表。
local sample_buffer = {
    slots = {},
    write_index = 0,
    count = 0
}
for i = 1, SAMPLE_BUFFER_SIZE do
    sample_buffer.slots[i] = {
        t = 0,
        vvi_fpm = 0,
        local_vy_mps = 0,
        g_normal = 1,
        pitch_deg = 0,
        roll_deg = 0,
        on_ground = 0
    }
end

local sort_scratch = {}
local sort_scratch_count = 0

local landing_analysis = {
    phase = "idle",
    touch_time = 0,
    impact_start_time = 0,
    impact_end_time = 0,
    end_time = 0,
    capture_deadline = 0,
    stop_stable_frames = 0,
    stop_candidate_time = 0,
    vvi_fpm = 0,
    vvi_min_fpm = 0,
    physical_fpm = 0,
    physical_short_fpm = 0,
    fpm_difference = 0,
    physical_fpm_valid = false,
    physical_sample_count = 0,
    pre_vy_mps = 0,
    post_vy_mps = 0,
    velocity_delta_mps = 0,
    baseline_g = 1,
    curve_g = 1,
    equivalent_g = 1,
    impulse_delta_mps = 0,
    consistency_error = 1,
    confidence = "LOW",
    method = "等待分析",
    stop_duration_seconds = 0,
    high_g_duration_seconds = 0,
    impact_sample_count = 0,
    average_sample_gap_seconds = 0,
    max_sample_gap_seconds = 0,
    analysis_ms = 0,
    finalize_ms = 0,
    used_fallback = false
}

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
local landing_status = "NICE"
local landing_timestamp = ""
local landing_context = {
    aircraft_icao = "UNKNOWN",
    aircraft_file = "",
    airport_id = "识别中",
    airport_name = "",
    airport_distance_km = 0,
    runway = "--",
    touch_latitude = 0,
    touch_longitude = 0,
    file_timestamp = ""
}
local surface_watch = {
    last_sample_time = -1000,
    last_friction_time = -1000,
    last_rain_time = -1000,
    consecutive_rain_samples = 0,
    max_consecutive_rain_samples = 0,
    peak_precipitation_ratio = 0,
    max_runway_friction = 0
}
local landing_surface = {
    wet_warning = false,
    warning_type = "none",
    warning_text = "",
    source_text = "未检测到持续降雨或湿滑道面",
    precipitation_ratio = 0,
    consecutive_rain_samples = 0,
    runway_friction = 0
}

local debug_data = {
    last_frame_fpm = 0,
    selected_fpm = 0,
    touch_g = 0,
    peak_g = 0,
    robust_g = 0,
    expected_max_g = 0,
    used_g = 0,
    physical_fpm = 0,
    fpm_difference = 0,
    consistency_error = 0,
    confidence = "LOW",
    analysis_ms = 0
}

local show_until = 0
local taxi_popup_done = false
local settings_window = nil
local landing_jobs = {
    context_pending = false,
    context_after = 0,
    log_pending = false,
    log_after = 0
}
local landing_report_notice = {
    text = "",
    until_time = 0
}
local popup_cache = {
    lines = { "", "", "", "", "", "" },
    warning_text = ""
}

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

local function trim_text(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function sanitize_filename_token(value)
    local token = string.upper(trim_text(value)):gsub("[^%w%-]", "")
    if token == "" or token == "UNKNOWN" then
        return "UNKNOWN"
    end
    return token
end

local function estimated_runway_from_heading(heading_deg)
    local runway_number = math.floor((normalize_deg(heading_deg) + 5) / 10)
    if runway_number == 0 or runway_number == 36 then
        runway_number = 36
    elseif runway_number > 36 then
        runway_number = runway_number - 36
    end
    return string.format("%02d", runway_number)
end

local function distance_km(lat1, lon1, lat2, lon2)
    local radians = math.pi / 180
    local d_lat = (lat2 - lat1) * radians
    local d_lon = (lon2 - lon1) * radians
    local a = math.sin(d_lat / 2) ^ 2
        + math.cos(lat1 * radians) * math.cos(lat2 * radians) * math.sin(d_lon / 2) ^ 2
    local limited_a = math.min(1, math.max(0, a))
    return 6371.0 * 2 * math.asin(math.sqrt(limited_a))
end

local function begin_landing_context()
    local aircraft_icao = ""
    if type(PLANE_ICAO) == "string" then
        aircraft_icao = string.upper(trim_text(PLANE_ICAO))
    end

    local aircraft_file = ""
    if type(AIRCRAFT_FILENAME) == "string" then
        aircraft_file = trim_text(AIRCRAFT_FILENAME)
    end

    if aircraft_icao == "" and aircraft_file ~= "" then
        aircraft_icao = string.upper(aircraft_file:gsub("%.[Aa][Cc][Ff]$", ""))
    end
    if aircraft_icao == "" then
        aircraft_icao = "UNKNOWN"
    end

    landing_context.aircraft_icao = aircraft_icao
    landing_context.aircraft_file = aircraft_file
    landing_context.airport_id = "识别中"
    landing_context.airport_name = ""
    landing_context.airport_distance_km = 0
    landing_context.runway = estimated_runway_from_heading(landing_heading_deg)
    landing_context.touch_latitude = lmm_get_double("latitude_deg")
    landing_context.touch_longitude = lmm_get_double("longitude_deg")
    landing_context.file_timestamp = os.date("%Y-%m-%d_%H-%M-%S")
    landing_report_notice.text = ""
    landing_report_notice.until_time = 0
end

local runway_friction_text

local function reset_surface_watch(now)
    surface_watch.last_sample_time = now - WEATHER_SAMPLE_INTERVAL_SECONDS
    surface_watch.last_friction_time = -1000
    surface_watch.last_rain_time = -1000
    surface_watch.consecutive_rain_samples = 0
    surface_watch.max_consecutive_rain_samples = 0
    surface_watch.peak_precipitation_ratio = 0
    surface_watch.max_runway_friction = 0
end

local function update_prelanding_surface_watch(now)
    -- 模拟时间倒退通常意味着重新载入航班，此时丢弃上一航班的气象快照。
    if now < surface_watch.last_sample_time then
        reset_surface_watch(now)
    end
    if now - surface_watch.last_sample_time < WEATHER_SAMPLE_INTERVAL_SECONDS then
        return
    end
    surface_watch.last_sample_time = now

    if now - surface_watch.last_friction_time > SURFACE_LOOKBACK_SECONDS then
        surface_watch.max_runway_friction = 0
    end
    if now - surface_watch.last_rain_time > SURFACE_LOOKBACK_SECONDS then
        surface_watch.peak_precipitation_ratio = 0
        surface_watch.max_consecutive_rain_samples = 0
    end

    local precipitation_ratio = lmm_get_float("aircraft_precipitation_ratio")
    local runway_friction = lmm_get_float("region_runway_friction")

    if runway_friction >= RUNWAY_FRICTION_WET_MIN then
        surface_watch.last_friction_time = now
        surface_watch.max_runway_friction = math.max(surface_watch.max_runway_friction, runway_friction)
    end

    if precipitation_ratio >= PRECIPITATION_DETECTION_THRESHOLD then
        surface_watch.consecutive_rain_samples = surface_watch.consecutive_rain_samples + 1
        surface_watch.max_consecutive_rain_samples = math.max(
            surface_watch.max_consecutive_rain_samples,
            surface_watch.consecutive_rain_samples
        )
        surface_watch.peak_precipitation_ratio = math.max(
            surface_watch.peak_precipitation_ratio,
            precipitation_ratio
        )
        if surface_watch.consecutive_rain_samples >= PRECIPITATION_CONFIRM_SAMPLES then
            surface_watch.last_rain_time = now
        end
    else
        surface_watch.consecutive_rain_samples = 0
    end
end

local function capture_landing_surface(now)
    local friction_recent = now - surface_watch.last_friction_time <= SURFACE_LOOKBACK_SECONDS
    local rain_recent = now - surface_watch.last_rain_time <= SURFACE_LOOKBACK_SECONDS

    landing_surface.precipitation_ratio = surface_watch.peak_precipitation_ratio
    landing_surface.consecutive_rain_samples = surface_watch.max_consecutive_rain_samples
    landing_surface.runway_friction = surface_watch.max_runway_friction

    if friction_recent then
        landing_surface.wet_warning = true
        landing_surface.warning_type = "friction"
        landing_surface.warning_text = "道面湿滑，注意摩擦力"
        landing_surface.source_text = string.format(
            "X-Plane 跑道摩擦等级 %.0f（%s）",
            landing_surface.runway_friction,
            runway_friction_text(landing_surface.runway_friction)
        )
    elseif rain_recent then
        landing_surface.wet_warning = true
        landing_surface.warning_type = "rain"
        landing_surface.warning_text = "持续降雨，道面可能湿滑"
        landing_surface.source_text = string.format(
            "飞机实际降水连续达到阈值，峰值 %.0f%%",
            landing_surface.precipitation_ratio * 100
        )
    else
        landing_surface.wet_warning = false
        landing_surface.warning_type = "none"
        landing_surface.warning_text = ""
        landing_surface.source_text = "最近三分钟未确认持续降雨或湿滑道面"
        landing_surface.precipitation_ratio = 0
        landing_surface.consecutive_rain_samples = 0
        landing_surface.runway_friction = surface_watch.max_runway_friction
    end
end

runway_friction_text = function(value)
    if value >= 13 then
        return "积雪/结冰"
    elseif value >= 10 then
        return "结冰"
    elseif value >= 7 then
        return "积雪"
    elseif value >= 4 then
        return "积水"
    elseif value >= 1 then
        return "湿滑"
    end
    return "干燥"
end

local function resolve_landing_context()
    landing_context.airport_id = "UNKNOWN"
    landing_context.airport_name = ""
    landing_context.airport_distance_km = 0
    landing_context.runway = estimated_runway_from_heading(landing_heading_deg)

    local nav_ref = XPLMFindNavAid(
        nil,
        nil,
        landing_context.touch_latitude,
        landing_context.touch_longitude,
        nil,
        xplm_Nav_Airport
    )
    if nav_ref == nil or nav_ref == -1 then
        return false, "未找到附近机场"
    end

    local _, airport_lat, airport_lon, _, _, _, airport_id, airport_name = XPLMGetNavAidInfo(nav_ref)
    airport_id = string.upper(trim_text(airport_id))
    airport_name = trim_text(airport_name)
    if airport_id == "" then
        return false, "机场导航数据没有标识符"
    end

    local airport_distance = distance_km(
        landing_context.touch_latitude,
        landing_context.touch_longitude,
        airport_lat,
        airport_lon
    )
    if airport_distance > MAX_AIRPORT_DISTANCE_KM then
        return false, string.format("最近机场距离 %.1f km，超过识别范围", airport_distance)
    end

    landing_context.airport_id = airport_id
    landing_context.airport_name = airport_name
    landing_context.airport_distance_km = airport_distance
    return true
end

local function landing_context_short_text()
    local airport_text = landing_context.airport_id
    if airport_text == "识别中" then
        return string.format("%s | 机场识别中 | RWY ~%s", landing_context.aircraft_icao, landing_context.runway)
    end
    return string.format("%s | %s | RWY ~%s", landing_context.aircraft_icao, airport_text, landing_context.runway)
end

local function file_name_from_path(path)
    return tostring(path or ""):match("([^/\\]+)$") or tostring(path or "")
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
    -- 0 = 轻柔，1 = 稳定，2 = 需注意，3 = 重着陆。
    -- FPM 与 G 独立分档并取较严重者，因此不匹配组合不会被平均或相互抵消。

    if abs_fpm > FPM_ATTENTION_MAX or g > G_ATTENTION_MAX then
        level = 3
    elseif abs_fpm > FPM_STABLE_MAX or g > G_STABLE_MAX then
        level = 2
    elseif abs_fpm > FPM_NICE_MAX or g > G_NICE_MAX then
        level = 1
    end

    -- 为以后使用预留的外部评分接口。
    if external_hint == "UNSTABLE" then
        level = math.max(level, 3)
    elseif external_hint == "ATTENTION" then
        level = math.max(level, 2)
    elseif external_hint == "STABLE" then
        level = math.max(level, 1)
    end

    if level == 3 then
        return "UNSTABLE"
    elseif level == 2 then
        return "ATTENTION"
    elseif level == 1 then
        return "STABLE"
    else
        return "NICE"
    end
end

local function status_color(status)
    if status == "UNSTABLE" then
        return 0.72, 0.10, 0.12
    elseif status == "ATTENTION" then
        return 0.78, 0.52, 0.06
    elseif status == "STABLE" then
        return 0.07, 0.32, 0.62
    else
        return 0.08, 0.50, 0.24
    end
end

local function status_short(status)
    if status == "UNSTABLE" then
        return "UNSTABLE 重着陆"
    elseif status == "ATTENTION" then
        return "Attention 需注意"
    elseif status == "STABLE" then
        return "Stable 稳定扎实落地"
    else
        return "Nice 轻柔接地"
    end
end

local function confidence_text(confidence)
    if confidence == "HIGH" then return "高" end
    if confidence == "MEDIUM" then return "中" end
    return "低"
end

local function refresh_popup_cache()
    popup_cache.lines[1] = landing_context_short_text()
    popup_cache.lines[2] = string.format("%+d fpm | +%.2fG", landing_fpm, landing_g)
    popup_cache.lines[3] = string.format("IAS %.0fkt | GS %.0fkt", landing_ias_kts, landing_gs_kts)
    popup_cache.lines[4] = string.format(
        "迎角 %.1f° | %s",
        landing_aoa_deg,
        format_roll_text(landing_roll_deg)
    )
    popup_cache.lines[5] = landing_wind_relative_text
    popup_cache.lines[6] = status_short(landing_status)
    popup_cache.warning_text = landing_surface.warning_text
end

local function panel_alpha()
    return PANEL_ALPHA_LEVELS[PANEL_OPACITY_LEVEL] or PANEL_ALPHA_LEVELS[25]
end

local function sanitize_g(g)
    -- 保留 5 G 以内的原始值用于冲量诊断；更极端的值视为损坏样本。
    if g == nil then return nil end
    if g > 0.2 and g <= 5.0 then
        return g
    end
    return nil
end

local function reset_sample_buffer()
    sample_buffer.write_index = 0
    sample_buffer.count = 0
end

local function add_flight_sample(now, vvi_fpm, local_vy_mps, g_normal, pitch_deg, roll_deg, on_ground)
    local next_index = sample_buffer.write_index + 1
    if next_index > SAMPLE_BUFFER_SIZE then next_index = 1 end

    local slot = sample_buffer.slots[next_index]
    slot.t = now
    slot.vvi_fpm = vvi_fpm
    slot.local_vy_mps = local_vy_mps
    slot.g_normal = sanitize_g(g_normal) or 0
    slot.pitch_deg = pitch_deg
    slot.roll_deg = roll_deg
    slot.on_ground = on_ground

    sample_buffer.write_index = next_index
    if sample_buffer.count < SAMPLE_BUFFER_SIZE then
        sample_buffer.count = sample_buffer.count + 1
    end
end

local function sample_at(position)
    if position < 1 or position > sample_buffer.count then return nil end
    local oldest = sample_buffer.write_index - sample_buffer.count + 1
    while oldest <= 0 do oldest = oldest + SAMPLE_BUFFER_SIZE end
    local index = oldest + position - 1
    while index > SAMPLE_BUFFER_SIZE do index = index - SAMPLE_BUFFER_SIZE end
    return sample_buffer.slots[index]
end

local function projected_vertical_g(sample)
    if sample == nil or sample.g_normal <= 0 then return nil end
    local radians = math.pi / 180
    return sample.g_normal
        * math.cos(sample.pitch_deg * radians)
        * math.cos(sample.roll_deg * radians)
end

local function collect_sample_values(start_time, end_time, value_kind, airborne_only)
    local count = 0
    local old_count = sort_scratch_count

    for i = 1, sample_buffer.count do
        local sample = sample_at(i)
        if sample.t >= start_time and sample.t <= end_time
            and (not airborne_only or sample.on_ground == 0) then
            local value = nil
            if value_kind == "local_vy" then
                value = sample.local_vy_mps
            elseif value_kind == "vvi" then
                value = sample.vvi_fpm
            elseif value_kind == "projected_g" then
                value = projected_vertical_g(sample)
            end
            if value ~= nil then
                count = count + 1
                sort_scratch[count] = value
            end
        end
    end

    for i = count + 1, old_count do
        sort_scratch[i] = nil
    end
    sort_scratch_count = count
    if count > 1 then table.sort(sort_scratch) end
    return count
end

local function scratch_percentile(percentile)
    if sort_scratch_count == 0 then return nil end
    local index = math.ceil(sort_scratch_count * percentile)
    if index < 1 then index = 1 end
    if index > sort_scratch_count then index = sort_scratch_count end
    return sort_scratch[index]
end

local function scratch_median()
    if sort_scratch_count == 0 then return nil end
    local middle = math.floor((sort_scratch_count + 1) / 2)
    if sort_scratch_count % 2 == 0 then
        return (sort_scratch[middle] + sort_scratch[middle + 1]) / 2
    end
    return sort_scratch[middle]
end

local function select_min_vvi_fpm(touch_time)
    local selected = approach_data.vs_fpm
    for i = 1, sample_buffer.count do
        local sample = sample_at(i)
        if sample.on_ground == 0
            and sample.t >= touch_time - VVI_DIAGNOSTIC_WINDOW_SECONDS
            and sample.t <= touch_time
            and sample.vvi_fpm < selected then
            selected = sample.vvi_fpm
        end
    end
    return selected
end

local function fallback_g_cap(fpm)
    local abs_fpm = abs_value(fpm)
    local margin = G_FALLBACK_MARGIN_UNSTABLE
    if abs_fpm <= FPM_NICE_MAX then
        margin = G_FALLBACK_MARGIN_NICE
    elseif abs_fpm <= FPM_STABLE_MAX then
        margin = G_FALLBACK_MARGIN_STABLE
    elseif abs_fpm <= FPM_ATTENTION_MAX then
        margin = G_FALLBACK_MARGIN_ATTENTION
    end

    local sink_mps = abs_fpm * 0.00508
    return 1.0 + sink_mps / (G_FPM_DECEL_TIME_SECONDS * 9.80665) + margin
end

local function begin_landing_analysis(now)
    landing_analysis.phase = "capture"
    landing_analysis.touch_time = now
    landing_analysis.impact_start_time = now
    -- 接地状态按帧跳变，实际减速可能发生在上一帧至触地帧之间，因此保留最后一个离地样本作为积分起点。
    local previous_sample = sample_at(sample_buffer.count - 1)
    if previous_sample ~= nil
        and previous_sample.on_ground == 0
        and now - previous_sample.t > 0
        and now - previous_sample.t <= MAX_VALID_SAMPLE_GAP_SECONDS then
        landing_analysis.impact_start_time = previous_sample.t
    end
    landing_analysis.impact_end_time = now
    landing_analysis.end_time = now
    landing_analysis.capture_deadline = now + IMPACT_CAPTURE_MAX_SECONDS
    landing_analysis.stop_stable_frames = 0
    landing_analysis.stop_candidate_time = 0
    landing_analysis.vvi_fpm = 0
    landing_analysis.vvi_min_fpm = 0
    landing_analysis.physical_fpm = 0
    landing_analysis.physical_short_fpm = 0
    landing_analysis.fpm_difference = 0
    landing_analysis.physical_fpm_valid = false
    landing_analysis.physical_sample_count = 0
    landing_analysis.pre_vy_mps = 0
    landing_analysis.post_vy_mps = 0
    landing_analysis.velocity_delta_mps = 0
    landing_analysis.baseline_g = 1
    landing_analysis.curve_g = 1
    landing_analysis.equivalent_g = 1
    landing_analysis.impulse_delta_mps = 0
    landing_analysis.consistency_error = 1
    landing_analysis.confidence = "LOW"
    landing_analysis.method = "正在采集第一次起落架压缩"
    landing_analysis.stop_duration_seconds = 0
    landing_analysis.high_g_duration_seconds = 0
    landing_analysis.impact_sample_count = 0
    landing_analysis.average_sample_gap_seconds = 0
    landing_analysis.max_sample_gap_seconds = 0
    landing_analysis.analysis_ms = 0
    landing_analysis.finalize_ms = 0
    landing_analysis.used_fallback = false
end

local function analyze_landing_velocity()
    local started = os.clock()
    local touch_time = landing_analysis.touch_time
    local buffer_start_time = touch_time - PRE_TOUCH_BUFFER_SECONDS

    local short_count = collect_sample_values(
        math.max(buffer_start_time, touch_time - PHYSICAL_FPM_SHORT_WINDOW_SECONDS),
        touch_time,
        "local_vy",
        true
    )
    local short_physical_vy = scratch_median()
    if short_count >= 2 and short_physical_vy ~= nil then
        landing_analysis.physical_short_fpm = short_physical_vy * 196.850394
    end

    local physical_count = collect_sample_values(
        math.max(buffer_start_time, touch_time - PHYSICAL_FPM_WINDOW_SECONDS),
        touch_time,
        "local_vy",
        true
    )
    local physical_vy = scratch_percentile(PHYSICAL_FPM_PERCENTILE)
    landing_analysis.physical_sample_count = physical_count
    landing_analysis.physical_fpm_valid = physical_count >= 3 and physical_vy ~= nil

    collect_sample_values(
        math.max(buffer_start_time, touch_time - PHYSICAL_FPM_WINDOW_SECONDS),
        touch_time,
        "vvi",
        true
    )
    landing_analysis.vvi_fpm = scratch_median() or approach_data.vs_fpm
    landing_analysis.vvi_min_fpm = select_min_vvi_fpm(touch_time)

    if landing_analysis.physical_fpm_valid then
        landing_analysis.physical_fpm = physical_vy * 196.850394
        landing_fpm = round_num(landing_analysis.physical_fpm)
    else
        landing_analysis.physical_fpm = landing_analysis.vvi_fpm
        landing_fpm = round_num(landing_analysis.vvi_fpm)
    end

    -- 250 毫秒分位值用于落地率显示和评分；冲量只对应第一次压缩，必须使用紧邻接地的短窗速度。
    if short_count >= 2 and short_physical_vy ~= nil then
        landing_analysis.pre_vy_mps = short_physical_vy
    elseif landing_analysis.physical_fpm_valid then
        landing_analysis.pre_vy_mps = physical_vy
    else
        landing_analysis.pre_vy_mps = landing_analysis.vvi_fpm * 0.00508
    end

    landing_analysis.fpm_difference = landing_analysis.physical_fpm - landing_analysis.vvi_fpm

    collect_sample_values(
        math.max(buffer_start_time, touch_time - G_BASELINE_WINDOW_SECONDS),
        landing_analysis.impact_start_time,
        "projected_g",
        true
    )
    landing_analysis.baseline_g = scratch_median() or 1.0

    collect_sample_values(
        math.max(touch_time, landing_analysis.end_time - 0.05),
        landing_analysis.end_time,
        "local_vy",
        false
    )
    landing_analysis.post_vy_mps = scratch_median() or 0
    landing_analysis.velocity_delta_mps = math.max(
        0,
        landing_analysis.post_vy_mps - landing_analysis.pre_vy_mps
    )
    landing_analysis.stop_duration_seconds = math.max(
        0.03,
        landing_analysis.impact_end_time - landing_analysis.impact_start_time
    )
    landing_analysis.phase = "analyze_impulse"
    landing_analysis.analysis_ms = landing_analysis.analysis_ms + (os.clock() - started) * 1000
end

local function analyze_landing_impulse()
    local started = os.clock()
    local touch_time = landing_analysis.impact_start_time
    local end_time = landing_analysis.impact_end_time

    local impact_count = collect_sample_values(touch_time, end_time, "projected_g", false)
    landing_analysis.impact_sample_count = impact_count
    landing_analysis.curve_g = scratch_percentile(G_CURVE_PERCENTILE) or landing_touch_g

    local peak_g = landing_touch_g
    for i = 1, sort_scratch_count do
        if sort_scratch[i] > peak_g then peak_g = sort_scratch[i] end
    end
    landing_peak_g = peak_g

    local high_threshold = landing_analysis.baseline_g
        + math.max(0, peak_g - landing_analysis.baseline_g) * 0.80
    local impulse_delta = 0
    local high_duration = 0
    local max_gap = 0
    local gap_sum = 0
    local gap_count = 0
    local previous_t = nil
    local previous_g = nil

    for i = 1, sample_buffer.count do
        local sample = sample_at(i)
        if sample.t >= touch_time and sample.t <= end_time then
            local current_g = projected_vertical_g(sample)
            if current_g ~= nil then
                if previous_t ~= nil then
                    local dt = sample.t - previous_t
                    if dt > max_gap then max_gap = dt end
                    if dt > 0 and dt <= 0.10 then
                        gap_sum = gap_sum + dt
                        gap_count = gap_count + 1
                        local previous_excess = math.max(0, previous_g - landing_analysis.baseline_g)
                        local current_excess = math.max(0, current_g - landing_analysis.baseline_g)
                        impulse_delta = impulse_delta
                            + (previous_excess + current_excess) * 0.5 * 9.80665 * dt
                        if previous_g >= high_threshold and current_g >= high_threshold then
                            high_duration = high_duration + dt
                        end
                    end
                end
                previous_t = sample.t
                previous_g = current_g
            end
        end
    end

    landing_analysis.impulse_delta_mps = impulse_delta
    landing_analysis.high_g_duration_seconds = high_duration
    landing_analysis.average_sample_gap_seconds = gap_count > 0 and gap_sum / gap_count or 0
    landing_analysis.max_sample_gap_seconds = max_gap
    landing_analysis.consistency_error = abs_value(
        impulse_delta - landing_analysis.velocity_delta_mps
    ) / math.max(landing_analysis.velocity_delta_mps, 0.20)

    local equivalent_g = landing_analysis.baseline_g
        + landing_analysis.velocity_delta_mps
            / (9.80665 * landing_analysis.stop_duration_seconds)
    landing_analysis.equivalent_g = math.max(1.0, math.min(5.0, equivalent_g))

    local samples_valid = landing_analysis.physical_fpm_valid
        and impact_count >= 3
        and max_gap <= MAX_VALID_SAMPLE_GAP_SECONDS

    if not samples_valid then
        landing_analysis.confidence = "LOW"
        landing_analysis.used_fallback = true
        landing_analysis.method = "物理样本不足，使用备用一致性上限"
        landing_g = math.min(landing_analysis.curve_g, fallback_g_cap(landing_fpm))
    elseif landing_analysis.consistency_error <= CONSISTENCY_HIGH_MAX_ERROR
        and high_duration >= HIGH_G_DURATION_MIN_SECONDS then
        landing_analysis.confidence = "HIGH"
        landing_analysis.used_fallback = false
        landing_analysis.method = "高可信冲量，采用第75百分位曲线G"
        landing_g = landing_analysis.curve_g
    -- 中可信度也要求至少两帧连续处于高 G 区域；单帧尖峰的持续时间为零，只能进入低可信度分支。
    elseif landing_analysis.consistency_error <= CONSISTENCY_MEDIUM_MAX_ERROR
        and high_duration > 0 then
        landing_analysis.confidence = "MEDIUM"
        landing_analysis.used_fallback = false
        landing_analysis.method = "中可信冲量，曲线G与等效G加权"
        landing_g = landing_analysis.curve_g * 0.65 + landing_analysis.equivalent_g * 0.35
    else
        landing_analysis.confidence = "LOW"
        landing_analysis.used_fallback = false
        landing_analysis.method = "低可信峰值，主要采用冲量等效G"
        landing_g = landing_analysis.curve_g * 0.25 + landing_analysis.equivalent_g * 0.75
    end

    landing_g = math.max(1.0, math.min(5.0, landing_g))
    landing_analysis.phase = "finalize"
    landing_analysis.analysis_ms = landing_analysis.analysis_ms + (os.clock() - started) * 1000
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

    local migrated = false
    for line in file:lines() do
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key == "popup_mode" then
            if value == "touchdown" then
                POPUP_MODE = "immediate"
                migrated = true
            elseif value == "immediate" or value == "taxi" then
                POPUP_MODE = value
            end
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
    if migrated then save_settings() end
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
        return "重着陆：下降率超过 300 fpm，或过载超过 1.80 G"
    elseif status == "ATTENTION" then
        return "需注意：下降率不超过 300 fpm，且过载不超过 1.80 G"
    elseif status == "STABLE" then
        return "稳定扎实落地：下降率不超过 250 fpm，且过载不超过 1.50 G"
    end
    return "轻柔接地：下降率不超过 100 fpm，且过载不超过 1.20 G"
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
    local airport_token = sanitize_filename_token(landing_context.airport_id)
    local runway_token = sanitize_filename_token(landing_context.runway)
    local file_timestamp = landing_context.file_timestamp
    if file_timestamp == "" then
        file_timestamp = os.date("%Y-%m-%d_%H-%M-%S")
    end
    local base_name = "LMM_" .. airport_token .. "_" .. runway_token .. "_" .. file_timestamp
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
            "[StarLux LMM] Aircraft=%s | Airport=%s | RWY~%s | Surface=%s | FPM vviMedian=%d physicalP25=%d selected=%d | G touch=%.2f peak=%.2f curve=%.2f equiv=%.2f used=%.2f | impulseErr=%.0f%% confidence=%s method=%s | IAS=%.0f GS=%.0f AoA=%.1f Roll=%.1f | Wind=%03d/%dkt | Mode=%s | Layout=%s",
            landing_context.aircraft_icao,
            landing_context.airport_id,
            landing_context.runway,
            landing_surface.warning_type,
            round_num(landing_analysis.vvi_fpm),
            round_num(landing_analysis.physical_fpm),
            debug_data.selected_fpm,
            landing_touch_g,
            landing_peak_g,
            debug_data.robust_g,
            debug_data.expected_max_g,
            landing_g,
            landing_analysis.consistency_error * 100,
            landing_analysis.confidence,
            landing_analysis.method,
            landing_ias_kts,
            landing_gs_kts,
            landing_aoa_deg,
            landing_roll_deg,
            round_num(normalize_deg(landing_wind_heading_deg)),
            round_num(landing_wind_speed_kts),
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
        return false, tostring(err)
    end

    file:write("\239\187\191")
    file:write("StarLux 落地率插件 - 单次落地记录\n")
    file:write("============================================================\n")
    file:write("落地时间（本地时间）: " .. landing_timestamp .. "\n")
    file:write("落地评价: " .. status_short(landing_status) .. "\n")
    file:write("评价说明: " .. status_explanation(landing_status) .. "\n\n")

    file:write("飞机与落地位置\n")
    file:write("------------------------------------------------------------\n")
    file:write("机型（ICAO）: " .. landing_context.aircraft_icao .. "\n")
    if landing_context.aircraft_file ~= "" then
        file:write("飞机文件: " .. landing_context.aircraft_file .. "\n")
    end
    if landing_context.airport_id == "UNKNOWN" then
        file:write("落地机场: 未能识别\n")
    else
        local airport_name_suffix = ""
        if landing_context.airport_name ~= "" then
            airport_name_suffix = " - " .. landing_context.airport_name
        end
        file:write("落地机场: " .. landing_context.airport_id .. airport_name_suffix .. "\n")
        file:write(string.format("触地点距机场参考点: %.1f km\n", landing_context.airport_distance_km))
    end
    file:write("触地跑道方向: 约 " .. landing_context.runway .. "\n")
    file:write("跑道识别说明: 根据触地磁航向推算跑道号，暂不区分 L/R/C。\n\n")

    file:write("触地数据\n")
    file:write("------------------------------------------------------------\n")
    file:write("触地垂直速度: " .. vertical_speed_log_text(landing_fpm) .. "\n")
    file:write("同窗 VVI 中位数: " .. vertical_speed_log_text(round_num(landing_analysis.vvi_fpm)) .. "\n")
    file:write("250 ms 物理速度第25百分位: " .. vertical_speed_log_text(round_num(landing_analysis.physical_fpm)) .. "\n")
    file:write("80 ms 物理速度中位数（旧算法对照）: " .. vertical_speed_log_text(round_num(landing_analysis.physical_short_fpm)) .. "\n")
    file:write("0.85 s 最差 VVI（旧算法对照）: " .. vertical_speed_log_text(round_num(landing_analysis.vvi_min_fpm)) .. "\n")
    file:write(string.format("物理主值与同窗 VVI 差值: %+d fpm\n", round_num(landing_analysis.fpm_difference)))
    file:write("FPM 物理窗口样本数: " .. tostring(landing_analysis.physical_sample_count) .. "\n")
    file:write(string.format("最终过载: %.2f G\n", landing_g))
    file:write(string.format("指示空速（IAS）: %.0f kt\n", landing_ias_kts))
    file:write(string.format("真空速（TAS）: %.0f kt\n", landing_tas_kts))
    file:write(string.format("地速（GS）: %.0f kt\n", landing_gs_kts))
    file:write(string.format("迎角: %.1f deg\n", landing_aoa_deg))
    file:write("横滚角: " .. roll_log_text(landing_roll_deg) .. "\n")
    file:write(string.format("飞机磁航向: %03d deg\n", round_num(normalize_deg(landing_heading_deg))))
    file:write(string.format("风向和风速: 来自 %03d deg，%d kt\n", round_num(normalize_deg(landing_wind_heading_deg)), round_num(landing_wind_speed_kts)))
    file:write("相对风: " .. landing_wind_relative_text .. "\n")
    file:write(string.format("触地前三分钟实际降水峰值: %.0f%%\n", landing_surface.precipitation_ratio * 100))
    file:write("连续达到降水阈值的采样数: " .. tostring(landing_surface.consecutive_rain_samples) .. "\n")
    file:write(string.format(
        "触地前三分钟跑道摩擦状态: %s（X-Plane 等级 %.0f）\n",
        runway_friction_text(landing_surface.runway_friction),
        landing_surface.runway_friction
    ))
    file:write("道面判定来源: " .. landing_surface.source_text .. "\n")
    file:write("道面提示: " .. (landing_surface.warning_text ~= "" and landing_surface.warning_text or "无") .. "\n\n")

    file:write("测量明细\n")
    file:write("------------------------------------------------------------\n")
    file:write(string.format("触地帧过载: %.2f G\n", landing_touch_g))
    file:write(string.format("第一次压缩原始峰值: %.2f G\n", landing_peak_g))
    file:write(string.format("第75百分位曲线 G: %.2f G\n", landing_analysis.curve_g))
    file:write(string.format("接地前垂直 G 基线: %.2f G\n", landing_analysis.baseline_g))
    file:write(string.format("冲量等效 G: %.2f G\n", landing_analysis.equivalent_g))
    file:write(string.format("第一次压缩持续时间: %.0f ms\n", landing_analysis.stop_duration_seconds * 1000))
    file:write(string.format("高 G 持续时间: %.0f ms\n", landing_analysis.high_g_duration_seconds * 1000))
    file:write(string.format("G 冲量推算速度变化: %.3f m/s\n", landing_analysis.impulse_delta_mps))
    file:write(string.format("实际垂直速度变化: %.3f m/s\n", landing_analysis.velocity_delta_mps))
    file:write(string.format("冲量一致性误差: %.1f%%\n", landing_analysis.consistency_error * 100))
    file:write("数据可信度: " .. confidence_text(landing_analysis.confidence) .. "\n")
    file:write("最终 G 采用方式: " .. landing_analysis.method .. "\n")
    file:write("是否启用备用算法: " .. (landing_analysis.used_fallback and "是" or "否") .. "\n")
    file:write("冲击阶段有效样本数: " .. tostring(landing_analysis.impact_sample_count) .. "\n")
    file:write(string.format("平均采样间隔: %.1f ms\n", landing_analysis.average_sample_gap_seconds * 1000))
    file:write(string.format("最大采样间隔: %.1f ms\n", landing_analysis.max_sample_gap_seconds * 1000))
    file:write(string.format("冲量分析耗时: %.3f ms\n", landing_analysis.analysis_ms))
    file:write(string.format("最终评分耗时: %.3f ms\n", landing_analysis.finalize_ms))
    file:write(string.format("最终显示和评分值: %.2f G\n\n", landing_g))

    file:write("评分阈值\n")
    file:write("------------------------------------------------------------\n")
    file:write(string.format("Nice 轻柔接地: 下降率不大于 %d fpm，过载不大于 %.2f G\n", FPM_NICE_MAX, G_NICE_MAX))
    file:write(string.format("Stable 稳定扎实落地: 下降率不大于 %d fpm，过载不大于 %.2f G\n", FPM_STABLE_MAX, G_STABLE_MAX))
    file:write(string.format("Attention 需注意: 下降率不大于 %d fpm，过载不大于 %.2f G\n", FPM_ATTENTION_MAX, G_ATTENTION_MAX))
    file:write("UNSTABLE 重着陆: 下降率或过载超过任意 Attention 上限。\n")
    file:write("FPM 与 G 分别分档，最终评价取两项中较严重的等级。\n\n")

    file:write("本次使用的显示设置\n")
    file:write("------------------------------------------------------------\n")
    file:write("弹窗时机: " .. (POPUP_MODE == "immediate" and "分析完成后立即显示" or "地速低于 30 kt 时") .. "\n")
    file:write("显示时长: " .. tostring(DISPLAY_SECONDS) .. " 秒\n")
    file:write("屏幕位置: " .. position_log_label(POPUP_POSITION) .. "\n")
    file:write("窗口布局: " .. (POPUP_LAYOUT == "vertical" and "竖向" or "横向") .. "\n")
    file:write("背景透明度档位: " .. tostring(PANEL_OPACITY_LEVEL) .. "%\n")
    local close_ok, close_error = file:close()
    if close_ok == nil then
        if logMsg then
            logMsg("[StarLux LMM] Unable to finalize landing log: " .. tostring(close_error))
        end
        return false, tostring(close_error)
    end

    if logMsg then
        logMsg("[StarLux LMM] Landing log saved: " .. log_path)
    end
    return true, log_path
end

local function schedule_landing_jobs(now)
    landing_jobs.context_pending = true
    landing_jobs.context_after = now + CONTEXT_RESOLVE_DELAY_SECONDS
    landing_jobs.log_pending = true
    landing_jobs.log_after = now + LOG_WRITE_DELAY_SECONDS
end

local function resolve_context_safely()
    landing_jobs.context_pending = false
    local call_ok, resolve_ok, reason = pcall(resolve_landing_context)
    if not call_ok then
        landing_context.airport_id = "UNKNOWN"
        landing_context.airport_name = ""
        if logMsg then
            logMsg("[StarLux LMM] Airport lookup failed; monitoring will continue: " .. tostring(resolve_ok))
        end
    elseif not resolve_ok and logMsg then
        logMsg("[StarLux LMM] Airport not identified: " .. tostring(reason))
    elseif logMsg then
        logMsg(string.format(
            "[StarLux LMM] Airport identified: %s (%s), %.1f km from touchdown, estimated RWY %s",
            landing_context.airport_id,
            landing_context.airport_name,
            landing_context.airport_distance_km,
            landing_context.runway
        ))
    end
    refresh_popup_cache()
end

local function process_landing_jobs(now)
    if landing_jobs.context_pending == true and now >= landing_jobs.context_after then
        resolve_context_safely()
    end

    if landing_jobs.log_pending == true and now >= landing_jobs.log_after then
        landing_jobs.log_pending = false

        -- 正常情况下机场查询会先完成；若模拟时间发生跳变，则在写文件前补做一次。
        if landing_jobs.context_pending == true then
            resolve_context_safely()
        end

        log_landing_summary()
        local call_ok, write_ok, result = pcall(write_landing_log)
        if call_ok and write_ok then
            landing_report_notice.text = "落地详细报告已生成: " .. file_name_from_path(result)
            landing_report_notice.until_time = now + REPORT_NOTICE_SECONDS
        elseif logMsg then
            local error_text = result
            if not call_ok then
                error_text = write_ok
            end
            logMsg("[StarLux LMM] Landing log failed, but flight monitoring will continue: " .. tostring(error_text))
        end
    end
end

local function finalize_landing_analysis(now)
    local started = os.clock()
    landing_status = classify_landing(landing_fpm, landing_g, EXTERNAL_SCORE_HINT)
    landing_complete = true
    armed = false

    debug_data.last_frame_fpm = round_num(approach_data.vs_fpm)
    debug_data.selected_fpm = landing_fpm
    debug_data.touch_g = landing_touch_g
    debug_data.peak_g = landing_peak_g
    debug_data.robust_g = landing_analysis.curve_g
    debug_data.expected_max_g = landing_analysis.equivalent_g
    debug_data.used_g = landing_g
    debug_data.physical_fpm = round_num(landing_analysis.physical_fpm)
    debug_data.fpm_difference = round_num(landing_analysis.fpm_difference)
    debug_data.consistency_error = landing_analysis.consistency_error
    debug_data.confidence = landing_analysis.confidence
    debug_data.analysis_ms = landing_analysis.analysis_ms

    refresh_popup_cache()
    if POPUP_MODE == "immediate" then
        show_until = now + DISPLAY_SECONDS
    end

    schedule_landing_jobs(now)
    landing_analysis.finalize_ms = (os.clock() - started) * 1000
    landing_analysis.phase = "complete"
end

local function process_landing_analysis(now, local_vy_mps)
    if landing_analysis.phase == "capture" then
        if local_vy_mps >= IMPACT_STOP_VY_MPS then
            if landing_analysis.stop_stable_frames == 0 then
                landing_analysis.stop_candidate_time = now
            end
            landing_analysis.stop_stable_frames = landing_analysis.stop_stable_frames + 1
        else
            landing_analysis.stop_stable_frames = 0
            landing_analysis.stop_candidate_time = 0
        end

        if local_vy_mps > 0.05 then
            landing_analysis.impact_end_time = now
            landing_analysis.end_time = now
            landing_analysis.phase = "analyze_velocity"
        elseif landing_analysis.stop_stable_frames >= IMPACT_STOP_STABLE_FRAMES then
            -- 三帧只用于确认停止状态；物理减速时长截止到第一帧达到停止阈值的时刻。
            landing_analysis.impact_end_time = landing_analysis.stop_candidate_time
            landing_analysis.end_time = now
            landing_analysis.phase = "analyze_velocity"
        elseif now >= landing_analysis.capture_deadline then
            landing_analysis.impact_end_time = now
            landing_analysis.end_time = now
            landing_analysis.phase = "analyze_velocity"
        end
    elseif landing_analysis.phase == "analyze_velocity" then
        analyze_landing_velocity()
    elseif landing_analysis.phase == "analyze_impulse" then
        analyze_landing_impulse()
    elseif landing_analysis.phase == "finalize" then
        finalize_landing_analysis(now)
    end
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
    if imgui.RadioButton("Show immediately after analysis", POPUP_MODE == "immediate") then
        POPUP_MODE = "immediate"
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
        refresh_popup_cache()
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
    local local_vy_mps = lmm_get_float("local_vy_mps")
    local y_agl_m = lmm_get_float("y_agl_m")
    local on_ground = lmm_get_int("on_ground")
    local current_g = lmm_get_float("g_normal")
    local roll_deg = lmm_get_float("roll_deg")
    local pitch_deg = lmm_get_float("pitch_deg")
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
            reset_sample_buffer()
            reset_surface_watch(now)
            landing_analysis.phase = "idle"
        end
        armed = true
        landing_complete = false
        taxi_popup_done = false
    end

    -- 只在进近阶段低频监测实际降水和跑道摩擦状态；触地后不再读取气象。
    if on_ground == 0 and armed == true and radio_alt_ft <= WEATHER_MONITOR_MAX_AGL_FT then
        update_prelanding_surface_watch(now)
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
        approach_data.pitch_deg = pitch_deg
        approach_data.wind_speed_kts = wind_speed_kts
        approach_data.wind_heading_deg = wind_heading_deg_mag
        approach_data.heading_deg = heading_deg_mag

    end

    -- 环形缓冲区只在近地进近和第一次起落架压缩阶段写入。
    if (armed == true and radio_alt_ft <= VS_SAMPLE_MAX_AGL_FT)
        or landing_analysis.phase == "capture" then
        add_flight_sample(
            now,
            vs_fpm,
            local_vy_mps,
            current_g,
            pitch_deg,
            roll_deg,
            on_ground
        )
    end

    -- 触地检测：状态从离地变为接地。
    if armed == true and was_on_ground == 0 and on_ground == 1 and gs_kt > 35 then
        landing_complete = false
        landing_timestamp = os.date("%Y-%m-%d %H:%M:%S")

        begin_landing_analysis(now)

        local clean_touch_g = sanitize_g(current_g)
        if clean_touch_g == nil then
            clean_touch_g = 1.00
        end

        landing_touch_g = clean_touch_g
        landing_peak_g = clean_touch_g
        landing_g = clean_touch_g

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
        begin_landing_context()
        capture_landing_surface(now)
    end

    -- 采样、速度分析、冲量分析和最终评分分布在不同更新帧执行。
    process_landing_analysis(now, local_vy_mps)

    -- 低速弹窗模式：落地后地速低于 30 节时显示。
    if POPUP_MODE == "taxi" and landing_complete == true and taxi_popup_done == false then
        if gs_kt <= TAXI_POPUP_SPEED_KT then
            show_until = now + DISPLAY_SECONDS
            taxi_popup_done = true
        end
    end

    -- 分阶段处理机场查询、报告写入和完成提示。
    process_landing_jobs(now)

    was_on_ground = on_ground
end

-- =========================
-- 数据窗绘制
-- =========================

function ma_landing_meter_draw()
    local now = current_sim_time()
    local screen_w = SCREEN_WIDTH or 1920
    local screen_h = SCREEN_HIGHT or 1080
    local popup_visible = show_until > 0 and now <= show_until

    if popup_visible then
        local panel_w = HORIZONTAL_PANEL_W
        local panel_h = HORIZONTAL_PANEL_H
        local show_surface_warning = landing_surface.wet_warning and landing_status == "NICE"
        if POPUP_LAYOUT == "vertical" then
            panel_w = VERTICAL_PANEL_W
            panel_h = VERTICAL_PANEL_H
        end
        if show_surface_warning then
            panel_h = panel_h + (POPUP_LAYOUT == "vertical" and 27 or 18)
        end

        local x, y = calculate_popup_position(screen_w, screen_h, panel_w, panel_h)
        local r, g, b = status_color(landing_status)

        -- 浅色半透明状态底板；导航查询和文件写入均已移出触地关键阶段。
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

        local text_x = x + ACCENT_THICKNESS + 10
        local line_y1 = y + 108
        local line_gap = 18
        if POPUP_LAYOUT == "vertical" then
            text_x = x + 14
            line_y1 = y + 162
            line_gap = 27
        end
        if show_surface_warning then
            line_y1 = line_y1 + line_gap
        end

        -- 基础六行文字使用均匀基线；湿滑时在底部增加独立的橙色提示行。
        glColor4f(1, 1, 1, 0.98)
        draw_string(text_x, line_y1, popup_cache.lines[1])
        draw_string(text_x, line_y1 - line_gap, popup_cache.lines[2])
        draw_string(text_x, line_y1 - line_gap * 2, popup_cache.lines[3])
        draw_string(text_x, line_y1 - line_gap * 3, popup_cache.lines[4])
        draw_string(text_x, line_y1 - line_gap * 4, popup_cache.lines[5])
        draw_string(text_x, line_y1 - line_gap * 5, popup_cache.lines[6])
        if show_surface_warning then
            glColor4f(0.78, 0.52, 0.06, 1.0)
            draw_string(text_x, line_y1 - line_gap * 6, popup_cache.warning_text)
        end

        if DEBUG_MODE == true then
            glColor4f(1, 1, 1, 0.86)
            local debug_line1 = string.format("DBG FPM vvi:%d phys:%d", round_num(landing_analysis.vvi_fpm), debug_data.physical_fpm)
            local debug_line2 = string.format("DBG G pk:%.2f curve:%.2f eq:%.2f", debug_data.peak_g, debug_data.robust_g, debug_data.expected_max_g)
            local debug_line3 = string.format("DBG err:%.0f%% %s %.2fms", debug_data.consistency_error * 100, debug_data.confidence, debug_data.analysis_ms)
            local debug_x = x + panel_w + 12
            if debug_x + 270 > screen_w then
                debug_x = math.max(0, x - 282)
            end
            draw_string(debug_x, y + 70, debug_line1)
            draw_string(debug_x, y + 48, debug_line2)
            draw_string(debug_x, y + 26, debug_line3)
        end
    end

    -- 报告完成提示独立于落地数据窗，写入成功后显示数秒。
    if landing_report_notice.until_time > now and landing_report_notice.text ~= "" then
        local notice_w = math.min(500, screen_w - 40)
        local notice_h = 36
        local notice_x = math.floor((screen_w - notice_w) / 2)
        local notice_y = 38

        XPLMSetGraphicsState(0, 0, 0, 1, 1, 0, 0)
        glColor4f(0.03, 0.16, 0.09, 0.78)
        glRectf(notice_x, notice_y, notice_x + notice_w, notice_y + notice_h)
        draw_panel_border(notice_x, notice_y, notice_w, notice_h, 0.08, 0.50, 0.24)
        glColor4f(1, 1, 1, 0.98)
        draw_string(notice_x + 12, notice_y + 12, landing_report_notice.text)
    end
end

do_every_frame("ma_landing_meter_update()")
do_every_draw("ma_landing_meter_draw()")

if logMsg then
    logMsg(string.format(
        "[StarLux LMM] v0.7.2 loaded successfully with %d direct XPLM DataRefs.",
        #LMM_DATAREF_SPECS
    ))
end

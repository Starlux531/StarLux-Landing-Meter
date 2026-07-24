-- StarLux 落地率插件 v0.9.0 测试版
-- 适用于 X-Plane 12 + FlyWithLua
-- v0.9.0 新增落地记录管理、本地浏览器可视化、原始 TXT 下载与安全删除功能。

-- =========================
-- 用户设置
-- =========================

local POPUP_MODE = "immediate"
-- "immediate" = 落地分析完成后立即显示
-- "taxi"      = 地速降低到 30 节以下时显示

local DISPLAY_SECONDS = 30
local DETAILED_MATH_LOG = false
-- false = 输出 v0.8.0 风格的简洁专业报告；true = 追加可完整复算的数学审计内容。
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

-- 拉平曲率首版只显示和记录，不参与落地评分。
-- 10 Hz 原始采样在分析阶段聚合为 0.5 秒轨迹点，降低帧率和瞬时噪声的影响。
local FLARE_CONFIG = {
    start_agl_ft = 100,
    sample_interval_seconds = 0.10,
    max_samples = 600,
    bucket_seconds = 0.50,
    max_buckets = 128,
    min_samples = 12,
    min_buckets = 4,
    curvature_percentile = 0.75,
    reversal_noise_fpm = 20,
    oscillation_high_reversal_min = 3,
    oscillation_severe_reversal_min = 5,
    oscillation_efficiency_max = 0.55,
    oscillation_worsening_ratio_min = 0.40
}

-- 弹跳必须具有持续离地时间，并满足离地高度或向上速度条件，避免把起落架信号抖动误判为弹跳。
local BOUNCE_CONFIG = {
    monitor_seconds = 6.0,
    min_airborne_seconds = 0.12,
    min_peak_agl_ft = 0.50,
    min_upward_mps = 0.15,
    second_g_capture_seconds = 0.35
}

-- 紧凑型数据窗；设置窗口提供九种屏幕位置。
local POPUP_POSITION = "middle_left"
local POPUP_LAYOUT = "horizontal"
-- "horizontal" = 横向数据窗，状态色粗边位于左侧
-- "vertical"   = 竖向数据窗，状态色粗边位于上方
local HORIZONTAL_PANEL_W = 395
local HORIZONTAL_PANEL_H = 150
local VERTICAL_PANEL_W = 265
local VERTICAL_PANEL_H = 223
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
local LOG_VIEWER_FILE_PATH = join_path(LOG_DIRECTORY_PATH, "LMM_Viewer.html")
local LOG_INDEX_TEMP_FILE_PATH = join_path(LOG_DIRECTORY_PATH, ".lmm_index.tmp")
local LOG_MANAGER_PAGE_SIZE = 8

local VS_SAMPLE_MAX_AGL_FT = 120

-- 冲量一致性算法参数。
local SAMPLE_BUFFER_SIZE = 256
local MATH_AUDIT_SAMPLE_MAX = SAMPLE_BUFFER_SIZE
local SECOND_TOUCH_AUDIT_SAMPLE_MAX = SAMPLE_BUFFER_SIZE
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

-- 数学审计快照会在分析完成前复制所用样本，避免延迟写报告时环形缓冲区已被新数据覆盖。
local math_audit = {
    samples = {},
    count = 0,
    limited = false,
    second_samples = {},
    second_count = 0,
    second_limited = false
}
for i = 1, MATH_AUDIT_SAMPLE_MAX do
    math_audit.samples[i] = {
        t = 0,
        vvi_fpm = 0,
        local_vy_mps = 0,
        g_normal = 0,
        projected_g = 0,
        pitch_deg = 0,
        roll_deg = 0,
        on_ground = 0
    }
end
for i = 1, SECOND_TOUCH_AUDIT_SAMPLE_MAX do
    math_audit.second_samples[i] = {
        t = 0,
        vvi_fpm = 0,
        local_vy_mps = 0,
        g_normal = 0,
        projected_g = 0,
        pitch_deg = 0,
        roll_deg = 0,
        on_ground = 0
    }
end

-- 100 英尺以下的拉平轨迹使用固定容量数组，进近过程中不创建逐帧小表。
local flare_trace = {
    slots = {},
    buckets = {},
    active = false,
    complete = false,
    limited = false,
    start_time = 0,
    touch_time = 0,
    next_sample_time = 0,
    count = 0,
    bucket_count = 0
}
for i = 1, FLARE_CONFIG.max_samples do
    flare_trace.slots[i] = {
        t = 0,
        agl_ft = 0,
        physical_fpm = 0,
        vvi_fpm = 0,
        ias_kts = 0,
        gs_kts = 0,
        pitch_deg = 0,
        aoa_deg = 0,
        roll_deg = 0
    }
end
for i = 1, FLARE_CONFIG.max_buckets do
    flare_trace.buckets[i] = {
        count = 0,
        t = 0,
        agl_ft = 0,
        physical_fpm = 0,
        vvi_fpm = 0,
        ias_kts = 0,
        gs_kts = 0,
        pitch_deg = 0,
        aoa_deg = 0,
        roll_deg = 0
    }
end

local flare_analysis = {
    valid = false,
    metric = 0,
    signed_mean_curvature = 0,
    duration_seconds = 0,
    entry_fpm = 0,
    touchdown_fpm = 0,
    recovery_fpm = 0,
    reversal_count = 0,
    worsening_ratio = 0,
    monotonic_efficiency = 0,
    late_recovery_ratio = 0,
    trend_text = "等待100英尺采样",
    calculation_ms = 0
}

local bounce_state = {
    monitoring = false,
    detected = false,
    phase = "idle",
    first_touch_time = 0,
    monitor_until = 0,
    airborne_start_time = 0,
    airborne_duration_seconds = 0,
    airborne_peak_agl_ft = 0,
    airborne_peak_upward_mps = 0,
    second_touch_time = 0,
    second_capture_until = 0,
    second_fpm = 0,
    second_touch_g = 1,
    second_peak_g = 1,
    second_curve_g = 1,
    second_g_ready = false,
    original_status = "NICE",
    score_applied = false
}

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
    used_fallback = false,
    math_log_enabled = false
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
local log_manager_window = nil
-- 新增文件管理函数统一放入表中，避免 Lua 5.1 主代码块超过 200 个局部变量上限。
local log_tools = {}
local log_manager_state = {
    records = {},
    page = 1,
    scan_error = "",
    pending_delete = "",
    notice = "",
    viewer_busy = false
}
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
    lines = { "", "", "", "", "", "", "" },
    warning_text = "",
    bounce_text = ""
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
        return 0.08, 0.50, 0.24
    else
        return 0.07, 0.32, 0.62
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
    if flare_analysis.valid then
        popup_cache.lines[5] = string.format(
            "拉平曲率 %.1f | %s",
            flare_analysis.metric,
            flare_analysis.trend_text
        )
    else
        popup_cache.lines[5] = "拉平曲率 -- | " .. flare_analysis.trend_text
    end
    popup_cache.lines[6] = landing_wind_relative_text
    popup_cache.lines[7] = status_short(landing_status)
    popup_cache.warning_text = landing_surface.warning_text
    if bounce_state.detected then
        if bounce_state.second_g_ready then
            popup_cache.bounce_text = string.format(
                "发生弹跳 | 二次 %+d fpm / +%.2fG",
                bounce_state.second_fpm,
                bounce_state.second_curve_g
            )
        else
            popup_cache.bounce_text = "发生弹跳 | 正在分析第二次触地"
        end
    else
        popup_cache.bounce_text = ""
    end
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

local function reset_math_audit()
    math_audit.count = 0
    math_audit.limited = false
    math_audit.second_count = 0
    math_audit.second_limited = false
end

local function capture_math_audit_range(target, maximum, start_time, end_time)
    local count = 0
    local limited = false
    for i = 1, sample_buffer.count do
        local sample = sample_at(i)
        if sample.t >= start_time and sample.t <= end_time then
            if count >= maximum then
                limited = true
            else
                count = count + 1
                local slot = target[count]
                slot.t = sample.t
                slot.vvi_fpm = sample.vvi_fpm
                slot.local_vy_mps = sample.local_vy_mps
                slot.g_normal = sample.g_normal
                slot.projected_g = projected_vertical_g(sample) or 0
                slot.pitch_deg = sample.pitch_deg
                slot.roll_deg = sample.roll_deg
                slot.on_ground = sample.on_ground
            end
        end
    end
    return count, limited
end

local function capture_primary_math_audit()
    math_audit.count, math_audit.limited = capture_math_audit_range(
        math_audit.samples,
        MATH_AUDIT_SAMPLE_MAX,
        landing_analysis.touch_time - VVI_DIAGNOSTIC_WINDOW_SECONDS,
        landing_analysis.end_time
    )
end

local function capture_second_touch_math_audit(end_time)
    math_audit.second_count, math_audit.second_limited = capture_math_audit_range(
        math_audit.second_samples,
        SECOND_TOUCH_AUDIT_SAMPLE_MAX,
        bounce_state.second_touch_time - PHYSICAL_FPM_WINDOW_SECONDS,
        end_time
    )
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

local function reset_flare_trace()
    flare_trace.active = false
    flare_trace.complete = false
    flare_trace.limited = false
    flare_trace.start_time = 0
    flare_trace.touch_time = 0
    flare_trace.next_sample_time = 0
    flare_trace.count = 0
    flare_trace.bucket_count = 0
    flare_analysis.valid = false
    flare_analysis.metric = 0
    flare_analysis.signed_mean_curvature = 0
    flare_analysis.duration_seconds = 0
    flare_analysis.entry_fpm = 0
    flare_analysis.touchdown_fpm = 0
    flare_analysis.recovery_fpm = 0
    flare_analysis.reversal_count = 0
    flare_analysis.worsening_ratio = 0
    flare_analysis.monotonic_efficiency = 0
    flare_analysis.late_recovery_ratio = 0
    flare_analysis.trend_text = "等待100英尺采样"
    flare_analysis.calculation_ms = 0
end

local function reset_bounce_state()
    bounce_state.monitoring = false
    bounce_state.detected = false
    bounce_state.phase = "idle"
    bounce_state.first_touch_time = 0
    bounce_state.monitor_until = 0
    bounce_state.airborne_start_time = 0
    bounce_state.airborne_duration_seconds = 0
    bounce_state.airborne_peak_agl_ft = 0
    bounce_state.airborne_peak_upward_mps = 0
    bounce_state.second_touch_time = 0
    bounce_state.second_capture_until = 0
    bounce_state.second_fpm = 0
    bounce_state.second_touch_g = 1
    bounce_state.second_peak_g = 1
    bounce_state.second_curve_g = 1
    bounce_state.second_g_ready = false
    bounce_state.original_status = "NICE"
    bounce_state.score_applied = false
end

local function start_flare_trace(now)
    flare_trace.active = true
    flare_trace.complete = false
    flare_trace.start_time = now
    flare_trace.next_sample_time = now
    flare_trace.count = 0
    flare_trace.bucket_count = 0
end

local function add_flare_trace_sample(
    now,
    radio_alt_ft,
    local_vy_mps,
    vvi_fpm,
    ias_kts,
    gs_kts,
    pitch_deg,
    aoa_deg,
    roll_deg
)
    if flare_trace.count >= FLARE_CONFIG.max_samples then
        flare_trace.limited = true
        flare_trace.next_sample_time = now + FLARE_CONFIG.sample_interval_seconds
        return
    end

    flare_trace.count = flare_trace.count + 1
    local slot = flare_trace.slots[flare_trace.count]
    slot.t = now
    slot.agl_ft = radio_alt_ft
    slot.physical_fpm = local_vy_mps * 196.850394
    slot.vvi_fpm = vvi_fpm
    slot.ias_kts = ias_kts
    slot.gs_kts = gs_kts
    slot.pitch_deg = pitch_deg
    slot.aoa_deg = aoa_deg
    slot.roll_deg = roll_deg
    flare_trace.next_sample_time = now + FLARE_CONFIG.sample_interval_seconds
end

local function update_flare_trace(
    now,
    radio_alt_ft,
    on_ground,
    local_vy_mps,
    vvi_fpm,
    ias_kts,
    gs_kts,
    pitch_deg,
    aoa_deg,
    roll_deg
)
    if flare_trace.active == false
        and flare_trace.complete == false
        and armed == true
        and on_ground == 0
        and radio_alt_ft <= FLARE_CONFIG.start_agl_ft
        and radio_alt_ft >= 0 then
        start_flare_trace(now)
    end

    if flare_trace.active == true and on_ground == 0 and now >= flare_trace.next_sample_time then
        add_flare_trace_sample(
            now,
            radio_alt_ft,
            local_vy_mps,
            vvi_fpm,
            ias_kts,
            gs_kts,
            pitch_deg,
            aoa_deg,
            roll_deg
        )
    end
end

local function finish_flare_trace(now)
    flare_trace.active = false
    flare_trace.complete = true
    flare_trace.touch_time = now
end

local function analyze_flare_curve()
    local started = os.clock()
    flare_analysis.valid = false
    flare_analysis.touchdown_fpm = landing_fpm
    flare_analysis.duration_seconds = math.max(0, flare_trace.touch_time - flare_trace.start_time)

    for i = 1, FLARE_CONFIG.max_buckets do
        local bucket = flare_trace.buckets[i]
        bucket.count = 0
        bucket.t = 0
        bucket.agl_ft = 0
        bucket.physical_fpm = 0
        bucket.vvi_fpm = 0
        bucket.ias_kts = 0
        bucket.gs_kts = 0
        bucket.pitch_deg = 0
        bucket.aoa_deg = 0
        bucket.roll_deg = 0
    end

    if flare_trace.count < FLARE_CONFIG.min_samples or flare_trace.start_time <= 0 then
        flare_analysis.trend_text = "拉平轨迹样本不足"
        flare_analysis.calculation_ms = (os.clock() - started) * 1000
        return
    end

    -- 原始 10 Hz 样本按 0.5 秒时间桶求平均，保留高度、速度和姿态参考信息。
    for i = 1, flare_trace.count do
        local sample = flare_trace.slots[i]
        local bucket_index = math.floor(
            (sample.t - flare_trace.start_time) / FLARE_CONFIG.bucket_seconds
        ) + 1
        if bucket_index < 1 then bucket_index = 1 end
        if bucket_index > FLARE_CONFIG.max_buckets then
            bucket_index = FLARE_CONFIG.max_buckets
            flare_trace.limited = true
        end

        local bucket = flare_trace.buckets[bucket_index]
        bucket.count = bucket.count + 1
        bucket.t = bucket.t + sample.t
        bucket.agl_ft = bucket.agl_ft + sample.agl_ft
        bucket.physical_fpm = bucket.physical_fpm + sample.physical_fpm
        bucket.vvi_fpm = bucket.vvi_fpm + sample.vvi_fpm
        bucket.ias_kts = bucket.ias_kts + sample.ias_kts
        bucket.gs_kts = bucket.gs_kts + sample.gs_kts
        bucket.pitch_deg = bucket.pitch_deg + sample.pitch_deg
        bucket.aoa_deg = bucket.aoa_deg + sample.aoa_deg
        bucket.roll_deg = bucket.roll_deg + sample.roll_deg
    end

    local compact_count = 0
    for i = 1, FLARE_CONFIG.max_buckets do
        local source = flare_trace.buckets[i]
        if source.count > 0 then
            compact_count = compact_count + 1
            local target = flare_trace.buckets[compact_count]
            if target ~= source then
                target.count = source.count
                target.t = source.t
                target.agl_ft = source.agl_ft
                target.physical_fpm = source.physical_fpm
                target.vvi_fpm = source.vvi_fpm
                target.ias_kts = source.ias_kts
                target.gs_kts = source.gs_kts
                target.pitch_deg = source.pitch_deg
                target.aoa_deg = source.aoa_deg
                target.roll_deg = source.roll_deg
            end

            local count = target.count
            target.t = target.t / count
            target.agl_ft = target.agl_ft / count
            target.physical_fpm = target.physical_fpm / count
            target.vvi_fpm = target.vvi_fpm / count
            target.ias_kts = target.ias_kts / count
            target.gs_kts = target.gs_kts / count
            target.pitch_deg = target.pitch_deg / count
            target.aoa_deg = target.aoa_deg / count
            target.roll_deg = target.roll_deg / count
        end
    end

    flare_trace.bucket_count = compact_count
    if compact_count < FLARE_CONFIG.min_buckets then
        flare_analysis.trend_text = "拉平轨迹聚合点不足"
        flare_analysis.calculation_ms = (os.clock() - started) * 1000
        return
    end

    -- 把最终评分使用的触地 FPM 作为轨迹终点；若与末桶太近，则直接替换末桶下降率。
    local last_bucket = flare_trace.buckets[compact_count]
    if flare_trace.touch_time - last_bucket.t >= 0.15
        and compact_count < FLARE_CONFIG.max_buckets then
        compact_count = compact_count + 1
        local touch_bucket = flare_trace.buckets[compact_count]
        touch_bucket.count = 1
        touch_bucket.t = flare_trace.touch_time
        touch_bucket.agl_ft = 0
        touch_bucket.physical_fpm = landing_fpm
        touch_bucket.vvi_fpm = landing_analysis.vvi_fpm
        touch_bucket.ias_kts = landing_ias_kts
        touch_bucket.gs_kts = landing_gs_kts
        touch_bucket.pitch_deg = approach_data.pitch_deg
        touch_bucket.aoa_deg = landing_aoa_deg
        touch_bucket.roll_deg = landing_roll_deg
    else
        last_bucket.t = flare_trace.touch_time
        last_bucket.agl_ft = 0
        last_bucket.physical_fpm = landing_fpm
    end
    flare_trace.bucket_count = compact_count

    local entry_fpm = flare_trace.buckets[1].physical_fpm
    local touch_fpm = flare_trace.buckets[compact_count].physical_fpm
    local total_variation = 0
    local worsening_count = 0
    local reversal_count = 0
    local previous_direction = 0
    local signed_curvature_sum = 0
    local curvature_count = 0
    local old_scratch_count = sort_scratch_count
    sort_scratch_count = 0

    for i = 2, compact_count do
        local delta = flare_trace.buckets[i].physical_fpm
            - flare_trace.buckets[i - 1].physical_fpm
        total_variation = total_variation + abs_value(delta)
        local direction = 0
        if delta > FLARE_CONFIG.reversal_noise_fpm then
            direction = 1
        elseif delta < -FLARE_CONFIG.reversal_noise_fpm then
            direction = -1
            worsening_count = worsening_count + 1
        end
        if direction ~= 0 and previous_direction ~= 0 and direction ~= previous_direction then
            reversal_count = reversal_count + 1
        end
        if direction ~= 0 then previous_direction = direction end
    end

    for i = 3, compact_count do
        local p1 = flare_trace.buckets[i - 2]
        local p2 = flare_trace.buckets[i - 1]
        local p3 = flare_trace.buckets[i]
        local dt1 = p2.t - p1.t
        local dt2 = p3.t - p2.t
        if dt1 > 0.10 and dt2 > 0.10 then
            local slope1 = (p2.physical_fpm - p1.physical_fpm) / dt1
            local slope2 = (p3.physical_fpm - p2.physical_fpm) / dt2
            local curvature = (slope2 - slope1) / ((dt1 + dt2) * 0.5)
            curvature_count = curvature_count + 1
            signed_curvature_sum = signed_curvature_sum + curvature
            sort_scratch_count = sort_scratch_count + 1
            sort_scratch[sort_scratch_count] = abs_value(curvature)
        end
    end

    for i = sort_scratch_count + 1, old_scratch_count do
        sort_scratch[i] = nil
    end
    if sort_scratch_count > 1 then table.sort(sort_scratch) end

    local recovery = touch_fpm - entry_fpm
    local interval_count = math.max(1, compact_count - 1)
    local late_target_time = flare_trace.start_time + flare_analysis.duration_seconds * 0.70
    local late_reference_fpm = entry_fpm
    for i = 1, compact_count do
        if flare_trace.buckets[i].t <= late_target_time then
            late_reference_fpm = flare_trace.buckets[i].physical_fpm
        end
    end

    flare_analysis.valid = curvature_count > 0
    flare_analysis.metric = scratch_percentile(FLARE_CONFIG.curvature_percentile) or 0
    flare_analysis.signed_mean_curvature = curvature_count > 0
        and signed_curvature_sum / curvature_count or 0
    flare_analysis.entry_fpm = entry_fpm
    flare_analysis.touchdown_fpm = touch_fpm
    flare_analysis.recovery_fpm = recovery
    flare_analysis.reversal_count = reversal_count
    flare_analysis.worsening_ratio = worsening_count / interval_count
    flare_analysis.monotonic_efficiency = recovery > 0
        and recovery / math.max(total_variation, 1) or 0
    flare_analysis.late_recovery_ratio = recovery > 20
        and math.max(0, touch_fpm - late_reference_fpm) / recovery or 0

    -- 轨迹结论只判断震荡程度。少量反转属于真实飞行中的正常扰动；
    -- 达到五次明显反转，或至少三次反转并伴随较低改善效率/较高恶化占比时，才判为高震荡。
    local oscillation_high = reversal_count
            >= FLARE_CONFIG.oscillation_severe_reversal_min
        or (
            reversal_count >= FLARE_CONFIG.oscillation_high_reversal_min
            and (
                flare_analysis.monotonic_efficiency
                    < FLARE_CONFIG.oscillation_efficiency_max
                or flare_analysis.worsening_ratio
                    >= FLARE_CONFIG.oscillation_worsening_ratio_min
            )
        )
    if oscillation_high then
        flare_analysis.trend_text = "下降率轨迹震荡高"
    else
        flare_analysis.trend_text = "下降率轨迹正常"
    end

    flare_analysis.calculation_ms = (os.clock() - started) * 1000
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
    -- 在第一次触地时冻结日志模式，确保延迟写入的报告与本次审计快照一致。
    landing_analysis.math_log_enabled = DETAILED_MATH_LOG
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
    if landing_analysis.math_log_enabled then
        capture_primary_math_audit()
    end
    landing_analysis.phase = "analyze_flare"
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
    file:write("detailed_math_log=" .. tostring(DETAILED_MATH_LOG) .. "\n")
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
    local detailed_math_key_found = false
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
        elseif key == "detailed_math_log" then
            DETAILED_MATH_LOG = value == "true"
            detailed_math_key_found = true
        elseif key == "debug_mode" then
            DEBUG_MODE = value == "true"
        end
    end
    file:close()
    if not detailed_math_key_found then migrated = true end
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

-- =========================
-- 落地记录索引与浏览器可视化
-- =========================

-- 文件管理功能只允许处理插件自己命名的 TXT，禁止目录分隔符和其他扩展名进入删除路径。
function log_tools.is_safe_log_filename(file_name)
    if type(file_name) ~= "string" or file_name == "" then return false end
    if file_name_from_path(file_name) ~= file_name then return false end
    if file_name:find("/", 1, true) or file_name:find("\\", 1, true) then return false end
    return file_name:match("^LMM_[%w%._%-]+%.txt$") ~= nil
end

function log_tools.log_timestamp_key(file_name)
    local timestamp = file_name:match("(%d%d%d%d%-%d%d%-%d%d_%d%d%-%d%d%-%d%d)")
    if timestamp == nil then return "00000000000000" end
    return timestamp:gsub("[^%d]", "")
end

function log_tools.shorten_log_filename(file_name, maximum)
    maximum = maximum or 68
    if #file_name <= maximum then return file_name end
    local left_count = math.floor((maximum - 3) * 0.58)
    local right_count = maximum - 3 - left_count
    return file_name:sub(1, left_count) .. "..." .. file_name:sub(-right_count)
end

function log_tools.log_record_display_name(file_name)
    local date_text, time_text = file_name:match(
        "(%d%d%d%d%-%d%d%-%d%d)_(%d%d%-%d%d%-%d%d)"
    )
    local identity = file_name
        :gsub("^LMM_", "")
        :gsub("_?%d%d%d%d%-%d%d%-%d%d_%d%d%-%d%d%-%d%d.*%.txt$", "")
        :gsub("_", " ")
    if date_text ~= nil then
        return log_tools.shorten_log_filename(
            date_text .. " " .. time_text:gsub("%-", ":") .. "  |  " .. identity,
            72
        )
    end
    return log_tools.shorten_log_filename(file_name, 72)
end

function log_tools.sort_log_records()
    table.sort(log_manager_state.records, function(a, b)
        if a.timestamp_key == b.timestamp_key then
            return a.name > b.name
        end
        return a.timestamp_key > b.timestamp_key
    end)
end

function log_tools.register_log_filename(file_name)
    if not log_tools.is_safe_log_filename(file_name) then return false end
    for i = 1, #log_manager_state.records do
        if log_manager_state.records[i].name == file_name then
            return true
        end
    end
    log_manager_state.records[#log_manager_state.records + 1] = {
        name = file_name,
        path = join_path(LOG_DIRECTORY_PATH, file_name),
        timestamp_key = log_tools.log_timestamp_key(file_name),
        display_name = log_tools.log_record_display_name(file_name)
    }
    log_tools.sort_log_records()
    return true
end

function log_tools.read_log_listing(stream)
    if stream == nil then return 0 end
    local count = 0
    for line in stream:lines() do
        local file_name = file_name_from_path(trim_text(line:gsub('^"(.*)"$', "%1")))
        if log_tools.register_log_filename(file_name) then
            count = count + 1
        end
    end
    return count
end

function log_tools.refresh_log_index()
    log_manager_state.records = {}
    log_manager_state.scan_error = ""
    log_manager_state.pending_delete = ""

    local list_command
    if PATH_SEPARATOR == "\\" then
        list_command = 'dir /b /a-d "' .. join_path(LOG_DIRECTORY_PATH, "LMM_*.txt") .. '" 2>NUL'
    else
        list_command = 'find "' .. LOG_DIRECTORY_PATH
            .. '" -maxdepth 1 -type f -name "LMM_*.txt" -print 2>/dev/null'
    end

    local indexed = false
    if type(io.popen) == "function" then
        local open_ok, stream = pcall(io.popen, list_command)
        if open_ok and stream ~= nil then
            local read_ok = pcall(log_tools.read_log_listing, stream)
            pcall(function() stream:close() end)
            indexed = read_ok
        end
    end

    -- 某些 FlyWithLua 构建会禁用 io.popen，此时使用一次性临时清单作为兼容回退。
    if not indexed then
        local fallback_command
        if PATH_SEPARATOR == "\\" then
            fallback_command = 'dir /b /a-d "'
                .. join_path(LOG_DIRECTORY_PATH, "LMM_*.txt")
                .. '" >"'
                .. LOG_INDEX_TEMP_FILE_PATH
                .. '" 2>NUL'
        else
            fallback_command = 'find "'
                .. LOG_DIRECTORY_PATH
                .. '" -maxdepth 1 -type f -name "LMM_*.txt" -print >"'
                .. LOG_INDEX_TEMP_FILE_PATH
                .. '" 2>/dev/null'
        end
        pcall(os.execute, fallback_command)
        local file = io.open(LOG_INDEX_TEMP_FILE_PATH, "r")
        if file ~= nil then
            log_tools.read_log_listing(file)
            file:close()
            os.remove(LOG_INDEX_TEMP_FILE_PATH)
            indexed = true
        end
    end

    log_tools.sort_log_records()
    local page_count = math.max(1, math.ceil(#log_manager_state.records / LOG_MANAGER_PAGE_SIZE))
    if log_manager_state.page > page_count then log_manager_state.page = page_count end
    if log_manager_state.page < 1 then log_manager_state.page = 1 end

    if not indexed then
        log_manager_state.scan_error = "Unable to scan LMM_Log. Check FlyWithLua file permissions."
        if logMsg then
            logMsg("[StarLux LMM] Unable to build landing log index.")
        end
    elseif logMsg then
        logMsg(string.format(
            "[StarLux LMM] Landing log index ready: %d record(s).",
            #log_manager_state.records
        ))
    end
    return indexed
end

function log_tools.html_escape(value)
    local escaped = tostring(value or "")
    escaped = escaped:gsub("&", "&amp;")
    escaped = escaped:gsub("<", "&lt;")
    escaped = escaped:gsub(">", "&gt;")
    escaped = escaped:gsub('"', "&quot;")
    escaped = escaped:gsub("'", "&#39;")
    return escaped
end

function log_tools.url_encode(value)
    return tostring(value or ""):gsub("([^%w%-_%.~])", function(char)
        return string.format("%%%02X", string.byte(char))
    end)
end

function log_tools.parse_number(value)
    if type(value) ~= "string" then return nil end
    local matched = value:match("([%+%-]?%d+%.?%d*)")
    return matched and tonumber(matched) or nil
end

function log_tools.parse_report_fields(content)
    local fields = {}
    for line in content:gmatch("[^\r\n]+") do
        -- 不把全角冒号放进字符类：UTF-8 字节可能误命中全角括号，破坏“机型（ICAO）”等键名。
        local key, value = line:match("^%s*(.-)%s*:%s*(.-)%s*$")
        if key == nil then
            key, value = line:match("^%s*(.-)%s*：%s*(.-)%s*$")
        end
        if key ~= nil and key ~= "" and fields[key] == nil then
            fields[key] = value
        end
    end
    return fields
end

function log_tools.first_report_field(fields, names)
    for i = 1, #names do
        local value = fields[names[i]]
        if value ~= nil and value ~= "" then return value end
    end
    return ""
end

function log_tools.report_status_code(value)
    local upper = string.upper(tostring(value or ""))
    if upper:find("UNSTABLE", 1, true) then return "UNSTABLE" end
    if upper:find("ATTENTION", 1, true) then return "ATTENTION" end
    if upper:find("STABLE", 1, true) then return "STABLE" end
    if upper:find("NICE", 1, true) then return "NICE" end
    return "UNKNOWN"
end

function log_tools.parse_flare_trajectory(content)
    local points = {}
    local in_table = false
    local data_started = false

    for line in content:gmatch("[^\r\n]+") do
        if line:find("0.5秒聚合轨迹表", 1, true) then
            in_table = true
        elseif in_table then
            local values = {}
            for token in line:gmatch("[%+%-]?%d+%.?%d*") do
                values[#values + 1] = tonumber(token)
            end
            if #values >= 3 then
                points[#points + 1] = {
                    t = values[1],
                    ra = values[2],
                    fpm = values[3],
                    vvi = values[4],
                    ias = values[5],
                    gs = values[6],
                    pitch = values[7],
                    aoa = values[8],
                    roll = values[9]
                }
                data_started = true
            elseif data_started then
                break
            end
        end
    end
    return points
end

function log_tools.report_filename_identity(file_name)
    local airport, aircraft, runway = file_name:match("^LMM_([^_]+)_([^_]+)_RWY([^_]+)_")
    return airport or "", aircraft or "", runway or ""
end

function log_tools.parse_landing_report(file_name, content)
    content = content:gsub("^\239\187\191", "")
    local fields = log_tools.parse_report_fields(content)
    local file_airport, file_aircraft, file_runway = log_tools.report_filename_identity(file_name)

    local evaluation = log_tools.first_report_field(fields, { "最终评价", "落地评价" })
    local fpm_text = log_tools.first_report_field(fields, { "触地垂直速度", "触地下降率" })
    local g_text = log_tools.first_report_field(fields, { "最终过载", "最终显示和评分值" })
    local ias_gs_text = log_tools.first_report_field(fields, { "IAS / GS" })
    local ias = log_tools.parse_number(log_tools.first_report_field(fields, { "指示空速（IAS）" }))
    local gs = log_tools.parse_number(log_tools.first_report_field(fields, { "地速（GS）" }))
    if ias_gs_text ~= "" then
        local first, second = ias_gs_text:match(
            "([%+%-]?%d+%.?%d*)%s*/%s*([%+%-]?%d+%.?%d*)"
        )
        ias = tonumber(first) or ias
        gs = tonumber(second) or gs
    end

    local airport_text = log_tools.first_report_field(fields, { "落地机场" })
    local airport = airport_text:match("^([%w]+)") or file_airport
    if airport == "" or airport_text:find("未能识别", 1, true) then airport = "UNKNOWN" end
    local aircraft = log_tools.first_report_field(fields, { "机型（ICAO）" })
    if aircraft == "" then aircraft = file_aircraft end
    if aircraft == "" then aircraft = "UNKNOWN" end
    local runway_text = log_tools.first_report_field(fields, { "触地跑道方向" })
    local runway = runway_text:match("RWY([%w]+)") or file_runway
    if runway == "" then runway = "--" end

    local version = content:match("StarLux.-v(%d+%.%d+%.%d+)")
    local legacy = version == nil
    version = version or "Legacy"

    local report = {
        file_name = file_name,
        raw = content,
        fields = fields,
        version = version,
        legacy = legacy,
        timestamp = log_tools.first_report_field(fields, { "落地时间（本地时间）" }),
        evaluation = evaluation ~= "" and evaluation or "未提供",
        explanation = log_tools.first_report_field(fields, { "评价说明" }),
        status = log_tools.report_status_code(evaluation),
        fpm = log_tools.parse_number(fpm_text),
        fpm_text = fpm_text ~= "" and fpm_text or "无数据",
        g = log_tools.parse_number(g_text),
        g_text = g_text ~= "" and g_text or "无数据",
        airport = airport,
        airport_text = airport_text ~= "" and airport_text or airport,
        aircraft = aircraft,
        runway = runway,
        ias = ias,
        gs = gs,
        tas_text = log_tools.first_report_field(fields, { "真空速（TAS）" }),
        aoa_text = log_tools.first_report_field(fields, { "迎角" }),
        roll_text = log_tools.first_report_field(fields, { "横滚角" }),
        heading_text = log_tools.first_report_field(fields, { "飞机磁航向" }),
        wind_text = log_tools.first_report_field(fields, { "相对风" }),
        wind_source_text = log_tools.first_report_field(fields, { "风向和风速" }),
        surface_text = log_tools.first_report_field(fields, { "道面提示" }),
        surface_source = log_tools.first_report_field(fields, { "道面判定来源" }),
        bounce_text = log_tools.first_report_field(fields, { "弹跳检测" }),
        flare_metric_text = log_tools.first_report_field(fields, { "拉平曲率" }),
        flare_metric = log_tools.parse_number(log_tools.first_report_field(fields, { "拉平曲率" })),
        flare_trend = log_tools.first_report_field(fields, { "拉平轨迹结论", "轨迹结论" }),
        flare_duration = log_tools.first_report_field(fields, { "100 ft 至触地时间" }),
        flare_entry = log_tools.first_report_field(fields, { "100 ft 附近下降率" }),
        flare_recovery = log_tools.first_report_field(fields, { "下降率净改善量" }),
        reversal_count = log_tools.first_report_field(fields, { "明显方向反转次数" }),
        worsening_ratio = log_tools.first_report_field(fields, { "下降率恶化区间比例" }),
        monotonic_efficiency = log_tools.first_report_field(fields, { "单调改善效率" }),
        touch_g = log_tools.parse_number(log_tools.first_report_field(fields, { "触地帧过载" })),
        peak_g = log_tools.parse_number(log_tools.first_report_field(fields, { "第一次压缩原始峰值", "短窗口原始峰值" })),
        curve_g = log_tools.parse_number(log_tools.first_report_field(fields, { "第75百分位曲线 G", "稳健采样值" })),
        baseline_g = log_tools.parse_number(log_tools.first_report_field(fields, { "接地前垂直 G 基线" })),
        equivalent_g = log_tools.parse_number(log_tools.first_report_field(fields, { "冲量等效 G", "FPM/G 一致性上限" })),
        consistency_text = log_tools.first_report_field(fields, { "冲量一致性误差" }),
        confidence_text = log_tools.first_report_field(fields, { "数据可信度" }),
        g_method = log_tools.first_report_field(fields, { "最终 G 采用方式" }),
        impact_samples = log_tools.first_report_field(fields, { "冲击阶段有效样本数" }),
        analysis_ms = log_tools.first_report_field(fields, { "落地分析耗时" }),
        trajectory = log_tools.parse_flare_trajectory(content)
    }
    return report
end

function log_tools.status_visuals(status)
    if status == "UNSTABLE" then return "#B51E2E", "UNSTABLE 重着陆" end
    if status == "ATTENTION" then return "#C47C08", "Attention 需注意" end
    if status == "STABLE" then return "#147A49", "Stable 稳定扎实落地" end
    if status == "NICE" then return "#125B93", "Nice 轻柔接地" end
    return "#596773", "未识别评价"
end

function log_tools.fpm_severity(fpm)
    if fpm == nil then return 0 end
    local value = abs_value(fpm)
    if value <= FPM_NICE_MAX then return 1 end
    if value <= FPM_STABLE_MAX then return 2 end
    if value <= FPM_ATTENTION_MAX then return 3 end
    return 4
end

function log_tools.g_severity(g)
    if g == nil then return 0 end
    if g <= G_NICE_MAX then return 1 end
    if g <= G_STABLE_MAX then return 2 end
    if g <= G_ATTENTION_MAX then return 3 end
    return 4
end

function log_tools.dominant_factor_text(report)
    if report.legacy then
        return "旧版记录保留当时的评分结论，不使用 0.9.0 阈值重新评级。"
    end
    local fpm_level = log_tools.fpm_severity(report.fpm)
    local g_level = log_tools.g_severity(report.g)
    if fpm_level == 0 or g_level == 0 then
        return "报告字段不足，无法比较 FPM 与 G 的评分主导关系。"
    elseif fpm_level > g_level then
        return "FPM 档位更严重，本次评分主要受触地下降率影响。"
    elseif g_level > fpm_level then
        return "G 档位更严重，本次评分主要受接地载荷影响。"
    end
    return "FPM 与 G 处于同一评分档位，结果具有良好的一致性。"
end

function log_tools.meter_percent(value, minimum, maximum)
    if value == nil then return 0 end
    local ratio = (value - minimum) / (maximum - minimum)
    return math.max(0, math.min(100, ratio * 100))
end

function log_tools.js_number(value)
    if value == nil then return "null" end
    return string.format("%.9f", value)
end

function log_tools.write_viewer_html(report)
    local file, err = io.open(LOG_VIEWER_FILE_PATH, "w")
    if file == nil then return false, tostring(err) end

    local status_color, status_label = log_tools.status_visuals(report.status)
    local fpm_value = report.fpm and string.format("%+d fpm", round_num(report.fpm)) or "-- fpm"
    local g_value = report.g and string.format("%.2f G", report.g) or "-- G"
    local ias_value = report.ias and string.format("%.0f kt", report.ias) or "--"
    local gs_value = report.gs and string.format("%.0f kt", report.gs) or "--"
    local fpm_pointer = log_tools.meter_percent(report.fpm and abs_value(report.fpm) or nil, 0, 350)
    local g_pointer = log_tools.meter_percent(report.g, 1.0, 2.0)
    local download_href = log_tools.url_encode(report.file_name)
    local surface_text = report.surface_text ~= "" and report.surface_text or "无"
    local bounce_text = report.bounce_text ~= "" and report.bounce_text or "未提供"
    local flare_trend = report.flare_trend ~= "" and report.flare_trend or "该记录未提供拉平轨迹结论"

    file:write("\239\187\191")
    file:write([=[<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>StarLux LMM 落地报告</title>
<style>
:root{--bg:#08131d;--panel:#102332;--panel2:#142b3c;--line:#284457;--text:#eef5f7;--muted:#9fb2bd;--accent:#2f8dcc;--status:#147a49}
*{box-sizing:border-box}
body{margin:0;background:radial-gradient(circle at 85% -10%,#174968 0,transparent 32%),linear-gradient(180deg,#07121b,#0b1722 55%,#08131d);color:var(--text);font-family:"Microsoft YaHei","PingFang SC","Noto Sans CJK SC",system-ui,sans-serif;min-height:100vh}
a{color:inherit}
.shell{max-width:1180px;margin:auto;padding:30px 22px 64px}
.topbar{display:flex;justify-content:space-between;align-items:center;gap:18px;margin-bottom:22px}
.brand{font-weight:800;letter-spacing:.08em;color:#82c5ef;font-size:13px}
.privacy{font-size:12px;color:#b9d9c8;border:1px solid #2b6d4a;background:#102b21;border-radius:999px;padding:7px 12px}
.hero{position:relative;overflow:hidden;border:1px solid #31566e;background:linear-gradient(135deg,rgba(27,64,88,.96),rgba(10,31,45,.98));border-radius:22px;padding:28px;box-shadow:0 26px 70px rgba(0,0,0,.28)}
.hero:after{content:"";position:absolute;width:260px;height:260px;border-radius:50%;right:-90px;top:-120px;background:var(--status);opacity:.14}
.hero-grid{position:relative;z-index:1;display:grid;grid-template-columns:1fr auto;gap:20px;align-items:start}
.eyebrow{font-size:12px;color:#9ccce9;letter-spacing:.08em;margin-bottom:9px}
h1{font-size:30px;line-height:1.2;margin:0 0 10px}
.sub{color:var(--muted);font-size:14px;line-height:1.7}
.status{min-width:220px;border-left:9px solid var(--status);background:rgba(4,15,23,.48);border-radius:13px;padding:16px 18px}
.status small{display:block;color:var(--muted);font-size:11px;margin-bottom:6px}
.status strong{font-size:18px;color:#fff}
.actions{display:flex;gap:10px;flex-wrap:wrap;margin-top:20px}
.btn{display:inline-flex;align-items:center;text-decoration:none;border-radius:10px;padding:10px 15px;font-weight:700;font-size:13px;border:1px solid #3a6076;background:#17364a}
.btn.primary{background:var(--status);border-color:var(--status)}
.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin-top:16px}
.card,.section{border:1px solid var(--line);background:linear-gradient(180deg,rgba(18,43,60,.96),rgba(13,32,45,.96));border-radius:16px}
.card{padding:16px;min-height:112px}
.card .label{font-size:12px;color:var(--muted);margin-bottom:11px}
.card .value{font-size:25px;font-weight:800;letter-spacing:-.02em}
.card .hint{font-size:12px;color:#aec0c9;margin-top:7px;line-height:1.5}
.layout{display:grid;grid-template-columns:1.45fr .75fr;gap:16px;margin-top:16px}
.section{padding:20px}
.section h2{font-size:18px;margin:0 0 5px}
.section .lead{font-size:12px;color:var(--muted);margin-bottom:18px}
.meter-wrap{margin:17px 0 23px}
.meter-head{display:flex;justify-content:space-between;font-size:13px;margin-bottom:8px}
.meter{height:15px;border-radius:999px;background:linear-gradient(90deg,#125b93 0 28.5%,#147a49 28.5% 71.4%,#c47c08 71.4% 85.7%,#b51e2e 85.7%);position:relative;box-shadow:inset 0 0 0 1px rgba(255,255,255,.12)}
.meter.g{background:linear-gradient(90deg,#125b93 0 20%,#147a49 20% 50%,#c47c08 50% 80%,#b51e2e 80%)}
.pointer{position:absolute;top:-5px;width:4px;height:25px;border-radius:4px;background:#fff;box-shadow:0 0 0 2px rgba(0,0,0,.45)}
.scale{display:flex;justify-content:space-between;color:#8196a2;font-size:10px;margin-top:5px}
.insight{border-left:4px solid var(--status);background:rgba(255,255,255,.04);padding:12px 14px;border-radius:8px;margin:10px 0;font-size:13px;line-height:1.65}
.facts{display:grid;grid-template-columns:1fr 1fr;gap:0 18px}
.fact{padding:11px 0;border-bottom:1px solid rgba(125,159,178,.2)}
.fact span{display:block;color:var(--muted);font-size:11px;margin-bottom:4px}.fact b{font-size:13px;font-weight:600}
.chart-box{position:relative;height:350px;margin-top:12px}
canvas{display:block;width:100%;height:100%}
.tooltip{display:none;position:absolute;pointer-events:none;background:#031019;border:1px solid #3d6b84;border-radius:9px;padding:9px 11px;font-size:11px;line-height:1.5;box-shadow:0 8px 25px rgba(0,0,0,.4)}
.empty{height:210px;display:flex;align-items:center;justify-content:center;text-align:center;color:var(--muted);border:1px dashed #355268;border-radius:12px}
.diag{width:100%;border-collapse:collapse;margin-top:10px;font-size:12px}.diag td{padding:9px;border-bottom:1px solid rgba(125,159,178,.2)}.diag td:first-child{color:var(--muted)}
details{margin-top:16px;border:1px solid var(--line);background:#0b1c28;border-radius:14px;padding:15px}
summary{cursor:pointer;font-weight:700;color:#b9d7e8}
pre{white-space:pre-wrap;word-break:break-word;font-family:Consolas,"Microsoft YaHei",monospace;font-size:11px;line-height:1.65;color:#c8d7df;max-height:540px;overflow:auto;padding:12px;background:#07141e;border-radius:9px}
footer{color:#7f949f;font-size:11px;line-height:1.7;margin-top:24px;text-align:center}
@media(max-width:850px){.grid{grid-template-columns:1fr 1fr}.layout{grid-template-columns:1fr}.hero-grid{grid-template-columns:1fr}.status{min-width:0}.facts{grid-template-columns:1fr}}
@media(max-width:520px){.grid{grid-template-columns:1fr}.shell{padding:18px 12px 45px}h1{font-size:24px}.hero{padding:20px}}
</style>
</head>
<body>
<main class="shell">
<div class="topbar"><div class="brand">STARLUX LANDING METRICS MONITOR · 0.9.0</div><div class="privacy">本地生成 · 数据未上传</div></div>
<section class="hero">
<div class="hero-grid"><div>
<div class="eyebrow">LANDING REPORT · ]=])
    file:write(log_tools.html_escape(report.timestamp ~= "" and report.timestamp or report.file_name))
    file:write([=[</div><h1>]=])
    file:write(log_tools.html_escape(report.airport .. " · RWY" .. report.runway .. " · " .. report.aircraft))
    file:write([=[</h1><div class="sub">]=])
    file:write(log_tools.html_escape(report.explanation ~= "" and report.explanation or "此记录未提供评价说明。"))
    file:write([=[</div><div class="actions"><a class="btn primary" href="]=])
    file:write(download_href)
    file:write([=[" download>下载原始 TXT</a><a class="btn" href="#raw">查看完整原文</a></div></div><div class="status"><small>最终评价</small><strong>]=])
    file:write(log_tools.html_escape(status_label))
    file:write([=[</strong><div class="hint">报告版本 v]=])
    file:write(log_tools.html_escape(report.version))
    file:write([=[</div></div></div></section>
<section class="grid">]=])

    local cards = {
        { "触地下降率", fpm_value, "250 ms 物理速度稳健值" },
        { "最终载荷", g_value, "曲线、冲量与速度变化互证" },
        { "指示空速 / 地速", ias_value .. " / " .. gs_value, "IAS / GS" },
        { "拉平曲率", report.flare_metric and string.format("%.1f", report.flare_metric) or "--", flare_trend }
    }
    for i = 1, #cards do
        file:write('<article class="card"><div class="label">'
            .. log_tools.html_escape(cards[i][1])
            .. '</div><div class="value">'
            .. log_tools.html_escape(cards[i][2])
            .. '</div><div class="hint">'
            .. log_tools.html_escape(cards[i][3])
            .. "</div></article>")
    end

    file:write([=[</section>
<div class="layout">
<section class="section"><h2>评分构成</h2><div class="lead">用当前报告中的 FPM 与 G 解释最终等级，不对历史记录暗中改分。</div>
<div class="meter-wrap"><div class="meter-head"><span>下降率严重度</span><b>]=])
    file:write(log_tools.html_escape(fpm_value))
    file:write([=[</b></div><div class="meter"><i class="pointer" style="left:calc(]=])
    file:write(string.format("%.2f", fpm_pointer))
    file:write([=[% - 2px)"></i></div><div class="scale"><span>0</span><span>100</span><span>250</span><span>300+</span></div></div>
<div class="meter-wrap"><div class="meter-head"><span>接地载荷严重度</span><b>]=])
    file:write(log_tools.html_escape(g_value))
    file:write([=[</b></div><div class="meter g"><i class="pointer" style="left:calc(]=])
    file:write(string.format("%.2f", g_pointer))
    file:write([=[% - 2px)"></i></div><div class="scale"><span>1.00</span><span>1.20</span><span>1.50</span><span>1.80+</span></div></div>
<div class="insight">]=])
    file:write(log_tools.html_escape(log_tools.dominant_factor_text(report)))
    file:write([=[</div><div class="insight">]=])
    file:write(log_tools.html_escape("拉平分析：" .. flare_trend))
    file:write([=[</div><div class="insight">]=])
    file:write(log_tools.html_escape("弹跳状态：" .. bounce_text .. "；道面提示：" .. surface_text))
    file:write([=[</div></section>
<aside class="section"><h2>着陆上下文</h2><div class="lead">帮助快速还原这次接地所处的环境。</div><div class="facts">]=])

    local facts = {
        { "机场", report.airport_text },
        { "跑道方向", "RWY" .. report.runway .. "（推算）" },
        { "机型", report.aircraft },
        { "相对风", report.wind_text ~= "" and report.wind_text or "--" },
        { "迎角", report.aoa_text ~= "" and report.aoa_text or "--" },
        { "横滚", report.roll_text ~= "" and report.roll_text or "--" },
        { "拉平用时", report.flare_duration ~= "" and report.flare_duration or "--" },
        { "净改善量", report.flare_recovery ~= "" and report.flare_recovery or "--" }
    }
    for i = 1, #facts do
        file:write('<div class="fact"><span>'
            .. log_tools.html_escape(facts[i][1])
            .. "</span><b>"
            .. log_tools.html_escape(facts[i][2])
            .. "</b></div>")
    end

    file:write([=[</div></aside></div>
<div class="layout">
<section class="section"><h2>100 ft 后拉平轨迹</h2><div class="lead">纵轴为物理下降率，悬停可查看时间、无线电高度与速度。</div>]=])
    if #report.trajectory >= 2 then
        file:write('<div class="chart-box"><canvas id="flareChart"></canvas><div class="tooltip" id="chartTip"></div></div>')
    else
        file:write('<div class="empty">该版本日志未包含可绘制的 0.5 秒聚合轨迹。<br>仍可在下方查看原始报告。</div>')
    end
    file:write([=[</section>
<aside class="section"><h2>载荷诊断</h2><div class="lead">完整数学日志开启时可看到更多中间量。</div><table class="diag">]=])

    local diagnostics = {
        { "最终 G", report.g and string.format("%.3f G", report.g) or "--" },
        { "触地帧 G", report.touch_g and string.format("%.3f G", report.touch_g) or "--" },
        { "原始峰值", report.peak_g and string.format("%.3f G", report.peak_g) or "--" },
        { "P75 曲线 G", report.curve_g and string.format("%.3f G", report.curve_g) or "--" },
        { "接地前基线", report.baseline_g and string.format("%.3f G", report.baseline_g) or "--" },
        { "冲量等效 G", report.equivalent_g and string.format("%.3f G", report.equivalent_g) or "--" },
        { "一致性误差", report.consistency_text ~= "" and report.consistency_text or "--" },
        { "数据可信度", report.confidence_text ~= "" and report.confidence_text or "--" },
        { "有效样本", report.impact_samples ~= "" and report.impact_samples or "--" },
        { "分析耗时", report.analysis_ms ~= "" and report.analysis_ms or "--" }
    }
    for i = 1, #diagnostics do
        file:write("<tr><td>"
            .. log_tools.html_escape(diagnostics[i][1])
            .. "</td><td>"
            .. log_tools.html_escape(diagnostics[i][2])
            .. "</td></tr>")
    end

    file:write([=[</table></aside></div>
<details id="raw"><summary>展开完整原始 TXT</summary><pre>]=])
    file:write(log_tools.html_escape(report.raw))
    file:write([=[</pre></details>
<footer>StarLux LMM 0.9.0 本地可视化 · 页面由插件在用户电脑上即时生成<br>本报告仅用于飞行模拟复盘，不替代航司、维修或适航判定。</footer>
</main>
<script>
const flareData = []=])
    for i = 1, #report.trajectory do
        local point = report.trajectory[i]
        if i > 1 then file:write(",") end
        file:write("{t:"
            .. log_tools.js_number(point.t)
            .. ",ra:"
            .. log_tools.js_number(point.ra)
            .. ",fpm:"
            .. log_tools.js_number(point.fpm)
            .. ",ias:"
            .. log_tools.js_number(point.ias)
            .. ",gs:"
            .. log_tools.js_number(point.gs)
            .. "}")
    end
    file:write([=[]; 
const statusColor = "]=])
    file:write(status_color)
    file:write([=[";
document.documentElement.style.setProperty("--status",statusColor);
function drawFlare(){
 const canvas=document.getElementById("flareChart"); if(!canvas||flareData.length<2)return;
 const box=canvas.getBoundingClientRect(),dpr=window.devicePixelRatio||1;
 canvas.width=Math.max(1,Math.floor(box.width*dpr));canvas.height=Math.max(1,Math.floor(box.height*dpr));
 const c=canvas.getContext("2d");c.setTransform(dpr,0,0,dpr,0,0);
 const W=box.width,H=box.height,p={l:58,r:20,t:18,b:42},pw=W-p.l-p.r,ph=H-p.t-p.b;
 const ts=flareData.map(x=>x.t),ys=flareData.map(x=>x.fpm);
 let xmin=Math.min(...ts),xmax=Math.max(...ts),ymin=Math.min(...ys),ymax=Math.max(...ys);
 if(ymax-ymin<60){ymax+=30;ymin-=30}else{const pad=(ymax-ymin)*.12;ymax+=pad;ymin-=pad}
 const X=x=>p.l+(x-xmin)/(xmax-xmin||1)*pw,Y=y=>p.t+(ymax-y)/(ymax-ymin||1)*ph;
 c.clearRect(0,0,W,H);c.font="11px Microsoft YaHei";c.lineWidth=1;
 for(let i=0;i<=4;i++){const y=p.t+ph*i/4,v=ymax-(ymax-ymin)*i/4;c.strokeStyle="#294657";c.beginPath();c.moveTo(p.l,y);c.lineTo(W-p.r,y);c.stroke();c.fillStyle="#91a7b3";c.textAlign="right";c.fillText(Math.round(v)+" fpm",p.l-8,y+4)}
 for(let i=0;i<=5;i++){const x=p.l+pw*i/5,v=xmin+(xmax-xmin)*i/5;c.strokeStyle="#223d4f";c.beginPath();c.moveTo(x,p.t);c.lineTo(x,p.t+ph);c.stroke();c.fillStyle="#91a7b3";c.textAlign="center";c.fillText(v.toFixed(1)+"s",x,H-14)}
 const grad=c.createLinearGradient(0,p.t,0,p.t+ph);grad.addColorStop(0,statusColor);grad.addColorStop(1,"#2f8dcc");
 c.strokeStyle=grad;c.lineWidth=3;c.lineJoin="round";c.beginPath();
 flareData.forEach((d,i)=>{const x=X(d.t),y=Y(d.fpm);i?c.lineTo(x,y):c.moveTo(x,y)});c.stroke();
 c.lineTo(X(flareData.at(-1).t),p.t+ph);c.lineTo(X(flareData[0].t),p.t+ph);c.closePath();
 const fill=c.createLinearGradient(0,p.t,0,p.t+ph);fill.addColorStop(0,statusColor+"55");fill.addColorStop(1,statusColor+"05");c.fillStyle=fill;c.fill();
 canvas._plot={X,Y,p,pw,ph,xmin,xmax,ymin,ymax};
}
function hoverFlare(ev){
 const canvas=ev.currentTarget,tip=document.getElementById("chartTip"),plot=canvas._plot;if(!plot)return;
 const rect=canvas.getBoundingClientRect(),mx=ev.clientX-rect.left;
 let best=flareData[0],dist=Infinity;flareData.forEach(d=>{const q=Math.abs(plot.X(d.t)-mx);if(q<dist){dist=q;best=d}});
 tip.style.display="block";tip.style.left=Math.min(rect.width-155,Math.max(8,plot.X(best.t)+14))+"px";tip.style.top=Math.max(8,plot.Y(best.fpm)-48)+"px";
 tip.innerHTML="<b>T+"+best.t.toFixed(2)+" s</b><br>"+Math.round(best.fpm)+" fpm · RA "+(best.ra??0).toFixed(1)+" ft<br>IAS "+Math.round(best.ias??0)+" / GS "+Math.round(best.gs??0)+" kt";
}
window.addEventListener("resize",drawFlare);window.addEventListener("load",drawFlare);
const chart=document.getElementById("flareChart");if(chart){chart.addEventListener("mousemove",hoverFlare);chart.addEventListener("mouseleave",()=>document.getElementById("chartTip").style.display="none")}
</script></body></html>]=])

    local close_ok, close_error = file:close()
    if close_ok == nil then return false, tostring(close_error) end
    return true, LOG_VIEWER_FILE_PATH
end

function log_tools.open_viewer_in_default_browser(path)
    local clean_path = tostring(path or ""):gsub('"', "")
    local command
    if PATH_SEPARATOR == "\\" then
        command = 'cmd /c start "" "' .. clean_path .. '"'
    elseif type(jit) == "table" and jit.os == "OSX" then
        command = 'open "' .. clean_path .. '" >/dev/null 2>&1 &'
    else
        command = 'xdg-open "' .. clean_path .. '" >/dev/null 2>&1 &'
    end
    local call_ok, result = pcall(os.execute, command)
    if not call_ok then return false, tostring(result) end
    if result == nil or result == false then
        return false, "The operating system did not accept the open command."
    end
    if type(result) == "number" and result ~= 0 then
        return false, "Open command exited with code " .. tostring(result) .. "."
    end
    return true
end

function log_tools.find_indexed_log(file_name)
    for i = 1, #log_manager_state.records do
        local record = log_manager_state.records[i]
        if record.name == file_name then return record end
    end
    return nil
end

function log_tools.open_log_visualization(file_name)
    local record = log_tools.find_indexed_log(file_name)
    if record == nil or not log_tools.is_safe_log_filename(file_name) then
        return false, "The selected record is no longer available."
    end

    local source, open_error = io.open(record.path, "rb")
    if source == nil then return false, tostring(open_error) end
    local content = source:read("*a")
    source:close()
    if content == nil or content == "" then return false, "The selected TXT is empty." end

    local report = log_tools.parse_landing_report(file_name, content)
    local write_ok, result = log_tools.write_viewer_html(report)
    if not write_ok then return false, result end
    local browser_ok, browser_error = log_tools.open_viewer_in_default_browser(result)
    if not browser_ok then return false, browser_error end
    return true
end

function log_tools.delete_indexed_log(file_name)
    local record = log_tools.find_indexed_log(file_name)
    if record == nil or not log_tools.is_safe_log_filename(file_name) then
        return false, "Delete blocked: record is outside the verified index."
    end
    local remove_ok, remove_error = os.remove(record.path)
    if not remove_ok then return false, tostring(remove_error) end
    for i = #log_manager_state.records, 1, -1 do
        if log_manager_state.records[i].name == file_name then
            table.remove(log_manager_state.records, i)
            break
        end
    end
    log_manager_state.pending_delete = ""
    local page_count = math.max(1, math.ceil(#log_manager_state.records / LOG_MANAGER_PAGE_SIZE))
    if log_manager_state.page > page_count then log_manager_state.page = page_count end
    return true
end

local function status_explanation(status)
    if bounce_state.score_applied and bounce_state.original_status ~= status then
        if status == "UNSTABLE" then
            return "发生弹跳，且至少一次稳健过载超过 1.80 G"
        end
        return "发生弹跳：评级由 "
            .. status_short(bounce_state.original_status)
            .. " 降级为 "
            .. status_short(status)
    end
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
    local aircraft_token = sanitize_filename_token(landing_context.aircraft_icao)
    local runway_token = sanitize_filename_token(landing_context.runway)
    local file_timestamp = landing_context.file_timestamp
    if file_timestamp == "" then
        file_timestamp = os.date("%Y-%m-%d_%H-%M-%S")
    end
    local base_name = "LMM_"
        .. airport_token
        .. "_"
        .. aircraft_token
        .. "_RWY"
        .. runway_token
        .. "_"
        .. file_timestamp
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
            "[StarLux LMM] Aircraft=%s | Airport=%s | RWY~%s | Surface=%s | FlareCurve=%.1f trend=%s samples=%d | Bounce=%s second=%dfpm/%.2fG | FPM vviMedian=%d physicalP25=%d selected=%d | G touch=%.2f peak=%.2f curve=%.2f equiv=%.2f used=%.2f | impulseErr=%.0f%% confidence=%s method=%s | IAS=%.0f GS=%.0f AoA=%.1f Roll=%.1f | Wind=%03d/%dkt | Mode=%s | Layout=%s",
            landing_context.aircraft_icao,
            landing_context.airport_id,
            landing_context.runway,
            landing_surface.warning_type,
            flare_analysis.metric,
            flare_analysis.trend_text,
            flare_trace.count,
            bounce_state.detected and "YES" or "NO",
            bounce_state.second_fpm,
            bounce_state.second_curve_g,
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

local function collect_audit_values(source, count, start_time, end_time, value_kind, airborne_only)
    local old_count = sort_scratch_count
    local selected_count = 0
    for i = 1, count do
        local sample = source[i]
        if sample.t >= start_time and sample.t <= end_time
            and (not airborne_only or sample.on_ground == 0) then
            local value = nil
            if value_kind == "local_vy" then
                value = sample.local_vy_mps
            elseif value_kind == "vvi" then
                value = sample.vvi_fpm
            elseif value_kind == "projected_g" and sample.projected_g > 0 then
                value = sample.projected_g
            end
            if value ~= nil then
                selected_count = selected_count + 1
                sort_scratch[selected_count] = value
            end
        end
    end
    for i = selected_count + 1, old_count do
        sort_scratch[i] = nil
    end
    sort_scratch_count = selected_count
    if selected_count > 1 then table.sort(sort_scratch) end
    return selected_count
end

local function write_sorted_scratch(file, label, decimals)
    file:write(label .. "（升序，n=" .. tostring(sort_scratch_count) .. "）:\n")
    if sort_scratch_count == 0 then
        file:write("  无有效样本\n")
        return
    end
    local number_format = "%." .. tostring(decimals) .. "f"
    for i = 1, sort_scratch_count do
        if (i - 1) % 8 == 0 then
            file:write("  ")
        end
        file:write(string.format("[%d]=", i))
        file:write(string.format(number_format, sort_scratch[i]))
        if i % 8 == 0 or i == sort_scratch_count then
            file:write("\n")
        else
            file:write("  ")
        end
    end
end

local function math_boolean_text(value)
    return value and "是" or "否"
end

local function audit_flag(enabled, text)
    if enabled then return text end
    return "-"
end

local function write_second_touch_math_audit(file)
    if bounce_state.detected == false then return end

    local touch_time = bounce_state.second_touch_time
    local fpm_start = touch_time - PHYSICAL_FPM_WINDOW_SECONDS
    file:write("附录A、第二次触地数学复算\n")
    file:write("----------------------------------------------------------------------\n")
    file:write("第二次触地审计样本数: " .. tostring(math_audit.second_count) .. "\n")
    file:write("第二次触地审计是否截断: " .. math_boolean_text(math_audit.second_limited) .. "\n")
    file:write("编号  T相对(s)    地面  rawG       pitch       roll        projectedG  localVy(m/s)  physicalFPM   VVI(fpm)\n")
    file:write("-------------------------------------------------------------------------------------------------------------\n")
    for i = 1, math_audit.second_count do
        local sample = math_audit.second_samples[i]
        file:write(string.format(
            "%4d  %+11.9f  %4d  %.9f  %+10.6f  %+10.6f  %.9f  %+12.9f  %+11.6f  %+10.6f\n",
            i,
            sample.t - touch_time,
            sample.on_ground,
            sample.g_normal,
            sample.pitch_deg,
            sample.roll_deg,
            sample.projected_g,
            sample.local_vy_mps,
            sample.local_vy_mps * 196.850394,
            sample.vvi_fpm
        ))
    end

    local fpm_count = collect_audit_values(
        math_audit.second_samples,
        math_audit.second_count,
        fpm_start,
        touch_time,
        "local_vy",
        true
    )
    local fpm_index = fpm_count > 0
        and math.max(1, math.ceil(fpm_count * PHYSICAL_FPM_PERCENTILE)) or 0
    local fpm_value = fpm_index > 0 and sort_scratch[fpm_index] or 0
    write_sorted_scratch(file, "第二次触地前250ms离地物理速度(m/s)", 9)
    file:write(string.format(
        "P25索引 = ceil(%d × %.2f) = %d；%.9f m/s × 196.850394 = %.9f fpm；显示 = %d fpm\n\n",
        fpm_count,
        PHYSICAL_FPM_PERCENTILE,
        fpm_index,
        fpm_value,
        fpm_value * 196.850394,
        bounce_state.second_fpm
    ))

    local second_g_count = collect_audit_values(
        math_audit.second_samples,
        math_audit.second_count,
        touch_time,
        math.huge,
        "projected_g",
        false
    )
    local second_g_index = second_g_count > 0
        and math.max(1, math.ceil(second_g_count * G_CURVE_PERCENTILE)) or 0
    local second_g_value = second_g_index > 0
        and sort_scratch[second_g_index] or bounce_state.second_touch_g
    write_sorted_scratch(file, "第二次触地压缩垂直投影G", 9)
    file:write(string.format(
        "P75索引 = ceil(%d × %.2f) = %d；复算G = %.9f；算法保存G = %.9f\n",
        second_g_count,
        G_CURVE_PERCENTILE,
        second_g_index,
        second_g_value,
        bounce_state.second_curve_g
    ))
    file:write(string.format(
        "弹跳评分比较: 第一次稳健G %.9f，第二次稳健G %.9f，红色阈值 %.2f G。\n\n",
        landing_g,
        bounce_state.second_curve_g,
        G_ATTENTION_MAX
    ))
end

local function write_primary_math_audit(file)
    local touch_time = landing_analysis.touch_time
    local physical_start = touch_time - PHYSICAL_FPM_WINDOW_SECONDS
    local short_start = touch_time - PHYSICAL_FPM_SHORT_WINDOW_SECONDS
    local diagnostic_start = touch_time - VVI_DIAGNOSTIC_WINDOW_SECONDS
    local baseline_start = touch_time - G_BASELINE_WINDOW_SECONDS
    local post_start = math.max(touch_time, landing_analysis.end_time - 0.05)
    local impact_start = landing_analysis.impact_start_time
    local impact_end = landing_analysis.impact_end_time

    file:write("六、数学复算区\n")
    file:write("----------------------------------------------------------------------\n")
    file:write("说明: 本节保存核心计算输入、窗口、排序、索引和公式；所有时间均以第一次触地 T=0 为基准。\n")
    file:write("显示值可能按界面位数四舍五入，复算请使用本节保留的高精度值。\n")
    file:write("垂直投影G公式: projectedG = rawNormalG × cos(pitchDeg×π/180) × cos(rollDeg×π/180)\n")
    file:write(string.format("触地绝对模拟时间: %.9f s\n", touch_time))
    file:write(string.format("第一次压缩起点: T%+.9f s\n", impact_start - touch_time))
    file:write(string.format("第一次压缩终点: T%+.9f s\n", impact_end - touch_time))
    file:write(string.format(
        "第一次压缩时长 = max(0.03, 终点-起点) = %.9f s\n",
        landing_analysis.stop_duration_seconds
    ))
    file:write("审计快照样本数: " .. tostring(math_audit.count) .. "\n")
    file:write("审计快照是否截断: " .. math_boolean_text(math_audit.limited) .. "\n\n")

    file:write("逐样本审计表\n")
    file:write("编号  T相对(s)    地面  rawG       pitch       roll        projectedG  localVy(m/s)  physicalFPM   VVI(fpm)   窗口标记\n")
    file:write("--------------------------------------------------------------------------------------------------------------------------------\n")
    for i = 1, math_audit.count do
        local sample = math_audit.samples[i]
        local airborne = sample.on_ground == 0
        local in_physical = airborne and sample.t >= physical_start and sample.t <= touch_time
        local in_short = airborne and sample.t >= short_start and sample.t <= touch_time
        local in_diagnostic = airborne and sample.t >= diagnostic_start and sample.t <= touch_time
        local in_baseline = airborne and sample.t >= baseline_start and sample.t <= impact_start
        local in_impact = sample.t >= impact_start and sample.t <= impact_end
        local in_post = sample.t >= post_start and sample.t <= landing_analysis.end_time
        local flags = table.concat({
            audit_flag(in_physical, "F250"),
            audit_flag(in_short, "F80"),
            audit_flag(in_diagnostic, "V850"),
            audit_flag(in_baseline, "BASE"),
            audit_flag(in_impact, "IMPACT"),
            audit_flag(in_post, "POST")
        }, ",")
        file:write(string.format(
            "%4d  %+11.9f  %4d  %.9f  %+10.6f  %+10.6f  %.9f  %+12.9f  %+11.6f  %+10.6f  %s\n",
            i,
            sample.t - touch_time,
            sample.on_ground,
            sample.g_normal,
            sample.pitch_deg,
            sample.roll_deg,
            sample.projected_g,
            sample.local_vy_mps,
            sample.local_vy_mps * 196.850394,
            sample.vvi_fpm,
            flags
        ))
    end
    file:write("\n窗口标记: F250=250ms物理FPM/VVI，F80=80ms短窗，V850=850ms最差VVI，BASE=接地前G基线，IMPACT=第一次压缩，POST=压缩末端速度。\n\n")

    local physical_count = collect_audit_values(
        math_audit.samples,
        math_audit.count,
        physical_start,
        touch_time,
        "local_vy",
        true
    )
    local physical_index = physical_count > 0
        and math.max(1, math.ceil(physical_count * PHYSICAL_FPM_PERCENTILE)) or 0
    local physical_value = physical_index > 0 and sort_scratch[physical_index] or 0
    write_sorted_scratch(file, "250ms物理垂直速度(m/s)", 9)
    file:write(string.format(
        "P25索引 = ceil(%d × %.2f) = %d；选中 %.9f m/s × 196.850394 = %.9f fpm；显示四舍五入 = %d fpm\n\n",
        physical_count,
        PHYSICAL_FPM_PERCENTILE,
        physical_index,
        physical_value,
        physical_value * 196.850394,
        landing_fpm
    ))

    local short_count = collect_audit_values(
        math_audit.samples,
        math_audit.count,
        short_start,
        touch_time,
        "local_vy",
        true
    )
    local short_value = scratch_median() or 0
    write_sorted_scratch(file, "80ms物理垂直速度(m/s)", 9)
    file:write(string.format(
        "短窗中位数 = %.9f m/s；换算 = %.9f fpm\n\n",
        short_value,
        short_value * 196.850394
    ))

    local vvi_count = collect_audit_values(
        math_audit.samples,
        math_audit.count,
        physical_start,
        touch_time,
        "vvi",
        true
    )
    local vvi_value = scratch_median() or 0
    write_sorted_scratch(file, "250ms VVI(fpm)", 6)
    file:write(string.format("VVI中位数(n=%d) = %.9f fpm\n\n", vvi_count, vvi_value))

    local diagnostic_count = collect_audit_values(
        math_audit.samples,
        math_audit.count,
        diagnostic_start,
        touch_time,
        "vvi",
        true
    )
    local diagnostic_min = diagnostic_count > 0 and sort_scratch[1] or 0
    local diagnostic_selected = math.min(approach_data.vs_fpm, diagnostic_min)
    write_sorted_scratch(file, "850ms VVI诊断值(fpm)", 6)
    file:write(string.format(
        "最差VVI = min(触地前快照 %.9f, 升序第1项 %.9f) = %.9f fpm；算法保存值 = %.9f fpm\n\n",
        approach_data.vs_fpm,
        diagnostic_min,
        diagnostic_selected,
        landing_analysis.vvi_min_fpm
    ))

    local baseline_count = collect_audit_values(
        math_audit.samples,
        math_audit.count,
        baseline_start,
        impact_start,
        "projected_g",
        true
    )
    local baseline_value = scratch_median() or 1
    write_sorted_scratch(file, "接地前垂直投影G基线样本", 9)
    file:write(string.format(
        "基线中位数(n=%d) = %.9f G；算法保存值 = %.9f G\n\n",
        baseline_count,
        baseline_value,
        landing_analysis.baseline_g
    ))

    local post_count = collect_audit_values(
        math_audit.samples,
        math_audit.count,
        post_start,
        landing_analysis.end_time,
        "local_vy",
        false
    )
    local post_value = scratch_median() or 0
    write_sorted_scratch(file, "压缩末端50ms物理垂直速度(m/s)", 9)
    file:write(string.format(
        "压缩前短窗中位数 = %.9f m/s；压缩后中位数(n=%d) = %.9f m/s\n",
        landing_analysis.pre_vy_mps,
        post_count,
        post_value
    ))
    file:write(string.format(
        "实际速度变化 = max(0, %.9f - (%.9f)) = %.9f m/s\n\n",
        landing_analysis.post_vy_mps,
        landing_analysis.pre_vy_mps,
        landing_analysis.velocity_delta_mps
    ))

    local impact_count = collect_audit_values(
        math_audit.samples,
        math_audit.count,
        impact_start,
        impact_end,
        "projected_g",
        false
    )
    local curve_index = impact_count > 0
        and math.max(1, math.ceil(impact_count * G_CURVE_PERCENTILE)) or 0
    local curve_value = curve_index > 0 and sort_scratch[curve_index] or landing_touch_g
    local projected_peak_value = impact_count > 0 and sort_scratch[impact_count] or 0
    write_sorted_scratch(file, "第一次压缩垂直投影G", 9)
    file:write(string.format(
        "P75索引 = ceil(%d × %.2f) = %d；第75百分位曲线G = %.9f G\n",
        impact_count,
        G_CURVE_PERCENTILE,
        curve_index,
        curve_value
    ))
    file:write(string.format(
        "投影G样本峰值 = %.9f G；触地帧原始G = %.9f G\n",
        projected_peak_value,
        landing_touch_g
    ))
    file:write(string.format(
        "算法峰值 = max(触地帧原始G, 投影G样本峰值) = %.9f G；算法保存曲线G = %.9f G\n\n",
        landing_peak_g,
        landing_analysis.curve_g
    ))

    local high_threshold = landing_analysis.baseline_g
        + math.max(0, landing_peak_g - landing_analysis.baseline_g) * 0.80
    local replay_impulse = 0
    local replay_high_duration = 0
    local replay_gap_sum = 0
    local replay_gap_count = 0
    local replay_max_gap = 0
    local previous_t = nil
    local previous_g = nil
    file:write("冲量梯形积分逐段复算\n")
    file:write(string.format(
        "高G阈值 = baseline + (peak-baseline)×0.80 = %.9f G\n",
        high_threshold
    ))
    file:write("段号  dt(s)       G前         G后         excess前    excess后    本段Δv(m/s)  累计Δv(m/s)  高G段\n")
    file:write("------------------------------------------------------------------------------------------------\n")
    local segment_index = 0
    for i = 1, math_audit.count do
        local sample = math_audit.samples[i]
        if sample.t >= impact_start and sample.t <= impact_end and sample.projected_g > 0 then
            if previous_t ~= nil then
                segment_index = segment_index + 1
                local dt = sample.t - previous_t
                local previous_excess = math.max(0, previous_g - landing_analysis.baseline_g)
                local current_excess = math.max(0, sample.projected_g - landing_analysis.baseline_g)
                local contribution = 0
                local high_segment = false
                if dt > replay_max_gap then replay_max_gap = dt end
                if dt > 0 and dt <= 0.10 then
                    replay_gap_sum = replay_gap_sum + dt
                    replay_gap_count = replay_gap_count + 1
                    contribution = (previous_excess + current_excess)
                        * 0.5 * 9.80665 * dt
                    replay_impulse = replay_impulse + contribution
                    if previous_g >= high_threshold and sample.projected_g >= high_threshold then
                        replay_high_duration = replay_high_duration + dt
                        high_segment = true
                    end
                end
                file:write(string.format(
                    "%4d  %.9f  %.9f  %.9f  %.9f  %.9f  %.9f    %.9f    %s\n",
                    segment_index,
                    dt,
                    previous_g,
                    sample.projected_g,
                    previous_excess,
                    current_excess,
                    contribution,
                    replay_impulse,
                    math_boolean_text(high_segment)
                ))
            end
            previous_t = sample.t
            previous_g = sample.projected_g
        end
    end
    file:write(string.format(
        "\n冲量公式: Σ[(excess前+excess后)/2 × 9.80665 × dt] = %.9f m/s；算法保存值 = %.9f m/s\n",
        replay_impulse,
        landing_analysis.impulse_delta_mps
    ))
    file:write(string.format(
        "高G持续时间复算 = %.9f s；算法保存值 = %.9f s\n",
        replay_high_duration,
        landing_analysis.high_g_duration_seconds
    ))
    file:write(string.format(
        "平均样本间隔复算 = %.9f s；最大样本间隔复算 = %.9f s；算法保存最大间隔 = %.9f s\n",
        replay_gap_count > 0 and replay_gap_sum / replay_gap_count or 0,
        replay_max_gap,
        landing_analysis.max_sample_gap_seconds
    ))
    file:write(string.format(
        "一致性误差 = |%.9f - %.9f| / max(%.9f, 0.20) = %.9f（%.6f%%）\n",
        landing_analysis.impulse_delta_mps,
        landing_analysis.velocity_delta_mps,
        landing_analysis.velocity_delta_mps,
        landing_analysis.consistency_error,
        landing_analysis.consistency_error * 100
    ))
    file:write(string.format(
        "冲量等效G = clamp(1,5, baseline + Δv/(9.80665×压缩时长)) = clamp(1,5, %.9f + %.9f/(9.80665×%.9f)) = %.9f G\n\n",
        landing_analysis.baseline_g,
        landing_analysis.velocity_delta_mps,
        landing_analysis.stop_duration_seconds,
        landing_analysis.equivalent_g
    ))

    local samples_valid = landing_analysis.physical_fpm_valid
        and impact_count >= 3
        and landing_analysis.max_sample_gap_seconds <= MAX_VALID_SAMPLE_GAP_SECONDS
    file:write("可信度与最终G分支复算\n")
    file:write("物理FPM样本有效: " .. math_boolean_text(landing_analysis.physical_fpm_valid) .. "\n")
    file:write(string.format("冲击样本数 >= 3: %s（%d）\n", math_boolean_text(impact_count >= 3), impact_count))
    file:write(string.format(
        "最大样本间隔 <= %.3f s: %s（%.9f s）\n",
        MAX_VALID_SAMPLE_GAP_SECONDS,
        math_boolean_text(landing_analysis.max_sample_gap_seconds <= MAX_VALID_SAMPLE_GAP_SECONDS),
        landing_analysis.max_sample_gap_seconds
    ))
    file:write("样本总体有效: " .. math_boolean_text(samples_valid) .. "\n")
    file:write(string.format(
        "高可信条件: 误差 <= %.2f 且高G持续 >= %.3f s -> %s\n",
        CONSISTENCY_HIGH_MAX_ERROR,
        HIGH_G_DURATION_MIN_SECONDS,
        math_boolean_text(
            samples_valid
            and landing_analysis.consistency_error <= CONSISTENCY_HIGH_MAX_ERROR
            and landing_analysis.high_g_duration_seconds >= HIGH_G_DURATION_MIN_SECONDS
        )
    ))
    file:write(string.format(
        "中可信条件: 误差 <= %.2f 且高G持续 > 0 -> %s\n",
        CONSISTENCY_MEDIUM_MAX_ERROR,
        math_boolean_text(
            samples_valid
            and landing_analysis.consistency_error <= CONSISTENCY_MEDIUM_MAX_ERROR
            and landing_analysis.high_g_duration_seconds > 0
        )
    ))
    file:write("最终采用方式: " .. landing_analysis.method .. "\n")
    local fallback_margin = G_FALLBACK_MARGIN_NICE
    local absolute_landing_fpm = abs_value(landing_fpm)
    if absolute_landing_fpm > FPM_ATTENTION_MAX then
        fallback_margin = G_FALLBACK_MARGIN_UNSTABLE
    elseif absolute_landing_fpm > FPM_STABLE_MAX then
        fallback_margin = G_FALLBACK_MARGIN_ATTENTION
    elseif absolute_landing_fpm > FPM_NICE_MAX then
        fallback_margin = G_FALLBACK_MARGIN_STABLE
    end
    file:write("备用一致性G上限公式: 1 + |FPM|×0.00508/(0.42×9.80665) + 当前等级余量\n")
    file:write(string.format(
        "本次余量 = %.9f；备用一致性G上限 = 1 + %d×0.00508/(0.42×9.80665) + %.9f = %.9f G\n",
        fallback_margin,
        absolute_landing_fpm,
        fallback_margin,
        fallback_g_cap(landing_fpm)
    ))
    file:write(string.format(
        "样本无效: finalG=min(curveG,备用上限)；高可信: finalG=curveG；中可信: finalG=0.65×curveG+0.35×equivalentG；低可信: finalG=0.25×curveG+0.75×equivalentG。\n"
    ))
    file:write(string.format(
        "所有分支最终执行 clamp(1,5,finalG)；最终G高精度值 = %.9f G；界面显示 = %.2f G\n\n",
        landing_g,
        landing_g
    ))

    file:write("评分复算\n")
    file:write(string.format(
        "|FPM|=%d，G=%.9f；Nice上限=%d/%.2f，Stable上限=%d/%.2f，Attention上限=%d/%.2f。\n",
        abs_value(landing_fpm),
        landing_g,
        FPM_NICE_MAX,
        G_NICE_MAX,
        FPM_STABLE_MAX,
        G_STABLE_MAX,
        FPM_ATTENTION_MAX,
        G_ATTENTION_MAX
    ))
    file:write("FPM与G分别分档，最终取较严重等级；基础复算结果: "
        .. status_short(classify_landing(landing_fpm, landing_g, EXTERNAL_SCORE_HINT)) .. "\n")
    file:write("外部评分提示: " .. (EXTERNAL_SCORE_HINT or "无") .. "\n")
    if bounce_state.detected then
        file:write("弹跳修正规则已应用；最终结果: " .. status_short(landing_status) .. "\n")
    else
        file:write("未发生弹跳；最终结果: " .. status_short(landing_status) .. "\n")
    end
    file:write("\n")

    write_second_touch_math_audit(file)
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
    file:write("StarLux 落地率插件 v0.9.0 - 单次落地记录\n")
    file:write("======================================================================\n\n")

    file:write("一、核心落地结果\n")
    file:write("----------------------------------------------------------------------\n")
    file:write("落地时间（本地时间）: " .. landing_timestamp .. "\n")
    file:write("最终评价: " .. status_short(landing_status) .. "\n")
    file:write("评价说明: " .. status_explanation(landing_status) .. "\n")
    file:write("触地垂直速度: " .. vertical_speed_log_text(landing_fpm) .. "\n")
    file:write(string.format("最终过载: %.2f G\n", landing_g))
    if flare_analysis.valid then
        file:write(string.format(
            "拉平曲率: %.1f fpm/s²（|二阶变化|第75百分位，越接近0表示轨迹越平顺）\n",
            flare_analysis.metric
        ))
    else
        file:write("拉平曲率: 无有效结果（" .. flare_analysis.trend_text .. "）\n")
    end
    file:write("拉平轨迹结论: " .. flare_analysis.trend_text .. "\n")
    file:write("弹跳检测: " .. (bounce_state.detected and "发生弹跳" or "未检测到弹跳") .. "\n")
    file:write("机型（ICAO）: " .. landing_context.aircraft_icao .. "\n")
    if landing_context.airport_id == "UNKNOWN" then
        file:write("落地机场: 未能识别\n")
    else
        local airport_name_suffix = ""
        if landing_context.airport_name ~= "" then
            airport_name_suffix = " - " .. landing_context.airport_name
        end
        file:write("落地机场: " .. landing_context.airport_id .. airport_name_suffix .. "\n")
    end
    file:write("触地跑道方向: RWY" .. landing_context.runway .. "（推算）\n")
    file:write(string.format("IAS / GS: %.0f / %.0f kt\n", landing_ias_kts, landing_gs_kts))
    file:write("相对风: " .. landing_wind_relative_text .. "\n")
    file:write("道面提示: " .. (landing_surface.warning_text ~= "" and landing_surface.warning_text or "无") .. "\n\n")

    if bounce_state.detected then
        file:write("弹跳与两次触地\n")
        file:write("----------------------------------------------------------------------\n")
        file:write(string.format(
            "第一次触地: %+d fpm / +%.2f G\n",
            landing_fpm,
            landing_g
        ))
        file:write(string.format(
            "第二次触地: %+d fpm / +%.2f G（触地帧 %.2f G，原始峰值 %.2f G）\n",
            bounce_state.second_fpm,
            bounce_state.second_curve_g,
            bounce_state.second_touch_g,
            bounce_state.second_peak_g
        ))
        file:write(string.format(
            "两次触地间隔: %.2f s\n",
            bounce_state.second_touch_time - bounce_state.first_touch_time
        ))
        file:write(string.format(
            "确认离地时间: %.2f s\n",
            bounce_state.airborne_duration_seconds
        ))
        file:write(string.format(
            "弹跳期间峰值无线电高度: %.2f ft\n",
            bounce_state.airborne_peak_agl_ft
        ))
        file:write(string.format(
            "弹跳期间最大向上速度: %.3f m/s\n",
            bounce_state.airborne_peak_upward_mps
        ))
        file:write("弹跳前评价: " .. status_short(bounce_state.original_status) .. "\n")
        file:write("弹跳后评价: " .. status_short(landing_status) .. "\n")
        file:write("规则: Nice 降为 Stable，Stable 降为 Attention；任一次稳健 G 超过 1.80 时为 UNSTABLE。\n\n")
    end

    file:write("二、100英尺后拉平轨迹\n")
    file:write("----------------------------------------------------------------------\n")
    file:write(string.format("原始采样频率: %.1f Hz\n", 1 / FLARE_CONFIG.sample_interval_seconds))
    file:write("原始样本数: " .. tostring(flare_trace.count) .. "\n")
    file:write("0.5秒聚合点数: " .. tostring(flare_trace.bucket_count) .. "\n")
    file:write("是否达到容量上限: " .. (flare_trace.limited and "是" or "否") .. "\n")
    file:write(string.format("100 ft 至触地时间: %.2f s\n", flare_analysis.duration_seconds))
    file:write(string.format("100 ft 附近下降率: %.0f fpm\n", flare_analysis.entry_fpm))
    file:write(string.format("触地下降率: %d fpm\n", landing_fpm))
    file:write(string.format("下降率净改善量: %+.0f fpm\n", flare_analysis.recovery_fpm))
    file:write(string.format("拉平曲率: %.1f fpm/s²\n", flare_analysis.metric))
    file:write(string.format("有符号平均曲率: %+.1f fpm/s²\n", flare_analysis.signed_mean_curvature))
    file:write("明显方向反转次数: " .. tostring(flare_analysis.reversal_count) .. "\n")
    file:write(string.format("下降率恶化区间比例: %.1f%%\n", flare_analysis.worsening_ratio * 100))
    file:write(string.format("单调改善效率: %.1f%%\n", flare_analysis.monotonic_efficiency * 100))
    file:write(string.format("末段改善占比: %.1f%%\n", flare_analysis.late_recovery_ratio * 100))
    file:write("轨迹结论: " .. flare_analysis.trend_text .. "\n")
    file:write(string.format(
        "明显反转门槛: 相邻聚合FPM变化绝对值超过 %.0f fpm\n",
        FLARE_CONFIG.reversal_noise_fpm
    ))
    file:write(string.format(
        "高震荡规则: 反转次数 >= %d，或反转次数 >= %d 且（单调改善效率 < %.2f 或恶化区间比例 >= %.2f）。\n",
        FLARE_CONFIG.oscillation_severe_reversal_min,
        FLARE_CONFIG.oscillation_high_reversal_min,
        FLARE_CONFIG.oscillation_efficiency_max,
        FLARE_CONFIG.oscillation_worsening_ratio_min
    ))
    file:write("评分说明: v0.9.0 测试阶段的拉平曲率不参与评分。\n")
    file:write(string.format("曲率分析耗时: %.3f ms\n\n", flare_analysis.calculation_ms))

    if landing_analysis.math_log_enabled then
        file:write("0.5秒聚合轨迹表（高精度复算输入）\n")
        file:write("T+秒         RA(ft)       物理FPM       VVI          IAS        GS         Pitch       AoA         Roll\n")
        file:write("----------------------------------------------------------------------------------------------------------\n")
        for i = 1, flare_trace.bucket_count do
            local bucket = flare_trace.buckets[i]
            file:write(string.format(
                "%11.9f  %11.6f  %+13.9f  %+11.6f  %10.6f  %10.6f  %+11.6f  %+10.6f  %+10.6f\n",
                bucket.t - flare_trace.start_time,
                bucket.agl_ft,
                bucket.physical_fpm,
                bucket.vvi_fpm,
                bucket.ias_kts,
                bucket.gs_kts,
                bucket.pitch_deg,
                bucket.aoa_deg,
                bucket.roll_deg
            ))
        end
        file:write("\n拉平曲率逐段复算\n")
        file:write("公式: slope1=(FPM2-FPM1)/dt1；slope2=(FPM3-FPM2)/dt2；curvature=(slope2-slope1)/((dt1+dt2)/2)\n")
        file:write("终点序号  dt1(s)      dt2(s)      slope1        slope2        curvature       |curvature|\n")
        file:write("--------------------------------------------------------------------------------------------\n")
        local old_curve_scratch_count = sort_scratch_count
        sort_scratch_count = 0
        local curve_replay_sum = 0
        local curve_replay_count = 0
        for i = 3, flare_trace.bucket_count do
            local p1 = flare_trace.buckets[i - 2]
            local p2 = flare_trace.buckets[i - 1]
            local p3 = flare_trace.buckets[i]
            local dt1 = p2.t - p1.t
            local dt2 = p3.t - p2.t
            if dt1 > 0.10 and dt2 > 0.10 then
                local slope1 = (p2.physical_fpm - p1.physical_fpm) / dt1
                local slope2 = (p3.physical_fpm - p2.physical_fpm) / dt2
                local curvature = (slope2 - slope1) / ((dt1 + dt2) * 0.5)
                curve_replay_count = curve_replay_count + 1
                curve_replay_sum = curve_replay_sum + curvature
                sort_scratch_count = sort_scratch_count + 1
                sort_scratch[sort_scratch_count] = abs_value(curvature)
                file:write(string.format(
                    "%8d  %.9f  %.9f  %+13.9f  %+13.9f  %+15.9f  %.9f\n",
                    i,
                    dt1,
                    dt2,
                    slope1,
                    slope2,
                    curvature,
                    abs_value(curvature)
                ))
            end
        end
        if sort_scratch_count > 1 then table.sort(sort_scratch) end
        write_sorted_scratch(file, "曲率绝对值(fpm/s²)", 9)
        local curve_percentile_index = curve_replay_count > 0
            and math.max(1, math.ceil(curve_replay_count * FLARE_CONFIG.curvature_percentile)) or 0
        local replay_curve_metric = curve_percentile_index > 0
            and sort_scratch[curve_percentile_index] or 0
        file:write(string.format(
            "P75索引 = ceil(%d × %.2f) = %d；拉平曲率复算 = %.9f fpm/s²；算法保存值 = %.9f fpm/s²\n",
            curve_replay_count,
            FLARE_CONFIG.curvature_percentile,
            curve_percentile_index,
            replay_curve_metric,
            flare_analysis.metric
        ))
        file:write(string.format(
            "有符号平均曲率复算 = %.9f fpm/s²；算法保存值 = %.9f fpm/s²\n\n",
            curve_replay_count > 0 and curve_replay_sum / curve_replay_count or 0,
            flare_analysis.signed_mean_curvature
        ))
        for i = sort_scratch_count + 1, old_curve_scratch_count do
            sort_scratch[i] = nil
        end
    else
        file:write("0.5秒聚合轨迹表\n")
        file:write("T+秒   RA(ft)   物理FPM   VVI   IAS   GS   Pitch   AoA   Roll\n")
        file:write("----------------------------------------------------------------------\n")
        for i = 1, flare_trace.bucket_count do
            local bucket = flare_trace.buckets[i]
            file:write(string.format(
                "%5.1f  %7.1f  %8.0f  %5.0f  %4.0f  %4.0f  %+6.1f  %+5.1f  %+5.1f\n",
                bucket.t - flare_trace.start_time,
                bucket.agl_ft,
                bucket.physical_fpm,
                bucket.vvi_fpm,
                bucket.ias_kts,
                bucket.gs_kts,
                bucket.pitch_deg,
                bucket.aoa_deg,
                bucket.roll_deg
            ))
        end
        file:write("\n")
    end

    file:write("三、飞行、位置与环境参考\n")
    file:write("----------------------------------------------------------------------\n")
    if landing_context.aircraft_file ~= "" then
        file:write("飞机文件: " .. landing_context.aircraft_file .. "\n")
    end
    file:write(string.format("触地点距机场参考点: %.1f km\n", landing_context.airport_distance_km))
    file:write("跑道说明: 根据触地磁航向推算，暂不区分 L/R/C。\n")
    file:write(string.format("真空速（TAS）: %.0f kt\n", landing_tas_kts))
    file:write(string.format("迎角: %.1f deg\n", landing_aoa_deg))
    file:write("横滚角: " .. roll_log_text(landing_roll_deg) .. "\n")
    file:write(string.format("飞机磁航向: %03d deg\n", round_num(normalize_deg(landing_heading_deg))))
    file:write(string.format(
        "风向和风速: 来自 %03d deg，%d kt\n",
        round_num(normalize_deg(landing_wind_heading_deg)),
        round_num(landing_wind_speed_kts)
    ))
    file:write(string.format("触地前三分钟实际降水峰值: %.0f%%\n", landing_surface.precipitation_ratio * 100))
    file:write("连续达到降水阈值的采样数: " .. tostring(landing_surface.consecutive_rain_samples) .. "\n")
    file:write(string.format(
        "跑道摩擦状态: %s（X-Plane 等级 %.0f）\n",
        runway_friction_text(landing_surface.runway_friction),
        landing_surface.runway_friction
    ))
    file:write("道面判定来源: " .. landing_surface.source_text .. "\n\n")

    file:write("四、FPM与G算法诊断\n")
    file:write("----------------------------------------------------------------------\n")
    file:write("同窗 VVI 中位数: " .. vertical_speed_log_text(round_num(landing_analysis.vvi_fpm)) .. "\n")
    file:write("250 ms 物理速度第25百分位: " .. vertical_speed_log_text(round_num(landing_analysis.physical_fpm)) .. "\n")
    file:write("80 ms 物理速度中位数: " .. vertical_speed_log_text(round_num(landing_analysis.physical_short_fpm)) .. "\n")
    file:write("0.85 s 最差 VVI: " .. vertical_speed_log_text(round_num(landing_analysis.vvi_min_fpm)) .. "\n")
    file:write(string.format("物理主值与同窗 VVI 差值: %+d fpm\n", round_num(landing_analysis.fpm_difference)))
    file:write("FPM 物理窗口样本数: " .. tostring(landing_analysis.physical_sample_count) .. "\n")
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
    file:write(string.format("落地分析耗时: %.3f ms\n", landing_analysis.analysis_ms))
    file:write(string.format("最终评分耗时: %.3f ms\n\n", landing_analysis.finalize_ms))

    file:write("五、评分阈值与显示设置\n")
    file:write("----------------------------------------------------------------------\n")
    file:write(string.format("Nice: FPM ≤ %d，G ≤ %.2f\n", FPM_NICE_MAX, G_NICE_MAX))
    file:write(string.format("Stable: FPM ≤ %d，G ≤ %.2f\n", FPM_STABLE_MAX, G_STABLE_MAX))
    file:write(string.format("Attention: FPM ≤ %d，G ≤ %.2f\n", FPM_ATTENTION_MAX, G_ATTENTION_MAX))
    file:write("UNSTABLE: FPM 或 G 超过任意 Attention 上限。\n")
    file:write("FPM 与 G 分别分档，最终评价取较严重等级；拉平曲率暂不参与评分。\n")
    file:write("弹窗时机: " .. (POPUP_MODE == "immediate" and "分析完成后立即显示" or "地速低于 30 kt 时") .. "\n")
    file:write("显示时长: " .. tostring(DISPLAY_SECONDS) .. " 秒\n")
    file:write("屏幕位置: " .. position_log_label(POPUP_POSITION) .. "\n")
    file:write("窗口布局: " .. (POPUP_LAYOUT == "vertical" and "竖向" or "横向") .. "\n")
    file:write("背景透明度档位: " .. tostring(PANEL_OPACITY_LEVEL) .. "%\n")
    file:write(
        "完整数学复算附录: "
        .. (landing_analysis.math_log_enabled and "开启" or "关闭")
        .. "\n\n"
    )

    if landing_analysis.math_log_enabled then
        write_primary_math_audit(file)
    end

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
            -- 新日志直接追加到内存索引，避免每次落地后重新遍历整个文件夹。
            log_tools.register_log_filename(file_name_from_path(result))
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

local function begin_bounce_monitor(now)
    bounce_state.monitoring = true
    bounce_state.detected = false
    bounce_state.phase = "waiting"
    bounce_state.first_touch_time = now
    bounce_state.monitor_until = now + BOUNCE_CONFIG.monitor_seconds
    bounce_state.airborne_start_time = 0
    bounce_state.airborne_duration_seconds = 0
    bounce_state.airborne_peak_agl_ft = 0
    bounce_state.airborne_peak_upward_mps = 0
    bounce_state.second_touch_time = 0
    bounce_state.second_capture_until = 0
    bounce_state.second_fpm = 0
    bounce_state.second_touch_g = 1
    bounce_state.second_peak_g = 1
    bounce_state.second_curve_g = 1
    bounce_state.second_g_ready = false
    bounce_state.score_applied = false
end

local function apply_bounce_score(now)
    if bounce_state.detected == false
        or bounce_state.second_g_ready == false
        or landing_complete == false
        or bounce_state.score_applied == true then
        return
    end

    bounce_state.original_status = landing_status
    if landing_status == "UNSTABLE"
        or landing_g > G_ATTENTION_MAX
        or bounce_state.second_curve_g > G_ATTENTION_MAX then
        landing_status = "UNSTABLE"
    elseif landing_status == "NICE" then
        landing_status = "STABLE"
    elseif landing_status == "STABLE" then
        landing_status = "ATTENTION"
    end
    -- Attention 发生弹跳后仍保持 Attention；只有任一次稳健 G 超过黄色上限才进入红色。

    bounce_state.score_applied = true
    refresh_popup_cache()
    if POPUP_MODE == "immediate" then
        show_until = now + DISPLAY_SECONDS
    end
end

local function finish_second_touch_analysis(now)
    local count = collect_sample_values(
        bounce_state.second_touch_time,
        now,
        "projected_g",
        false
    )
    local curve_g = scratch_percentile(G_CURVE_PERCENTILE)
    if count > 0 and curve_g ~= nil then
        bounce_state.second_curve_g = math.max(1.0, math.min(5.0, curve_g))
    else
        bounce_state.second_curve_g = bounce_state.second_touch_g
    end
    if landing_analysis.math_log_enabled then
        capture_second_touch_math_audit(now)
    end
    bounce_state.second_g_ready = true
    bounce_state.monitoring = false
    bounce_state.phase = "complete"
    apply_bounce_score(now)
    refresh_popup_cache()
end

local function process_bounce_monitor(now, on_ground, radio_alt_ft, local_vy_mps, current_g)
    if bounce_state.phase == "second_capture" then
        local clean_g = sanitize_g(current_g)
        if clean_g ~= nil and clean_g > bounce_state.second_peak_g then
            bounce_state.second_peak_g = clean_g
        end
        if now >= bounce_state.second_capture_until then
            finish_second_touch_analysis(now)
        end
        return
    end

    if bounce_state.monitoring == false then return end
    if now > bounce_state.monitor_until then
        bounce_state.monitoring = false
        bounce_state.phase = "complete"
        return
    end

    if bounce_state.phase == "waiting" then
        if on_ground == 0 and was_on_ground == 1 then
            bounce_state.phase = "airborne"
            bounce_state.airborne_start_time = now
            bounce_state.airborne_peak_agl_ft = math.max(0, radio_alt_ft)
            bounce_state.airborne_peak_upward_mps = math.max(0, local_vy_mps)
        end
    elseif bounce_state.phase == "airborne" then
        if on_ground == 0 then
            bounce_state.airborne_peak_agl_ft = math.max(
                bounce_state.airborne_peak_agl_ft,
                radio_alt_ft
            )
            bounce_state.airborne_peak_upward_mps = math.max(
                bounce_state.airborne_peak_upward_mps,
                local_vy_mps
            )
        elseif on_ground == 1 and was_on_ground == 0 then
            bounce_state.airborne_duration_seconds = math.max(
                0,
                now - bounce_state.airborne_start_time
            )
            local valid_bounce = bounce_state.airborne_duration_seconds
                    >= BOUNCE_CONFIG.min_airborne_seconds
                and (
                    bounce_state.airborne_peak_agl_ft >= BOUNCE_CONFIG.min_peak_agl_ft
                    or bounce_state.airborne_peak_upward_mps >= BOUNCE_CONFIG.min_upward_mps
                )

            if valid_bounce then
                bounce_state.detected = true
                bounce_state.phase = "second_capture"
                bounce_state.second_touch_time = now
                bounce_state.second_capture_until = now + BOUNCE_CONFIG.second_g_capture_seconds

                collect_sample_values(
                    now - PHYSICAL_FPM_WINDOW_SECONDS,
                    now,
                    "local_vy",
                    true
                )
                local second_vy = scratch_percentile(PHYSICAL_FPM_PERCENTILE)
                if second_vy ~= nil then
                    bounce_state.second_fpm = round_num(second_vy * 196.850394)
                else
                    bounce_state.second_fpm = round_num(local_vy_mps * 196.850394)
                end

                local clean_touch_g = sanitize_g(current_g) or 1.0
                bounce_state.second_touch_g = clean_touch_g
                bounce_state.second_peak_g = clean_touch_g
                bounce_state.second_curve_g = clean_touch_g
                refresh_popup_cache()
            else
                -- 极短的离地信号按接地状态抖动处理，继续等待真正弹跳。
                bounce_state.phase = "waiting"
                bounce_state.airborne_start_time = 0
                bounce_state.airborne_peak_agl_ft = 0
                bounce_state.airborne_peak_upward_mps = 0
            end
        end
    end
end

local function finalize_landing_analysis(now)
    local started = os.clock()
    landing_status = classify_landing(landing_fpm, landing_g, EXTERNAL_SCORE_HINT)
    landing_complete = true
    armed = false
    bounce_state.original_status = landing_status

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

    apply_bounce_score(now)
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
    elseif landing_analysis.phase == "analyze_flare" then
        analyze_flare_curve()
        landing_analysis.phase = "finalize"
    elseif landing_analysis.phase == "finalize" then
        finalize_landing_analysis(now)
    end
end

local storage_init_ok, storage_init_error = pcall(function()
    ensure_log_directory()
    load_settings()
    -- 初始化阶段只建立文件名索引，不批量读取报告正文。
    log_tools.refresh_log_index()
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

    settings_window = float_wnd_create(520, 600, 1, true)
    float_wnd_set_title(settings_window, "StarLux Landing Meter - Settings")
    float_wnd_set_imgui_builder(settings_window, "ma_build_settings_window")
    float_wnd_set_onclose(settings_window, "ma_settings_window_closed")

    local screen_w = SCREEN_WIDTH or 1920
    local screen_h = SCREEN_HIGHT or 1080
    float_wnd_set_position(settings_window, math.floor((screen_w - 520) / 2), math.floor((screen_h - 600) / 2))
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

    imgui.Separator()
    imgui.TextUnformatted("TXT report detail")
    local math_changed, new_math_value = imgui.Checkbox(
        "Include full mathematical audit (larger TXT files)",
        DETAILED_MATH_LOG
    )
    if math_changed then
        DETAILED_MATH_LOG = new_math_value
        save_settings()
    end
    imgui.TextUnformatted("Off: concise report. On: complete reproducible calculations.")

    if imgui.Button("Preview popup for 5 seconds", 220, 28) then
        refresh_popup_cache()
        show_until = current_sim_time() + 5
    end
    imgui.SameLine()
    if imgui.Button("Open landing records", 220, 28) then
        ma_open_log_manager()
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

function ma_log_manager_window_closed(wnd)
    log_manager_window = nil
    log_manager_state.pending_delete = ""
end

function ma_open_log_manager()
    if not SUPPORTS_FLOATING_WINDOWS then
        if logMsg then
            logMsg("[StarLux LMM] This FlyWithLua version does not support floating windows.")
        end
        return
    end
    if log_manager_window ~= nil then return end

    log_manager_window = float_wnd_create(760, 650, 1, true)
    float_wnd_set_title(log_manager_window, "StarLux Landing Meter - Landing Records")
    float_wnd_set_imgui_builder(log_manager_window, "ma_build_log_manager_window")
    float_wnd_set_onclose(log_manager_window, "ma_log_manager_window_closed")

    local screen_w = SCREEN_WIDTH or 1920
    local screen_h = SCREEN_HIGHT or 1080
    float_wnd_set_position(
        log_manager_window,
        math.floor((screen_w - 760) / 2),
        math.floor((screen_h - 650) / 2)
    )
end

function ma_build_log_manager_window(wnd, x, y)
    local record_count = #log_manager_state.records
    local page_count = math.max(1, math.ceil(record_count / LOG_MANAGER_PAGE_SIZE))
    if log_manager_state.page > page_count then log_manager_state.page = page_count end

    imgui.TextUnformatted("Landing records")
    imgui.TextUnformatted(
        string.format(
            "%d record(s) indexed. Click a record to open the visual report.",
            record_count
        )
    )
    if imgui.Button("Refresh index", 140, 26) then
        local refresh_ok = log_tools.refresh_log_index()
        log_manager_state.notice = refresh_ok
            and string.format("Index refreshed: %d record(s).", #log_manager_state.records)
            or log_manager_state.scan_error
    end
    imgui.SameLine()
    if imgui.Button("Open LMM_Log folder", 180, 26) then
        local open_ok, open_error = log_tools.open_viewer_in_default_browser(LOG_DIRECTORY_PATH)
        log_manager_state.notice = open_ok and "Opened LMM_Log folder." or tostring(open_error)
    end

    if log_manager_state.scan_error ~= "" then
        imgui.TextUnformatted(log_manager_state.scan_error)
    end
    imgui.Separator()

    if record_count == 0 then
        imgui.TextUnformatted("No landing records found.")
        imgui.TextUnformatted("Complete a landing or copy an LMM_*.txt file into LMM_Log.")
    else
        local first_index = (log_manager_state.page - 1) * LOG_MANAGER_PAGE_SIZE + 1
        local last_index = math.min(record_count, first_index + LOG_MANAGER_PAGE_SIZE - 1)
        for i = first_index, last_index do
            local record = log_manager_state.records[i]
            if imgui.Button(
                record.display_name .. "##lmm_record_" .. tostring(i),
                600,
                30
            ) then
                log_manager_state.viewer_busy = true
                local call_ok, open_ok, result = pcall(log_tools.open_log_visualization, record.name)
                log_manager_state.viewer_busy = false
                if call_ok and open_ok then
                    log_manager_state.notice = "Visual report opened: " .. record.name
                else
                    local error_text = call_ok and result or open_ok
                    log_manager_state.notice = "Unable to open report: " .. tostring(error_text)
                    if logMsg then
                        logMsg("[StarLux LMM] Viewer error: " .. tostring(error_text))
                    end
                end
            end
            imgui.SameLine()
            if imgui.Button("Delete##lmm_delete_" .. tostring(i), 100, 30) then
                log_manager_state.pending_delete = record.name
                log_manager_state.notice = ""
            end
        end
    end

    if log_manager_state.pending_delete ~= "" then
        imgui.Separator()
        imgui.TextUnformatted("Permanently delete this TXT?")
        imgui.TextUnformatted(log_tools.shorten_log_filename(log_manager_state.pending_delete, 84))
        if imgui.Button("Confirm delete", 150, 28) then
            local target_name = log_manager_state.pending_delete
            local call_ok, delete_ok, result = pcall(log_tools.delete_indexed_log, target_name)
            if call_ok and delete_ok then
                log_manager_state.notice = "Deleted: " .. target_name
            else
                local error_text = call_ok and result or delete_ok
                log_manager_state.notice = "Delete failed: " .. tostring(error_text)
                log_manager_state.pending_delete = ""
            end
        end
        imgui.SameLine()
        if imgui.Button("Cancel", 100, 28) then
            log_manager_state.pending_delete = ""
        end
    end

    imgui.Separator()
    if imgui.Button("< Previous", 110, 26) and log_manager_state.page > 1 then
        log_manager_state.page = log_manager_state.page - 1
        log_manager_state.pending_delete = ""
    end
    imgui.SameLine()
    imgui.TextUnformatted(
        string.format("Page %d / %d", log_manager_state.page, page_count)
    )
    imgui.SameLine()
    if imgui.Button("Next >", 110, 26) and log_manager_state.page < page_count then
        log_manager_state.page = log_manager_state.page + 1
        log_manager_state.pending_delete = ""
    end

    if log_manager_state.viewer_busy then
        imgui.TextUnformatted("Generating local visual report...")
    elseif log_manager_state.notice ~= "" then
        imgui.TextUnformatted(log_manager_state.notice)
    end
    imgui.TextUnformatted("Visualizer runs locally. No landing data is uploaded.")
end

add_macro("StarLux Landing Meter | Open Settings", "ma_open_settings_window()")
create_command(
    "starlux/lmm/open_settings",
    "Open StarLux Landing Meter settings",
    "ma_open_settings_window()",
    "",
    ""
)
add_macro("StarLux Landing Meter | Landing Records", "ma_open_log_manager()")
create_command(
    "starlux/lmm/open_landing_records",
    "Open StarLux Landing Meter landing records",
    "ma_open_log_manager()",
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
    if on_ground == 0
        and radio_alt_ft > 20
        and gs_kt > 50
        and bounce_state.monitoring == false then
        if armed == false then
            reset_sample_buffer()
            reset_math_audit()
            reset_surface_watch(now)
            reset_flare_trace()
            reset_bounce_state()
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

    -- 进入 100 英尺后以固定 10 Hz 采集下降率、速度和姿态轨迹。
    update_flare_trace(
        now,
        radio_alt_ft,
        on_ground,
        local_vy_mps,
        vs_fpm,
        ias_kts,
        gs_kt,
        pitch_deg,
        aoa_deg,
        roll_deg
    )

    -- 环形缓冲区在近地进近、第一次压缩及弹跳监测阶段写入。
    if (armed == true and radio_alt_ft <= VS_SAMPLE_MAX_AGL_FT)
        or landing_analysis.phase == "capture"
        or bounce_state.monitoring == true
        or bounce_state.phase == "second_capture" then
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
    if armed == true
        and bounce_state.monitoring == false
        and was_on_ground == 0
        and on_ground == 1
        and gs_kt > 35 then
        landing_complete = false
        landing_timestamp = os.date("%Y-%m-%d %H:%M:%S")

        finish_flare_trace(now)
        begin_bounce_monitor(now)
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
    process_bounce_monitor(now, on_ground, radio_alt_ft, local_vy_mps, current_g)

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
        local show_bounce_warning = bounce_state.detected
        local extra_line_count = 0
        if show_bounce_warning then
            extra_line_count = extra_line_count + 1
        end
        if show_surface_warning then
            extra_line_count = extra_line_count + 1
        end
        if POPUP_LAYOUT == "vertical" then
            panel_w = VERTICAL_PANEL_W
            panel_h = VERTICAL_PANEL_H
        end
        if extra_line_count > 0 then
            panel_h = panel_h
                + extra_line_count * (POPUP_LAYOUT == "vertical" and 27 or 18)
        end

        local x, y = calculate_popup_position(screen_w, screen_h, panel_w, panel_h)
        local r, g, b = status_color(landing_status)

        -- 深色状态底板配合透明度档位；导航查询和文件写入均已移出触地关键阶段。
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
        local line_y1 = y + 126
        local line_gap = 18
        if POPUP_LAYOUT == "vertical" then
            text_x = x + 14
            line_y1 = y + 189
            line_gap = 27
        end
        if extra_line_count > 0 then
            line_y1 = line_y1 + line_gap * extra_line_count
        end

        -- 基础七行文字使用均匀基线；弹跳和湿滑提示依次增加在底部。
        glColor4f(1, 1, 1, 0.98)
        draw_string(text_x, line_y1, popup_cache.lines[1])
        draw_string(text_x, line_y1 - line_gap, popup_cache.lines[2])
        draw_string(text_x, line_y1 - line_gap * 2, popup_cache.lines[3])
        draw_string(text_x, line_y1 - line_gap * 3, popup_cache.lines[4])
        draw_string(text_x, line_y1 - line_gap * 4, popup_cache.lines[5])
        draw_string(text_x, line_y1 - line_gap * 5, popup_cache.lines[6])
        draw_string(text_x, line_y1 - line_gap * 6, popup_cache.lines[7])

        local alert_line_index = 7
        if show_bounce_warning then
            if landing_status == "UNSTABLE" then
                glColor4f(0.92, 0.24, 0.24, 1.0)
            else
                glColor4f(0.92, 0.62, 0.10, 1.0)
            end
            draw_string(
                text_x,
                line_y1 - line_gap * alert_line_index,
                popup_cache.bounce_text
            )
            alert_line_index = alert_line_index + 1
        end
        if show_surface_warning then
            glColor4f(0.78, 0.52, 0.06, 1.0)
            draw_string(
                text_x,
                line_y1 - line_gap * alert_line_index,
                popup_cache.warning_text
            )
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
        "[StarLux LMM] v0.9.0 loaded successfully with %d direct XPLM DataRefs.",
        #LMM_DATAREF_SPECS
    ))
end

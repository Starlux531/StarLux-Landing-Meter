-- StarLux 落地率插件 v1.1.4 稳定测试版
-- 适用于 X-Plane 12 + FlyWithLua
-- v1.1.4 重建接地数据主链：FPM 以 AGL 几何下降率为锚点选择最接近的有效测量，G 以 1.0 G 为冲量基准。

-- =========================
-- 用户设置
-- =========================

local POPUP_MODE = "immediate"
-- "immediate" = 落地分析完成后立即显示
-- "taxi"      = 地速降低到 30 节以下时显示
-- "stopped"   = 飞机停稳并持续 10 秒后显示
-- "off"       = 不自动显示落地数据窗，但保留报告生成提示
-- "clean"     = 纯净模式：关闭落地数据窗和报告生成提示

-- 文档输出语言保存在 runtime_state 中，避免增加 Lua 5.1 主代码块局部变量。

local DISPLAY_SECONDS = 30
local DETAILED_MATH_LOG = false
-- false = 输出 v0.8.0 风格的简洁专业报告；true = 追加可完整复算的数学审计内容。
-- 某些长行程起落架在 0.35 秒时仍未完成第一次压缩，因此把安全上限延长到 1.20 秒。
-- 满足停止或反弹条件时仍会提前结束；若到达上限，报告会明确记录超时原因。
local IMPACT_CAPTURE_MAX_SECONDS = 1.20
local PRE_TOUCH_BUFFER_SECONDS = 0.50
-- 物理候选优先取最后 100 ms 离地垂直速度中位数；250 ms P25 只在短窗缺样时备用。
local PHYSICAL_FPM_WINDOW_SECONDS = 0.25
local PHYSICAL_FPM_CONTACT_WINDOW_SECONDS = 0.10
local PHYSICAL_FPM_PERCENTILE = 0.25
local VVI_DIAGNOSTIC_WINDOW_SECONDS = 0.85
local G_BASELINE_WINDOW_SECONDS = 0.20
local IMPACT_STOP_VY_MPS = -0.05
local IMPACT_STOP_STABLE_FRAMES = 3
local TAXI_POPUP_SPEED_KT = 30

-- AGL 几何斜率作为跨机模锚点：物理 FPM 与 VVI 谁更接近 AGL 就采用谁；两者均明显偏离时直接采用 AGL。
-- AGL 样本不可用时，才依次回退到物理候选和 VVI。

-- 拉平曲率首版只显示和记录，不参与落地评分。
-- 10 Hz 原始采样在分析阶段聚合为 0.25 秒轨迹点，在保留细节的同时抑制瞬时噪声。
local FLARE_CONFIG = {
    start_agl_ft = 100,
    -- 先在目标高度以上保留一小段原始样本。触地后才能知道飞机参考点相对跑道面的静态高度，
    -- 因此必须预留足够高度，再完成接地点归零并裁切出真正的 100 ft 后轨迹。
    capture_margin_ft = 40,
    max_touch_reference_ft = 60,
    sample_interval_seconds = 0.10,
    max_samples = 600,
    -- 0.25 秒显示桶在保留 10 Hz 原始输入的同时提高网页轨迹分辨率；扩容后仍覆盖最长 60 秒原始缓存。
    bucket_seconds = 0.25,
    max_buckets = 256,
    min_samples = 12,
    min_buckets = 4,
    -- 只有持续下降才允许启动；复飞、重新爬升或异常超时会作废本轮轨迹。
    start_descent_fpm = -50,
    start_confirm_seconds = 0.20,
    cancel_climb_fpm = 100,
    cancel_climb_seconds = 1.00,
    cancel_agl_ft = 150,
    max_trace_seconds = 120,
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
local REPORT_READER_TEMPLATE_PATH = join_path(LMM_BASE_DIRECTORY, "LMM_Report_Reader.html")
local LOG_VIEWER_FILE_PATH = join_path(LOG_DIRECTORY_PATH, "LMM_Viewer.html")
local LOG_VIEWER_DATA_FILE_PATH = join_path(LOG_DIRECTORY_PATH, "LMM_Viewer_Data.js")
local LOG_INDEX_TEMP_FILE_PATH = join_path(LOG_DIRECTORY_PATH, ".lmm_index.tmp")
local LOG_MANAGER_PAGE_SIZE = 8

local VS_SAMPLE_MAX_AGL_FT = 120

-- G 稳健主值与物理闭合复核参数。
local SAMPLE_BUFFER_SIZE = 256
local MATH_AUDIT_SAMPLE_MAX = SAMPLE_BUFFER_SIZE
local SECOND_TOUCH_AUDIT_SAMPLE_MAX = SAMPLE_BUFFER_SIZE
local G_CURVE_PERCENTILE = 0.75
-- 固定接地窗取 P75，既保留最初承载阶段，也避免单帧尖峰直接成为最终 G。
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
    { key = "local_vx_mps", path = "sim/flightmodel/position/local_vx", kind = "float" },
    { key = "local_vz_mps", path = "sim/flightmodel/position/local_vz", kind = "float" },
    { key = "y_agl_m", path = "sim/flightmodel/position/y_agl", kind = "float" },
    { key = "elevation_m", path = "sim/flightmodel/position/elevation", kind = "double" },
    { key = "on_ground", path = "sim/flightmodel/failures/onground_any", kind = "int" },
    { key = "g_normal", path = "sim/flightmodel/forces/g_nrml", kind = "float" },
    { key = "roll_deg", path = "sim/flightmodel/position/phi", kind = "float" },
    { key = "pitch_deg", path = "sim/flightmodel/position/theta", kind = "float" },
    { key = "groundspeed_mps", path = "sim/flightmodel/position/groundspeed", kind = "float" },
    { key = "running_time_sec", path = "sim/time/total_running_time_sec", kind = "float" },
    { key = "is_in_replay", path = "sim/time/is_in_replay", kind = "int" },
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
        agl_m = 0,
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
        agl_m = 0,
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
        agl_m = 0,
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
    touch_reference_ft = 0,
    next_sample_time = 0,
    descent_confirm_start = 0,
    climb_confirm_start = 0,
    height_reference = "TERRAIN_AGL",
    reference_elevation_ft = 0,
    count = 0,
    analysis_sample_count = 0,
    bucket_count = 0
}
for i = 1, FLARE_CONFIG.max_samples do
    flare_trace.slots[i] = {
        t = 0,
        agl_ft = 0,
        physical_fpm = 0,
        vvi_fpm = 0,
        selected_fpm = 0,
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
        selected_fpm = 0,
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
    result_status = "NICE",
    score_applied = false
}

local landing_analysis = {
    fpm_validation = {
        agl_window_seconds = PHYSICAL_FPM_WINDOW_SECONDS,
        agl_end_guard_seconds = 0.04,
        agl_min_span_seconds = 0.16,
        agl_min_samples = 4,
        agl_min_pair_gap_seconds = 0.035,
        agl_max_samples = 64,
        terminal_agl_ft = 5.0,
        agl_anchor_max_difference_fpm = 30
    },
    g_local_event = {
        window_seconds = 0.160,
        min_span_seconds = 0.040,
        min_samples = 5,
        percentile = 0.75
    },
    phase = "idle",
    touch_time = 0,
    impact_start_time = 0,
    impact_end_time = 0,
    end_time = 0,
    capture_deadline = 0,
    stop_stable_frames = 0,
    stop_candidate_time = 0,
    capture_end_reason = "等待采集",
    vvi_fpm = 0,
    vvi_min_fpm = 0,
    vvi_fpm_valid = false,
    vvi_sample_count = 0,
    physical_fpm = 0,
    physical_short_fpm = 0,
    physical_fallback_fpm = 0,
    fpm_difference = 0,
    physical_fpm_valid = false,
    physical_sample_count = 0,
    agl_fpm = 0,
    agl_fit_times = {},
    agl_fit_values = {},
    agl_fpm_valid = false,
    agl_sample_count = 0,
    agl_pair_count = 0,
    agl_sample_span_seconds = 0,
    agl_physical_difference = 0,
    agl_vvi_difference = 0,
    fpm_max_pair_difference = 0,
    fpm_selection_reason = "",
    fpm_method = "等待终端下降率测量",
    flare_fpm_source = "VVI",
    pre_vy_mps = 0,
    post_vy_mps = 0,
    velocity_delta_mps = 0,
    baseline_g = 1,
    curve_g = 1,
    local_event_g = 1,
    local_event_g_valid = false,
    local_event_window_start_time = 0,
    local_event_window_end_time = 0,
    local_event_window_span_seconds = 0,
    local_event_sample_count = 0,
    local_event_percentile_index = 0,
    robust_event_g = 1,
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
    airport_internal_id = "",
    airport_name = "",
    airport_distance_km = 0,
    runway = "--",
    runway_detected = false,
    runway_status = "pending",
    runway_confidence = "NONE",
    runway_source = "",
    runway_source_path = "",
    runway_length_m = 0,
    runway_width_m = 0,
    runway_surface = "",
    runway_surface_code = 0,
    runway_shoulder_code = 0,
    runway_centerline_lights = 0,
    runway_edge_lights = 0,
    opposite_runway = "",
    displaced_threshold_m = 0,
    opposite_displaced_threshold_m = 0,
    blast_pad_m = 0,
    opposite_blast_pad_m = 0,
    marking_code = 0,
    opposite_marking_code = 0,
    tdz_lights = 0,
    opposite_tdz_lights = 0,
    reil_code = 0,
    opposite_reil_code = 0,
    touchdown_from_threshold_m = 0,
    runway_remaining_m = 0,
    centerline_offset_m = 0,
    centerline_signed_m = 0,
    centerline_side = "CENTER",
    centerline_penalty_applied = false,
    centerline_penalty_level = "none",
    centerline_original_status = "NICE",
    centerline_warning_text = "",
    touch_latitude = 0,
    touch_longitude = 0,
    touch_vx_mps = 0,
    touch_vz_mps = 0,
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
local runtime_state = {
    deferred_popup_done = false,
    stopped_popup_since = 0,
    stopped_speed_kt = 1.0,
    stopped_hold_seconds = 10.0,
    replay_active = false,
    document_language = "zh",
    runway_detection_enabled = true
}
local settings_window = nil
local log_manager_window = nil
-- 新增文件管理函数统一放入表中，避免 Lua 5.1 主代码块超过 200 个局部变量上限。
local log_tools = {}
log_tools.runway_config = {
    scan_chunk_bytes = 131072,
    timeout_seconds = 30.0,
    prefetch_timeout_seconds = 300.0,
    prefetch_check_interval_seconds = 5.0,
    prefetch_min_agl_ft = 100.0,
    prefetch_max_agl_ft = 5000.0,
    prefetch_max_distance_km = 40.0,
    nearby_probe_radius_km = 5.0,
    nearby_candidate_max_distance_km = 15.0,
    nearby_prefetch_queue_limit = 12,
    nearby_probe_move_km = 2.0,
    nearby_probe_interval_seconds = 30.0,
    cross_tolerance_m = 45.0,
    along_tolerance_m = 150.0,
    centerline_downgrade_m = 7.0,
    centerline_unstable_m = 15.0,
    earth_radius_m = 6371000.0
}
log_tools.runway_state = {
    sources = {},
    active = false,
    file = nil,
    source_index = 0,
    source = nil,
    partial = "",
    collecting = false,
    collecting_airport = "",
    target_airport = "",
    runways = {},
    metadata = {},
    started_at = 0,
    mode = "idle",
    cache = {},
    airport_nav = {},
    prefetch_queue = {},
    prefetch_queued = {},
    last_nearby_probe_lat = nil,
    last_nearby_probe_lon = nil,
    last_nearby_probe_at = -1000,
    last_prefetch_check = -1000,
    last_mode = "idle",
    last_status = "idle",
    last_reason = ""
}
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
    log_after = 0,
    runway_deadline = 0
}
local landing_report_notice = {
    text = "",
    file_name = "",
    until_time = 0
}
local popup_cache = {
    lines = { "", "", "", "", "", "", "" },
    warning_text = "",
    bounce_text = "",
    centerline_text = ""
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

-- 落地弹窗和报告提示按照所选数据输出语言显示。
function log_tools.ui_text(chinese, english)
    if runtime_state.document_language == "en" then return english end
    return chinese
end

-- FlyWithLua ImGui 设置窗口和记录管理器固定使用英文，避免中文字体缺失造成方框或空白。
function log_tools.settings_text(chinese, english)
    return english
end

local function sanitize_filename_token(value)
    local token = string.upper(trim_text(value)):gsub("[^%w%-]", "")
    if token == "" or token == "UNKNOWN" then
        return "UNKNOWN"
    end
    return token
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
    -- 进近阶段已启动的 apt.dat 预扫描必须跨越触地保留，避免从文件头重新开始。
    if log_tools.cancel_runway_resolver
        and log_tools.runway_state.active
        and log_tools.runway_state.mode ~= "prefetch" then
        log_tools.cancel_runway_resolver("new landing")
    end
    landing_context.airport_id = "识别中"
    landing_context.airport_internal_id = ""
    landing_context.airport_name = ""
    landing_context.airport_distance_km = 0
    landing_context.runway = "--"
    landing_context.runway_detected = false
    landing_context.runway_status = runtime_state.runway_detection_enabled and "pending" or "disabled"
    landing_context.runway_confidence = "NONE"
    landing_context.runway_source = ""
    landing_context.runway_source_path = ""
    landing_context.runway_length_m = 0
    landing_context.runway_width_m = 0
    landing_context.runway_surface = ""
    landing_context.runway_surface_code = 0
    landing_context.runway_shoulder_code = 0
    landing_context.runway_centerline_lights = 0
    landing_context.runway_edge_lights = 0
    landing_context.opposite_runway = ""
    landing_context.displaced_threshold_m = 0
    landing_context.opposite_displaced_threshold_m = 0
    landing_context.blast_pad_m = 0
    landing_context.opposite_blast_pad_m = 0
    landing_context.marking_code = 0
    landing_context.opposite_marking_code = 0
    landing_context.tdz_lights = 0
    landing_context.opposite_tdz_lights = 0
    landing_context.reil_code = 0
    landing_context.opposite_reil_code = 0
    landing_context.touchdown_from_threshold_m = 0
    landing_context.runway_remaining_m = 0
    landing_context.centerline_offset_m = 0
    landing_context.centerline_signed_m = 0
    landing_context.centerline_side = "CENTER"
    landing_context.centerline_penalty_applied = false
    landing_context.centerline_penalty_level = "none"
    landing_context.centerline_original_status = "NICE"
    landing_context.centerline_warning_text = ""
    landing_context.touch_latitude = lmm_get_double("latitude_deg")
    landing_context.touch_longitude = lmm_get_double("longitude_deg")
    landing_context.touch_vx_mps = lmm_get_float("local_vx_mps")
    landing_context.touch_vz_mps = lmm_get_float("local_vz_mps")
    landing_context.file_timestamp = os.date("%Y-%m-%d_%H-%M-%S")
    landing_report_notice.text = ""
    landing_report_notice.file_name = ""
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
        return log_tools.ui_text("积雪/结冰", "snow/ice")
    elseif value >= 10 then
        return log_tools.ui_text("结冰", "ice")
    elseif value >= 7 then
        return log_tools.ui_text("积雪", "snow")
    elseif value >= 4 then
        return log_tools.ui_text("积水", "standing water")
    elseif value >= 1 then
        return log_tools.ui_text("湿滑", "wet")
    end
    return log_tools.ui_text("干燥", "dry")
end

function log_tools.normalize_xplane_path(path)
    local normalized = trim_text(path)
    normalized = normalized:gsub("/", PATH_SEPARATOR)
    normalized = normalized:gsub("\\", PATH_SEPARATOR)
    return normalized
end

function log_tools.add_apt_source(path, label)
    local state = log_tools.runway_state
    local normalized = log_tools.normalize_xplane_path(path)
    for i = 1, #state.sources do
        if state.sources[i].path == normalized then return false end
    end
    local probe = io.open(normalized, "rb")
    if probe == nil then return false end
    probe:close()
    state.sources[#state.sources + 1] = { path = normalized, label = trim_text(label) }
    return true
end

function log_tools.discover_apt_sources()
    local state = log_tools.runway_state
    state.sources = {}
    state.cache = {}
    state.airport_nav = {}
    state.prefetch_queue = {}
    state.prefetch_queued = {}
    state.last_nearby_probe_lat = nil
    state.last_nearby_probe_lon = nil
    state.last_nearby_probe_at = -1000
    local root = trim_text(SYSTEM_DIRECTORY or "")
    if root == "" then
        state.last_reason = "X-Plane 根目录不可用"
        return 0
    end

    local global_path = join_path(join_path(join_path(root, "Global Scenery"), "Global Airports"), join_path("Earth nav data", "apt.dat"))
    local packs_path = join_path(join_path(root, "Custom Scenery"), "scenery_packs.ini")
    local packs = io.open(packs_path, "r")
    local global_added = false
    if packs ~= nil then
        for line in packs:lines() do
            if not line:match("^%s*SCENERY_PACK_DISABLED%s+") then
                local entry = line:match("^%s*SCENERY_PACK%s+(.+)%s*$")
                if entry ~= nil then
                    entry = trim_text(entry):gsub('^"(.*)"$', "%1")
                    if entry == "*GLOBAL_AIRPORTS*" then
                        global_added = log_tools.add_apt_source(global_path, "Global Airports") or global_added
                    else
                        local base_path
                        if entry:match("^%a:[/\\]") or entry:sub(1, 1) == "/" then
                            base_path = log_tools.normalize_xplane_path(entry)
                        else
                            base_path = join_path(root, log_tools.normalize_xplane_path(entry))
                        end
                        local apt_path = join_path(join_path(base_path, "Earth nav data"), "apt.dat")
                        log_tools.add_apt_source(apt_path, entry:gsub("[/\\]+$", ""))
                    end
                end
            end
        end
        packs:close()
    end
    if not global_added then
        log_tools.add_apt_source(global_path, "Global Airports")
    end
    state.last_reason = #state.sources > 0 and "" or "未找到可读取的 apt.dat"
    return #state.sources
end

function log_tools.cancel_runway_resolver(reason)
    local state = log_tools.runway_state
    if state.file ~= nil then pcall(function() state.file:close() end) end
    state.file = nil
    state.active = false
    state.source = nil
    state.partial = ""
    state.collecting = false
    state.collecting_airport = ""
    state.runways = {}
    state.metadata = {}
    state.mode = "idle"
    if reason ~= nil then state.last_reason = tostring(reason) end
end

function log_tools.finish_runway_resolver(status, reason)
    local state = log_tools.runway_state
    local finished_mode = state.mode
    if state.file ~= nil then pcall(function() state.file:close() end) end
    state.file = nil
    state.active = false
    state.source = nil
    state.partial = ""
    state.collecting = false
    state.collecting_airport = ""
    state.mode = "idle"
    state.last_mode = finished_mode
    state.last_status = tostring(status or "unavailable")
    state.last_reason = tostring(reason or "")
    -- 预扫描只缓存机场跑道数据；触地前不得改写上一份落地结果或当前弹窗。
    if finished_mode ~= "prefetch" and landing_context.runway_detected == false then
        landing_context.runway_status = status or "unavailable"
        landing_context.runway = "--"
        landing_context.runway_confidence = "NONE"
    end
end

function log_tools.runway_surface_text(code)
    if code == 1 or (code >= 20 and code <= 38) then return "沥青" end
    if code == 2 or (code >= 50 and code <= 57) then return "混凝土" end
    if code == 3 then return "草地" end
    if code == 4 then return "泥土" end
    if code == 5 then return "碎石" end
    if code == 12 then return "干湖床" end
    if code == 14 then return "冰雪" end
    if code == 15 then return "透明道面" end
    return "未知（代码 " .. tostring(code) .. "）"
end

function log_tools.runway_marking_text(code)
    local labels = {
        [0] = "无跑道标线",
        [1] = "目视跑道标线",
        [2] = "FAA 非精密进近跑道标线",
        [3] = "FAA 精密进近跑道标线",
        [4] = "英国非精密进近跑道标线",
        [5] = "英国精密进近跑道标线",
        [6] = "EASA/ICAO 非精密进近跑道标线",
        [7] = "EASA/ICAO 精密进近跑道标线"
    }
    return labels[tonumber(code) or 0] or ("未知跑道标线（代码 " .. tostring(code) .. "）")
end

function log_tools.runway_yes_no(value)
    if tonumber(value) ~= nil and tonumber(value) ~= 0 then return log_tools.ui_text("是", "Yes") end
    return log_tools.ui_text("否", "No")
end

function log_tools.apt_tokens(line)
    local values = {}
    for token in tostring(line or ""):gmatch("%S+") do
        values[#values + 1] = token
    end
    return values
end

function log_tools.parse_runway_row(line)
    local fields = log_tools.apt_tokens(line)
    if #fields < 20 or fields[1] ~= "100" then return nil end
    -- apt.dat fields 15 and 24 are approach-light codes. They are intentionally
    -- not read because neither runway matching nor the report reader uses them.
    local width = tonumber(fields[2])
    local surface = tonumber(fields[3])
    local lat1, lon1 = tonumber(fields[10]), tonumber(fields[11])
    local lat2, lon2 = tonumber(fields[19]), tonumber(fields[20])
    if width == nil or surface == nil or lat1 == nil or lon1 == nil or lat2 == nil or lon2 == nil then return nil end
    return {
        width_m = width,
        surface_code = surface,
        shoulder_code = tonumber(fields[4]) or 0,
        centerline_lights = tonumber(fields[6]) or 0,
        edge_lights = tonumber(fields[7]) or 0,
        end1 = string.upper(fields[9] or ""),
        lat1 = lat1,
        lon1 = lon1,
        displaced1_m = tonumber(fields[12]) or 0,
        blast1_m = tonumber(fields[13]) or 0,
        marking1_code = tonumber(fields[14]) or 0,
        tdz1_lights = tonumber(fields[16]) or 0,
        reil1_code = tonumber(fields[17]) or 0,
        end2 = string.upper(fields[18] or ""),
        lat2 = lat2,
        lon2 = lon2,
        displaced2_m = tonumber(fields[21]) or 0,
        blast2_m = tonumber(fields[22]) or 0,
        marking2_code = tonumber(fields[23]) or 0,
        tdz2_lights = tonumber(fields[25]) or 0,
        reil2_code = tonumber(fields[26]) or 0
    }
end

function log_tools.select_touchdown_runway(runways)
    local state = log_tools.runway_state
    local runway_list = runways or state.runways
    local origin_lat = landing_context.touch_latitude
    local origin_lon = landing_context.touch_longitude
    local radians = math.pi / 180
    local cos_lat = math.cos(origin_lat * radians)
    local radius = log_tools.runway_config.earth_radius_m
    local vx = landing_context.touch_vx_mps
    local vn = -landing_context.touch_vz_mps
    local velocity_length = math.sqrt(vx * vx + vn * vn)
    if velocity_length < 2 then
        return nil, nil, "触地地速向量不可用"
    end
    vx = vx / velocity_length
    vn = vn / velocity_length

    local candidates = {}
    for i = 1, #runway_list do
        local runway = runway_list[i]
        local ax = (runway.lon1 - origin_lon) * radians * radius * cos_lat
        local an = (runway.lat1 - origin_lat) * radians * radius
        local bx = (runway.lon2 - origin_lon) * radians * radius * cos_lat
        local bn = (runway.lat2 - origin_lat) * radians * radius
        local dx, dn = bx - ax, bn - an
        local length = math.sqrt(dx * dx + dn * dn)
        if length >= 100 and runway.width_m > 0 then
            local ux, un = dx / length, dn / length
            local px, pn = -ax, -an
            local along = px * ux + pn * un
            local signed_cross = ux * pn - un * px
            local cross = math.abs(signed_cross)
            local out_of_bounds = 0
            if along < 0 then
                out_of_bounds = -along
            elseif along > length then
                out_of_bounds = along - length
            end
            local alignment_dot = vx * ux + vn * un
            local alignment = math.abs(alignment_dot)
            if cross <= runway.width_m / 2 + log_tools.runway_config.cross_tolerance_m
                and along >= -log_tools.runway_config.along_tolerance_m
                and along <= length + log_tools.runway_config.along_tolerance_m
                and alignment >= 0.35 then
                local forward = alignment_dot >= 0
                local threshold_distance
                local remaining
                local runway_id
                local opposite_runway_id
                local displaced_threshold_m
                local opposite_displaced_threshold_m
                local blast_pad_m
                local opposite_blast_pad_m
                local marking_code
                local opposite_marking_code
                local tdz_lights
                local opposite_tdz_lights
                local reil_code
                local opposite_reil_code
                local centerline_signed_m
                if forward then
                    runway_id = runway.end1
                    opposite_runway_id = runway.end2
                    displaced_threshold_m = runway.displaced1_m
                    opposite_displaced_threshold_m = runway.displaced2_m
                    blast_pad_m = runway.blast1_m
                    opposite_blast_pad_m = runway.blast2_m
                    marking_code = runway.marking1_code
                    opposite_marking_code = runway.marking2_code
                    tdz_lights = runway.tdz1_lights
                    opposite_tdz_lights = runway.tdz2_lights
                    reil_code = runway.reil1_code
                    opposite_reil_code = runway.reil2_code
                    threshold_distance = along - runway.displaced1_m
                    remaining = length - along
                    centerline_signed_m = signed_cross
                else
                    runway_id = runway.end2
                    opposite_runway_id = runway.end1
                    displaced_threshold_m = runway.displaced2_m
                    opposite_displaced_threshold_m = runway.displaced1_m
                    blast_pad_m = runway.blast2_m
                    opposite_blast_pad_m = runway.blast1_m
                    marking_code = runway.marking2_code
                    opposite_marking_code = runway.marking1_code
                    tdz_lights = runway.tdz2_lights
                    opposite_tdz_lights = runway.tdz1_lights
                    reil_code = runway.reil2_code
                    opposite_reil_code = runway.reil1_code
                    threshold_distance = (length - along) - runway.displaced2_m
                    remaining = along
                    centerline_signed_m = -signed_cross
                end
                candidates[#candidates + 1] = {
                    score = cross + out_of_bounds * 4 + (1 - alignment) * 220,
                    runway_id = runway_id,
                    opposite_runway_id = opposite_runway_id,
                    length_m = length,
                    width_m = runway.width_m,
                    surface_code = runway.surface_code,
                    shoulder_code = runway.shoulder_code,
                    centerline_lights = runway.centerline_lights,
                    edge_lights = runway.edge_lights,
                    displaced_threshold_m = displaced_threshold_m,
                    opposite_displaced_threshold_m = opposite_displaced_threshold_m,
                    blast_pad_m = blast_pad_m,
                    opposite_blast_pad_m = opposite_blast_pad_m,
                    marking_code = marking_code,
                    opposite_marking_code = opposite_marking_code,
                    tdz_lights = tdz_lights,
                    opposite_tdz_lights = opposite_tdz_lights,
                    reil_code = reil_code,
                    opposite_reil_code = opposite_reil_code,
                    threshold_distance_m = threshold_distance,
                    remaining_m = remaining,
                    centerline_offset_m = cross,
                    centerline_signed_m = centerline_signed_m,
                    alignment = alignment,
                    runway_center_distance_km = math.sqrt(
                        ((ax + bx) * 0.5) * ((ax + bx) * 0.5)
                        + ((an + bn) * 0.5) * ((an + bn) * 0.5)
                    ) / 1000,
                    inside = along >= 0 and along <= length
                }
            end
        end
    end

    table.sort(candidates, function(a, b) return a.score < b.score end)
    local best = candidates[1]
    if best == nil or best.runway_id == "" then
        return nil, nil, "触地点未落入任何跑道几何包络"
    end
    local second = candidates[2]
    if second ~= nil and second.runway_id ~= best.runway_id and second.score - best.score < 25 then
        return nil, nil, "多条跑道候选过于接近，拒绝猜测"
    end
    local confidence = "MEDIUM"
    if best.inside and best.centerline_offset_m <= best.width_m / 2 + 8 and best.alignment >= 0.75 then
        confidence = "HIGH"
    end
    return best, confidence
end

function log_tools.select_cached_touchdown_runway(excluded_airport)
    local state = log_tools.runway_state
    local excluded = string.upper(trim_text(excluded_airport))
    local matches = {}
    for airport_id, cached in pairs(state.cache) do
        if airport_id ~= excluded and cached ~= nil and #(cached.runways or {}) > 0 then
            local best, confidence = log_tools.select_touchdown_runway(cached.runways)
            if best ~= nil then
                matches[#matches + 1] = {
                    airport_id = airport_id,
                    cached = cached,
                    best = best,
                    confidence = confidence
                }
            end
        end
    end
    table.sort(matches, function(a, b) return a.best.score < b.best.score end)
    local selected = matches[1]
    if selected == nil then
        return nil
    end
    local second = matches[2]
    if second ~= nil and second.best.score - selected.best.score < 25 then
        return nil
    end
    return selected.best, selected.confidence, selected.cached, selected.airport_id
end

function log_tools.apply_centerline_score()
    if landing_context.runway_detected == false or landing_context.centerline_penalty_applied then return end
    local offset = landing_context.centerline_offset_m or 0
    local downgrade_limit = log_tools.runway_config.centerline_downgrade_m
    local unstable_limit = log_tools.runway_config.centerline_unstable_m
    if offset <= downgrade_limit then return end

    landing_context.centerline_penalty_applied = true
    landing_context.centerline_original_status = landing_status
    landing_context.centerline_warning_text = string.format("偏离中心线 %.1f 米", offset)
    if offset > unstable_limit then
        landing_context.centerline_penalty_level = "unstable"
        landing_status = "UNSTABLE"
    else
        landing_context.centerline_penalty_level = "downgrade"
        if landing_status == "NICE" then
            landing_status = "STABLE"
        elseif landing_status == "STABLE" then
            landing_status = "ATTENTION"
        end
        -- Attention 保持黄色，避免 7–15 米区间被中心线规则直接推入红色。
    end
    if POPUP_MODE == "immediate" and landing_complete then
        local popup_now = lmm_get_float("running_time_sec")
        if popup_now <= 0 then popup_now = os.clock() end
        show_until = math.max(show_until, popup_now + DISPLAY_SECONDS)
    end
end

function log_tools.finish_airport_block()
    local state = log_tools.runway_state
    local cache_key = string.upper(trim_text(
        state.collecting_airport ~= "" and state.collecting_airport or state.target_airport
    ))
    if cache_key ~= "" then
        state.cache[cache_key] = {
            runways = state.runways,
            metadata = state.metadata,
            source = state.source
        }
        state.prefetch_queued[cache_key] = nil
    end

    -- 同一次顺序扫描可以顺手缓存沿途遇到的相邻机场，但不能把它当作当前主目标结束扫描。
    if cache_key ~= string.upper(trim_text(state.target_airport)) then
        state.collecting = false
        state.collecting_airport = ""
        state.runways = {}
        state.metadata = {}
        return false
    end

    -- 进近阶段只完成读取和缓存；触地点几何必须使用真正接地时保存的坐标与速度向量。
    if state.mode == "prefetch" then
        log_tools.finish_runway_resolver("prefetched", "")
        return true
    end

    local best, confidence, reason = log_tools.select_touchdown_runway()
    if best == nil then
        local fallback_best, fallback_confidence, fallback_cache, fallback_airport =
            log_tools.select_cached_touchdown_runway(cache_key)
        if fallback_best == nil then
            -- 候选复核保持静默；失败时继续沿用原有主机场失败原因，不增加报告/UI 提示。
            log_tools.finish_runway_resolver("unavailable", reason)
            return false
        end
        best = fallback_best
        confidence = fallback_confidence
        cache_key = fallback_airport
        state.target_airport = fallback_airport
        state.runways = fallback_cache.runways or {}
        state.metadata = fallback_cache.metadata or {}
        state.source = fallback_cache.source
    end

    local icao = string.upper(trim_text(
        state.metadata.icao_code or state.metadata.icao_id or cache_key
    ))
    if icao ~= "" then landing_context.airport_id = icao end
    landing_context.airport_internal_id = cache_key
    if trim_text(state.metadata.airport_name or "") ~= "" then
        landing_context.airport_name = trim_text(state.metadata.airport_name)
    end
    local nav_info = state.airport_nav[cache_key]
    if nav_info ~= nil then
        landing_context.airport_distance_km = distance_km(
            landing_context.touch_latitude,
            landing_context.touch_longitude,
            nav_info.latitude,
            nav_info.longitude
        )
        if trim_text(nav_info.name or "") ~= "" then landing_context.airport_name = nav_info.name end
    elseif best.runway_center_distance_km ~= nil then
        landing_context.airport_distance_km = best.runway_center_distance_km
    end

    landing_context.runway = best.runway_id
    landing_context.runway_detected = true
    landing_context.runway_status = "resolved"
    landing_context.runway_confidence = confidence
    landing_context.runway_source = state.source and state.source.label or "apt.dat"
    landing_context.runway_source_path = state.source and state.source.path or ""
    landing_context.runway_length_m = best.length_m
    landing_context.runway_width_m = best.width_m
    landing_context.runway_surface = log_tools.runway_surface_text(best.surface_code)
    landing_context.runway_surface_code = best.surface_code
    landing_context.runway_shoulder_code = best.shoulder_code
    landing_context.runway_centerline_lights = best.centerline_lights
    landing_context.runway_edge_lights = best.edge_lights
    landing_context.opposite_runway = best.opposite_runway_id
    landing_context.displaced_threshold_m = best.displaced_threshold_m
    landing_context.opposite_displaced_threshold_m = best.opposite_displaced_threshold_m
    landing_context.blast_pad_m = best.blast_pad_m
    landing_context.opposite_blast_pad_m = best.opposite_blast_pad_m
    landing_context.marking_code = best.marking_code
    landing_context.opposite_marking_code = best.opposite_marking_code
    landing_context.tdz_lights = best.tdz_lights
    landing_context.opposite_tdz_lights = best.opposite_tdz_lights
    landing_context.reil_code = best.reil_code
    landing_context.opposite_reil_code = best.opposite_reil_code
    landing_context.touchdown_from_threshold_m = best.threshold_distance_m
    landing_context.runway_remaining_m = best.remaining_m
    landing_context.centerline_offset_m = best.centerline_offset_m
    landing_context.centerline_signed_m = best.centerline_signed_m
    if best.centerline_signed_m > 0.05 then
        landing_context.centerline_side = "LEFT"
    elseif best.centerline_signed_m < -0.05 then
        landing_context.centerline_side = "RIGHT"
    else
        landing_context.centerline_side = "CENTER"
    end
    log_tools.apply_centerline_score()
    log_tools.finish_runway_resolver("resolved", "")
    return true
end

function log_tools.process_apt_line(line)
    local state = log_tools.runway_state
    local code = tostring(line or ""):match("^%s*(%d+)%s")
    if state.collecting and (code == "1" or code == "16" or code == "17") then
        if log_tools.finish_airport_block() or not state.active then return true end
    end
    if not state.collecting then
        if code == "1" then
            local fields = log_tools.apt_tokens(line)
            local airport_id = string.upper(trim_text(fields[5] or ""))
            local is_prefetch_candidate = state.mode == "prefetch"
                and state.prefetch_queued[airport_id] == true
                and state.cache[airport_id] == nil
            if airport_id == state.target_airport or is_prefetch_candidate then
                state.collecting = true
                state.collecting_airport = airport_id
                state.runways = {}
                state.metadata = {
                    airport_elevation_ft = tonumber(fields[2]),
                    airport_id = airport_id,
                    airport_name = trim_text(table.concat(fields, " ", 6))
                }
            end
        end
        return false
    end

    if code == "100" then
        local runway = log_tools.parse_runway_row(line)
        if runway ~= nil then state.runways[#state.runways + 1] = runway end
    elseif code == "1302" then
        local key, value = tostring(line):match("^%s*1302%s+(%S+)%s+(.+)%s*$")
        if key ~= nil then state.metadata[string.lower(key)] = trim_text(value) end
    end
    return false
end

-- 机场建在悬崖、高架结构或海岸边时，X-Plane y_agl 会随正下方地形突然改变。
-- 跑道预读完成后改用“飞机 MSL 高度 - apt.dat 机场标高”作为拉平轨迹高度；
-- 一旦轨迹启动就冻结本轮基准，避免中途切换制造新的高度跳变。
function log_tools.flare_reference_height_ft(elevation_m, terrain_agl_ft)
    local state = log_tools.runway_state
    local reference_elevation_ft = nil
    if flare_trace.active and flare_trace.height_reference == "APT_ELEVATION" then
        reference_elevation_ft = flare_trace.reference_elevation_ft
    elseif flare_trace.active then
        return terrain_agl_ft
    else
        local metadata_is_target = state.collecting_airport == ""
            or state.collecting_airport == state.target_airport
        if metadata_is_target then
            reference_elevation_ft = tonumber(state.metadata and state.metadata.airport_elevation_ft)
        end
        if reference_elevation_ft == nil
            and state.target_airport ~= "" then
            local cached = state.cache[state.target_airport]
            reference_elevation_ft = cached and cached.metadata
                and tonumber(cached.metadata.airport_elevation_ft) or nil
        end
    end

    if reference_elevation_ft == nil then
        flare_trace.height_reference = "TERRAIN_AGL"
        flare_trace.reference_elevation_ft = 0
        return terrain_agl_ft
    end

    local runway_relative_ft = meters_to_feet(elevation_m) - reference_elevation_ft
    if runway_relative_ft < -50 or runway_relative_ft > 6000 then
        flare_trace.height_reference = "TERRAIN_AGL"
        flare_trace.reference_elevation_ft = 0
        return terrain_agl_ft
    end

    flare_trace.height_reference = "APT_ELEVATION"
    flare_trace.reference_elevation_ft = reference_elevation_ft
    return math.max(0, runway_relative_ft)
end

function log_tools.open_next_apt_source()
    local state = log_tools.runway_state
    while state.source_index < #state.sources do
        state.source_index = state.source_index + 1
        state.source = state.sources[state.source_index]
        state.file = io.open(state.source.path, "rb")
        state.partial = ""
        state.collecting = false
        state.collecting_airport = ""
        state.runways = {}
        state.metadata = {}
        if state.file ~= nil then return true end
    end
    log_tools.finish_runway_resolver("unavailable", "所有 apt.dat 均未找到该机场")
    return false
end

function log_tools.start_runway_resolver(airport_id, now, mode)
    local state = log_tools.runway_state
    local target_airport = string.upper(trim_text(airport_id))
    local requested_mode = mode == "prefetch" and "prefetch" or "landing"
    if target_airport == "" then return false end

    local cached = state.cache[target_airport]
    if cached ~= nil then
        if requested_mode == "prefetch" then
            state.last_mode = "prefetch"
            state.last_status = "prefetched"
            state.last_reason = ""
            return true
        end
        log_tools.cancel_runway_resolver("")
        state.target_airport = target_airport
        state.runways = cached.runways or {}
        state.metadata = cached.metadata or {}
        state.source = cached.source
        state.mode = "landing"
        state.active = true
        landing_context.runway_status = "scanning"
        return log_tools.finish_airport_block()
    end

    -- 如果触地后确认的机场与进近预扫描目标一致，直接从当前文件偏移继续。
    if state.active and state.target_airport == target_airport then
        if requested_mode == "landing" then
            state.mode = "landing"
            state.started_at = now or 0
            landing_context.runway_status = "scanning"
        end
        return true
    end

    log_tools.cancel_runway_resolver("")
    state.target_airport = target_airport
    state.source_index = 0
    state.started_at = now or 0
    state.mode = requested_mode
    state.active = true
    if requested_mode == "landing" then landing_context.runway_status = "scanning" end
    if #state.sources == 0 then
        log_tools.finish_runway_resolver("unavailable", "没有可读取的 apt.dat 数据源")
        return false
    end
    return log_tools.open_next_apt_source()
end

function log_tools.process_runway_resolver(now)
    local state = log_tools.runway_state
    if not state.active then return false end
    local timeout_seconds = state.mode == "prefetch"
        and log_tools.runway_config.prefetch_timeout_seconds
        or log_tools.runway_config.timeout_seconds
    if now - state.started_at >= timeout_seconds then
        local reason = state.mode == "prefetch"
            and "进近跑道预扫描超过时间预算"
            or "跑道识别超过时间预算"
        log_tools.finish_runway_resolver("timeout", reason)
        return true
    end
    if state.file == nil and not log_tools.open_next_apt_source() then return true end
    if not state.active or state.file == nil then return true end

    local chunk = state.file:read(log_tools.runway_config.scan_chunk_bytes)
    if chunk == nil then
        if state.partial ~= "" then
            log_tools.process_apt_line(state.partial)
            state.partial = ""
        end
        if not state.active then return true end
        if state.collecting then
            if log_tools.finish_airport_block() or not state.active then return true end
        end
        state.file:close()
        state.file = nil
        state.source = nil
        return false
    end

    local data = state.partial .. chunk
    local last_break = data:match(".*()\n")
    if last_break == nil then
        state.partial = data
        return false
    end
    local complete = data:sub(1, last_break)
    state.partial = data:sub(last_break + 1)
    for line in complete:gmatch("[^\r\n]+") do
        if log_tools.process_apt_line(line) then return true end
    end
    return not state.active
end

function log_tools.enqueue_runway_prefetch(airport_id, prefer_front)
    local state = log_tools.runway_state
    local config = log_tools.runway_config
    local normalized_id = string.upper(trim_text(airport_id))
    if normalized_id == ""
        or state.cache[normalized_id] ~= nil
        or (state.active and state.target_airport == normalized_id) then
        return false
    end
    if state.prefetch_queued[normalized_id] == true then
        if prefer_front == true then
            for i = #state.prefetch_queue, 1, -1 do
                if state.prefetch_queue[i] == normalized_id then
                    table.remove(state.prefetch_queue, i)
                    break
                end
            end
            table.insert(state.prefetch_queue, 1, normalized_id)
        end
        return false
    end
    if #state.prefetch_queue >= config.nearby_prefetch_queue_limit and prefer_front ~= true then
        return false
    end
    if prefer_front == true then
        table.insert(state.prefetch_queue, 1, normalized_id)
    else
        state.prefetch_queue[#state.prefetch_queue + 1] = normalized_id
    end
    state.prefetch_queued[normalized_id] = true
    return true
end

function log_tools.probe_prefetch_airport(query_lat, query_lon, origin_lat, origin_lon, max_distance_km, prefer_front)
    local nav_ref = XPLMFindNavAid(nil, nil, query_lat, query_lon, nil, xplm_Nav_Airport)
    if nav_ref == nil or nav_ref == -1 then return nil end
    local _, airport_lat, airport_lon, _, _, _, airport_id, airport_name = XPLMGetNavAidInfo(nav_ref)
    airport_id = string.upper(trim_text(airport_id))
    if airport_id == "" or airport_lat == nil or airport_lon == nil then return nil end
    local airport_distance = distance_km(origin_lat, origin_lon, airport_lat, airport_lon)
    if airport_distance > max_distance_km then return nil end
    log_tools.runway_state.airport_nav[airport_id] = {
        latitude = airport_lat,
        longitude = airport_lon,
        name = trim_text(airport_name)
    }
    log_tools.enqueue_runway_prefetch(airport_id, prefer_front)
    return airport_id
end

function log_tools.prune_runway_prefetch_queue(latitude, longitude)
    local state = log_tools.runway_state
    local kept = {}
    for i = 1, #state.prefetch_queue do
        local airport_id = state.prefetch_queue[i]
        local nav_info = state.airport_nav[airport_id]
        local keep = state.cache[airport_id] == nil
        if keep and nav_info ~= nil then
            keep = distance_km(
                latitude,
                longitude,
                nav_info.latitude,
                nav_info.longitude
            ) <= log_tools.runway_config.prefetch_max_distance_km
        end
        if keep then
            kept[#kept + 1] = airport_id
        else
            state.prefetch_queued[airport_id] = nil
        end
    end
    state.prefetch_queue = kept
end

function log_tools.discover_nearby_prefetch_airports(latitude, longitude, now)
    local config = log_tools.runway_config
    log_tools.prune_runway_prefetch_queue(latitude, longitude)
    local primary_id = log_tools.probe_prefetch_airport(
        latitude,
        longitude,
        latitude,
        longitude,
        config.prefetch_max_distance_km,
        true
    )
    local state = log_tools.runway_state
    local moved_km = math.huge
    if state.last_nearby_probe_lat ~= nil and state.last_nearby_probe_lon ~= nil then
        moved_km = distance_km(
            latitude,
            longitude,
            state.last_nearby_probe_lat,
            state.last_nearby_probe_lon
        )
    end
    if moved_km < config.nearby_probe_move_km
        and (now or 0) - state.last_nearby_probe_at < config.nearby_probe_interval_seconds then
        return primary_id
    end
    state.last_nearby_probe_lat = latitude
    state.last_nearby_probe_lon = longitude
    state.last_nearby_probe_at = now or 0
    local lat_delta = config.nearby_probe_radius_km / 111.32
    local cos_lat = math.abs(math.cos(latitude * math.pi / 180))
    if cos_lat < 0.10 then cos_lat = 0.10 end
    local lon_delta = config.nearby_probe_radius_km / (111.32 * cos_lat)
    local diagonal = 0.70710678
    local max_distance = config.nearby_candidate_max_distance_km
    log_tools.probe_prefetch_airport(latitude + lat_delta, longitude, latitude, longitude, max_distance, false)
    log_tools.probe_prefetch_airport(latitude - lat_delta, longitude, latitude, longitude, max_distance, false)
    log_tools.probe_prefetch_airport(latitude, longitude + lon_delta, latitude, longitude, max_distance, false)
    log_tools.probe_prefetch_airport(latitude, longitude - lon_delta, latitude, longitude, max_distance, false)
    log_tools.probe_prefetch_airport(latitude + lat_delta * diagonal, longitude + lon_delta * diagonal, latitude, longitude, max_distance, false)
    log_tools.probe_prefetch_airport(latitude + lat_delta * diagonal, longitude - lon_delta * diagonal, latitude, longitude, max_distance, false)
    log_tools.probe_prefetch_airport(latitude - lat_delta * diagonal, longitude + lon_delta * diagonal, latitude, longitude, max_distance, false)
    log_tools.probe_prefetch_airport(latitude - lat_delta * diagonal, longitude - lon_delta * diagonal, latitude, longitude, max_distance, false)
    return primary_id
end

function log_tools.start_next_runway_prefetch(now)
    local state = log_tools.runway_state
    while #state.prefetch_queue > 0 do
        local airport_id = table.remove(state.prefetch_queue, 1)
        state.prefetch_queued[airport_id] = nil
        if state.cache[airport_id] == nil then
            return log_tools.start_runway_resolver(airport_id, now, "prefetch")
        end
    end
    return false
end

function log_tools.update_runway_prefetch(now, radio_alt_ft, on_ground, local_vy_mps, gs_kt, is_armed)
    local state = log_tools.runway_state
    local config = log_tools.runway_config
    if runtime_state.runway_detection_enabled ~= true
        or is_armed ~= true
        or on_ground ~= 0
        or radio_alt_ft < config.prefetch_min_agl_ft
        or radio_alt_ft > config.prefetch_max_agl_ft
        or local_vy_mps >= -0.10
        or gs_kt <= 50 then
        return false
    end
    if now - state.last_prefetch_check < config.prefetch_check_interval_seconds then return false end
    state.last_prefetch_check = now

    local latitude = lmm_get_double("latitude_deg")
    local longitude = lmm_get_double("longitude_deg")
    local airport_id = log_tools.discover_nearby_prefetch_airports(latitude, longitude, now)
    if airport_id == nil then return false end
    if state.active then
        if state.mode == "landing" then return false end
        return true
    end
    if log_tools.start_next_runway_prefetch(now) then return true end
    return state.cache[airport_id] ~= nil
end

local function resolve_landing_context(now)
    landing_context.airport_id = "UNKNOWN"
    landing_context.airport_internal_id = ""
    landing_context.airport_name = ""
    landing_context.airport_distance_km = 0
    landing_context.runway = "--"
    landing_context.runway_detected = false
    landing_context.runway_confidence = "NONE"

    local nav_ref = XPLMFindNavAid(
        nil,
        nil,
        landing_context.touch_latitude,
        landing_context.touch_longitude,
        nil,
        xplm_Nav_Airport
    )
    if nav_ref == nil or nav_ref == -1 then
        landing_context.runway_status = "unavailable"
        return false, "未找到附近机场"
    end

    local _, airport_lat, airport_lon, _, _, _, airport_id, airport_name = XPLMGetNavAidInfo(nav_ref)
    airport_id = string.upper(trim_text(airport_id))
    airport_name = trim_text(airport_name)
    if airport_id == "" then
        landing_context.runway_status = "unavailable"
        return false, "机场导航数据没有标识符"
    end

    local airport_distance = distance_km(
        landing_context.touch_latitude,
        landing_context.touch_longitude,
        airport_lat,
        airport_lon
    )
    if airport_distance > MAX_AIRPORT_DISTANCE_KM then
        landing_context.runway_status = "unavailable"
        return false, string.format("最近机场距离 %.1f km，超过识别范围", airport_distance)
    end

    landing_context.airport_id = airport_id
    landing_context.airport_internal_id = airport_id
    landing_context.airport_name = airport_name
    landing_context.airport_distance_km = airport_distance
    log_tools.runway_state.airport_nav[airport_id] = {
        latitude = airport_lat,
        longitude = airport_lon,
        name = airport_name
    }
    if runtime_state.runway_detection_enabled then
        log_tools.start_runway_resolver(airport_id, now, "landing")
    else
        landing_context.runway_status = "disabled"
    end
    return true
end

local function landing_context_short_text()
    local aircraft = landing_context.aircraft_icao
    local airport = landing_context.airport_id
    if airport == "识别中" then
        return string.format(log_tools.ui_text("%s | 机场信息计算中", "%s | Resolving airport data"), aircraft)
    end
    if airport == "UNKNOWN" then
        return string.format(log_tools.ui_text("%s | 机场未识别", "%s | Airport not identified"), aircraft)
    end
    if landing_context.runway_detected then
        return string.format("%s | %s | RWY %s", aircraft, airport, landing_context.runway)
    end
    if landing_context.runway_status == "pending" or landing_context.runway_status == "scanning" then
        return string.format(log_tools.ui_text("%s | %s | 跑道识别中", "%s | %s | Resolving runway"), aircraft, airport)
    end
    return string.format("%s | %s", aircraft, airport)
end

function log_tools.write_runway_reference(file)
    if landing_context.runway_detected then
        file:write("跑道说明: 依据 scenery_packs.ini 优先级读取 apt.dat，并用跑道端点、触地坐标和地速向量完成几何匹配；位置采用飞机参考点，数值为约值。\n")
        file:write("跑道识别来源: X-Plane apt.dat 几何匹配\n")
        file:write("跑道识别可信度: " .. landing_context.runway_confidence .. "\n")
        file:write("跑道数据源: " .. landing_context.runway_source .. "\n")
        file:write(string.format("跑道长度: %.1f m\n", landing_context.runway_length_m))
        file:write(string.format("跑道宽度: %.1f m\n", landing_context.runway_width_m))
        file:write("跑道路面: " .. landing_context.runway_surface .. "\n")
        file:write("跑道路面代码: " .. tostring(landing_context.runway_surface_code) .. "\n")
        file:write("反向跑道方向: RWY" .. landing_context.opposite_runway .. "\n")
        file:write("跑道标线代码: " .. tostring(landing_context.marking_code) .. "\n")
        file:write("跑道标线类型: " .. log_tools.runway_marking_text(landing_context.marking_code) .. "\n")
        file:write("反向跑道标线代码: " .. tostring(landing_context.opposite_marking_code) .. "\n")
        file:write("反向跑道标线类型: " .. log_tools.runway_marking_text(landing_context.opposite_marking_code) .. "\n")
        file:write(string.format("跑道入口内移: %.1f m\n", landing_context.displaced_threshold_m))
        file:write(string.format("反向跑道入口内移: %.1f m\n", landing_context.opposite_displaced_threshold_m))
        file:write(string.format("跑道前端防吹坪: %.1f m\n", landing_context.blast_pad_m))
        file:write(string.format("反向跑道防吹坪: %.1f m\n", landing_context.opposite_blast_pad_m))
        file:write("接地区灯: " .. log_tools.runway_yes_no(landing_context.tdz_lights) .. "\n")
        file:write("反向接地区灯: " .. log_tools.runway_yes_no(landing_context.opposite_tdz_lights) .. "\n")
        file:write("跑道入口识别灯代码: " .. tostring(landing_context.reil_code) .. "\n")
        file:write("反向跑道入口识别灯代码: " .. tostring(landing_context.opposite_reil_code) .. "\n")
        file:write("跑道中线灯代码: " .. tostring(landing_context.runway_centerline_lights) .. "\n")
        file:write("跑道边灯代码: " .. tostring(landing_context.runway_edge_lights) .. "\n")
        file:write("跑道道肩代码: " .. tostring(landing_context.runway_shoulder_code) .. "\n")
        file:write(string.format("触地点距跑道入口: %.1f m（飞机参考点，约）\n", landing_context.touchdown_from_threshold_m))
        file:write(string.format("触地点距跑道末端: %.1f m（飞机参考点，约）\n", landing_context.runway_remaining_m))
        file:write(string.format("触地点距跑道中心线: %.1f m（飞机参考点，约）\n", landing_context.centerline_offset_m))
        file:write(string.format("触地点中心线有符号偏差: %+.1f m（左正右负）\n", landing_context.centerline_signed_m))
        file:write("触地点中心线方向: " .. landing_context.centerline_side .. "\n")
    else
        local reason = log_tools.runway_state.last_reason
        if landing_context.runway_status == "disabled" then reason = "用户已关闭精准跑道识别" end
        file:write("跑道说明: 未输出跑道方向和触地点；插件不会使用磁航向猜测跑道。\n")
        file:write("跑道识别来源: " .. (reason ~= "" and reason or "无可靠结果") .. "\n")
        file:write("跑道识别可信度: NONE\n")
    end
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

function log_tools.relative_wind_side(wind_from_deg, aircraft_heading_deg, language)
    local diff = angular_diff_180(wind_from_deg, aircraft_heading_deg)
    local abs_diff = abs_value(diff)
    local chinese, english = "顶风", "headwind"
    if abs_diff <= 20 then
        chinese, english = "顶风", "headwind"
    elseif abs_diff >= 160 then
        chinese, english = "顺风", "tailwind"
    elseif diff < 0 and abs_diff <= 90 then
        chinese, english = "左前侧风", "left-front crosswind"
    elseif diff > 0 and abs_diff <= 90 then
        chinese, english = "右前侧风", "right-front crosswind"
    elseif diff < 0 then
        chinese, english = "左后侧风", "left-rear crosswind"
    else
        chinese, english = "右后侧风", "right-rear crosswind"
    end
    return language == "en" and english or chinese
end

local function build_wind_relative_text(wind_from_deg, wind_speed_kts, aircraft_heading_deg)
    -- 相对风在触地时按当前文档输出语言固化，保证弹窗与 TXT 报告表述一致。
    return string.format(
        runtime_state.document_language == "en" and "Wind %03d/%dkt %s" or "风 %03d/%dkt %s",
        round_num(normalize_deg(wind_from_deg)),
        round_num(wind_speed_kts),
        log_tools.relative_wind_side(wind_from_deg, aircraft_heading_deg, runtime_state.document_language)
    )
end

local function format_roll_text(roll_deg)
    local abs_roll = abs_value(roll_deg)
    if abs_roll < 0.05 then
        return log_tools.ui_text("横滚 LEVEL 0.0°", "Roll LEVEL 0.0°")
    elseif roll_deg < 0 then
        return string.format(log_tools.ui_text("横滚 L %.1f°", "Roll L %.1f°"), abs_roll)
    end
    return string.format(log_tools.ui_text("横滚 R %.1f°", "Roll R %.1f°"), abs_roll)
end

local function classify_landing(fpm, g, external_hint)
    local abs_fpm = abs_value(fpm)
    local level = 0
    -- 0 = 轻柔，1 = 稳定，2 = 需注意，3 = 不良落地。
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
        return log_tools.ui_text("UNSTABLE 不良落地", "UNSTABLE Adverse landing")
    elseif status == "ATTENTION" then
        return log_tools.ui_text("Attention 需注意", "Attention Review advised")
    elseif status == "STABLE" then
        return log_tools.ui_text("Stable 稳定扎实落地", "Stable Solid landing")
    else
        return log_tools.ui_text("Nice 轻柔接地", "Nice Soft touchdown")
    end
end

function log_tools.popup_status_text(status)
    if status == "UNSTABLE" then return log_tools.ui_text("UNSTABLE 不良落地", "UNSTABLE Adverse landing") end
    if status == "ATTENTION" then return log_tools.ui_text("Attention 需注意", "Attention Review advised") end
    if status == "STABLE" then return log_tools.ui_text("Stable 稳定扎实落地", "Stable Solid landing") end
    return log_tools.ui_text("Nice 轻柔接地", "Nice Soft touchdown")
end

function log_tools.popup_flare_trend_text(value)
    if runtime_state.document_language ~= "en" then return value end
    local english = {
        ["等待100英尺采样"] = "Waiting for 100 ft sampling",
        ["拉平轨迹样本不足"] = "Insufficient flare samples",
        ["拉平轨迹聚合点不足"] = "Insufficient flare buckets",
        ["下降率轨迹震荡高"] = "High vertical-speed oscillation",
        ["下降率轨迹正常"] = "Vertical-speed trend normal"
    }
    return english[value] or value
end

function log_tools.popup_warning_text(value)
    if runtime_state.document_language ~= "en" then return value end
    if value == "道面湿滑，注意摩擦力" then return "Wet surface: reduced braking friction" end
    if value == "持续降雨，道面可能湿滑" then return "Persistent rain: runway may be wet" end
    return value
end

local function refresh_popup_cache()
    popup_cache.lines[1] = landing_context_short_text()
    popup_cache.lines[2] = string.format("%+d fpm | +%.2fG", landing_fpm, landing_g)
    popup_cache.lines[3] = string.format("IAS %.0fkt | GS %.0fkt", landing_ias_kts, landing_gs_kts)
    popup_cache.lines[4] = string.format(log_tools.ui_text("迎角 %.1f° | %s", "AoA %.1f° | %s"), landing_aoa_deg, format_roll_text(landing_roll_deg))
    local flare_trend = log_tools.popup_flare_trend_text(flare_analysis.trend_text)
    if flare_analysis.valid then
        popup_cache.lines[5] = string.format(log_tools.ui_text("拉平曲率 %.1f | %s", "Flare curvature %.1f | %s"), flare_analysis.metric, flare_trend)
    else
        popup_cache.lines[5] = log_tools.ui_text("拉平曲率 -- | ", "Flare curvature -- | ") .. flare_trend
    end
    popup_cache.lines[6] = string.format(
        log_tools.ui_text("风 %03d/%dkt %s", "Wind %03d/%dkt %s"),
        round_num(normalize_deg(landing_wind_heading_deg)),
        round_num(landing_wind_speed_kts),
        log_tools.relative_wind_side(landing_wind_heading_deg, landing_heading_deg, runtime_state.document_language)
    )
    popup_cache.lines[7] = log_tools.popup_status_text(landing_status)
    popup_cache.warning_text = log_tools.popup_warning_text(landing_surface.warning_text)
    if landing_context.centerline_penalty_applied then
        popup_cache.centerline_text = string.format(
            log_tools.ui_text("偏离中心线 %.1f 米", "Centerline deviation %.1f m"),
            landing_context.centerline_offset_m
        )
    else
        popup_cache.centerline_text = ""
    end
    if bounce_state.detected then
        if bounce_state.second_g_ready then
            popup_cache.bounce_text = string.format(log_tools.ui_text("发生弹跳 | 二次 %+d fpm / +%.2fG", "Bounce detected | 2nd %+d fpm / +%.2fG"), bounce_state.second_fpm, bounce_state.second_curve_g)
        else
            popup_cache.bounce_text = log_tools.ui_text("发生弹跳 | 正在分析第二次触地", "Bounce detected | Analysing second touchdown")
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

local function add_flight_sample(now, vvi_fpm, local_vy_mps, g_normal, pitch_deg, roll_deg, agl_m, on_ground)
    local next_index = sample_buffer.write_index + 1
    if next_index > SAMPLE_BUFFER_SIZE then next_index = 1 end

    local slot = sample_buffer.slots[next_index]
    slot.t = now
    slot.vvi_fpm = vvi_fpm
    slot.local_vy_mps = local_vy_mps
    slot.g_normal = sanitize_g(g_normal) or 0
    slot.pitch_deg = pitch_deg
    slot.roll_deg = roll_deg
    slot.agl_m = agl_m
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
                slot.agl_m = sample.agl_m
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
    flare_trace.touch_reference_ft = 0
    flare_trace.next_sample_time = 0
    flare_trace.descent_confirm_start = 0
    flare_trace.climb_confirm_start = 0
    flare_trace.height_reference = "TERRAIN_AGL"
    flare_trace.reference_elevation_ft = 0
    flare_trace.count = 0
    flare_trace.analysis_sample_count = 0
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
    bounce_state.result_status = "NICE"
    bounce_state.score_applied = false
end

local function start_flare_trace(now)
    flare_trace.active = true
    flare_trace.complete = false
    flare_trace.limited = false
    flare_trace.start_time = now
    flare_trace.next_sample_time = now
    flare_trace.descent_confirm_start = 0
    flare_trace.climb_confirm_start = 0
    flare_trace.touch_reference_ft = 0
    flare_trace.count = 0
    flare_trace.analysis_sample_count = 0
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
    local physical_fpm = local_vy_mps * 196.850394
    local descending = on_ground == 0
        and physical_fpm <= FLARE_CONFIG.start_descent_fpm
        and vvi_fpm <= FLARE_CONFIG.start_descent_fpm

    -- 已启动的轨迹如果重新爬升、飞离近地范围或持续时间异常，则判定为复飞/陈旧数据并作废。
    if flare_trace.active == true then
        local climbing = physical_fpm >= FLARE_CONFIG.cancel_climb_fpm
            and vvi_fpm >= FLARE_CONFIG.cancel_climb_fpm
        if climbing then
            if flare_trace.climb_confirm_start <= 0 then
                flare_trace.climb_confirm_start = now
            end
        else
            flare_trace.climb_confirm_start = 0
        end

        local climb_confirmed = flare_trace.climb_confirm_start > 0
            and now - flare_trace.climb_confirm_start >= FLARE_CONFIG.cancel_climb_seconds
        local trace_timed_out = flare_trace.start_time > 0
            and now - flare_trace.start_time > FLARE_CONFIG.max_trace_seconds
        if radio_alt_ft >= FLARE_CONFIG.cancel_agl_ft
            or climb_confirmed
            or trace_timed_out then
            reset_flare_trace()
        end
    end

    -- 必须先确认飞机持续下降，防止起飞爬升穿过 100 英尺时误启动拉平采样。
    if flare_trace.active == false
        and flare_trace.complete == false
        and armed == true
        and on_ground == 0 then
        if descending then
            if flare_trace.descent_confirm_start <= 0 then
                flare_trace.descent_confirm_start = now
            end
        else
            flare_trace.descent_confirm_start = 0
        end

        local descent_confirmed = flare_trace.descent_confirm_start > 0
            and now - flare_trace.descent_confirm_start >= FLARE_CONFIG.start_confirm_seconds
        if descent_confirmed
            and radio_alt_ft <= FLARE_CONFIG.start_agl_ft + FLARE_CONFIG.capture_margin_ft
            and radio_alt_ft >= 0 then
            start_flare_trace(now)
        end
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
local function finish_flare_trace(now, touchdown_height_ft)
    flare_trace.active = false
    flare_trace.complete = true
    flare_trace.touch_time = now
    local reference_ft = tonumber(touchdown_height_ft) or 0
    if reference_ft < 0 or reference_ft > FLARE_CONFIG.max_touch_reference_ft then
        reference_ft = 0
    end
    flare_trace.touch_reference_ft = reference_ft
end

local function analyze_flare_curve()
    local started = os.clock()
    flare_analysis.valid = false
    flare_analysis.touchdown_fpm = landing_fpm
    local use_physical_curve = landing_analysis.flare_fpm_source == "PHYSICAL"
    local use_agl_curve = landing_analysis.flare_fpm_source == "AGL"
    flare_analysis.duration_seconds = 0
    flare_trace.analysis_sample_count = 0

    for i = 1, FLARE_CONFIG.max_buckets do
        local bucket = flare_trace.buckets[i]
        bucket.count = 0
        bucket.t = 0
        bucket.agl_ft = 0
        bucket.physical_fpm = 0
        bucket.vvi_fpm = 0
        bucket.selected_fpm = 0
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

    -- apt.dat 高度和 X-Plane y_agl 都使用飞机参考点，不会在机轮接地时自然变成 0。
    -- 用触地帧冻结的参考点高度统一归零，再从校准后的 100 ft 位置开始分析；
    -- 预采样区保证归零后仍保留完整的 100 ft 后轨迹。
    local analysis_start_time = 0
    for i = 1, flare_trace.count do
        local sample = flare_trace.slots[i]
        local corrected_height_ft = math.max(0, sample.agl_ft - flare_trace.touch_reference_ft)
        if corrected_height_ft <= FLARE_CONFIG.start_agl_ft then
            analysis_start_time = sample.t
            break
        end
    end
    if analysis_start_time <= 0 then
        flare_analysis.trend_text = "拉平轨迹缺少接地点校准后的100英尺样本"
        flare_analysis.calculation_ms = (os.clock() - started) * 1000
        return
    end
    flare_trace.start_time = analysis_start_time
    flare_analysis.duration_seconds = math.max(0, flare_trace.touch_time - flare_trace.start_time)

    -- 原始 10 Hz 样本按 0.25 秒时间桶求平均，保留高度、速度和姿态参考信息。
    for i = 1, flare_trace.count do
        local sample = flare_trace.slots[i]
        if sample.t >= flare_trace.start_time then
            local bucket_index = math.floor(
                (sample.t - flare_trace.start_time) / FLARE_CONFIG.bucket_seconds
            ) + 1
            if bucket_index < 1 then bucket_index = 1 end
            if bucket_index > FLARE_CONFIG.max_buckets then
                bucket_index = FLARE_CONFIG.max_buckets
                flare_trace.limited = true
            end

            local bucket = flare_trace.buckets[bucket_index]
            flare_trace.analysis_sample_count = flare_trace.analysis_sample_count + 1
            bucket.count = bucket.count + 1
            bucket.t = bucket.t + sample.t
            bucket.agl_ft = bucket.agl_ft
                + math.max(0, sample.agl_ft - flare_trace.touch_reference_ft)
            bucket.physical_fpm = bucket.physical_fpm + sample.physical_fpm
            bucket.vvi_fpm = bucket.vvi_fpm + sample.vvi_fpm
            bucket.selected_fpm = bucket.selected_fpm
                + (use_physical_curve and sample.physical_fpm or sample.vvi_fpm)
            bucket.ias_kts = bucket.ias_kts + sample.ias_kts
            bucket.gs_kts = bucket.gs_kts + sample.gs_kts
            bucket.pitch_deg = bucket.pitch_deg + sample.pitch_deg
            bucket.aoa_deg = bucket.aoa_deg + sample.aoa_deg
            bucket.roll_deg = bucket.roll_deg + sample.roll_deg
        end
    end

    if flare_trace.analysis_sample_count < FLARE_CONFIG.min_samples then
        flare_analysis.trend_text = "拉平轨迹校准后样本不足"
        flare_analysis.calculation_ms = (os.clock() - started) * 1000
        return
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
                target.selected_fpm = source.selected_fpm
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
            target.selected_fpm = target.selected_fpm / count
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

    -- 最终采用 AGL 锚点时，轨迹主线同步从已校准的跑道相对高度求中心差分；
    -- 物理 FPM 与 VVI 仍作为独立曲线保留。
    if use_agl_curve then
        for i = 1, compact_count do
            local left_index = math.max(1, i - 1)
            local right_index = math.min(compact_count, i + 1)
            local left_bucket = flare_trace.buckets[left_index]
            local right_bucket = flare_trace.buckets[right_index]
            local dt = right_bucket.t - left_bucket.t
            if dt > 0.05 then
                flare_trace.buckets[i].selected_fpm =
                    (right_bucket.agl_ft - left_bucket.agl_ft) / dt * 60
            end
        end
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
        touch_bucket.physical_fpm = landing_analysis.physical_fpm_valid
            and landing_analysis.physical_fpm or landing_analysis.vvi_fpm
        touch_bucket.vvi_fpm = landing_analysis.vvi_fpm
        touch_bucket.selected_fpm = landing_fpm
        touch_bucket.ias_kts = landing_ias_kts
        touch_bucket.gs_kts = landing_gs_kts
        touch_bucket.pitch_deg = approach_data.pitch_deg
        touch_bucket.aoa_deg = landing_aoa_deg
        touch_bucket.roll_deg = landing_roll_deg
    else
        last_bucket.t = flare_trace.touch_time
        last_bucket.agl_ft = 0
        last_bucket.physical_fpm = landing_analysis.physical_fpm_valid
            and landing_analysis.physical_fpm or landing_analysis.vvi_fpm
        last_bucket.vvi_fpm = landing_analysis.vvi_fpm
        last_bucket.selected_fpm = landing_fpm
    end
    flare_trace.bucket_count = compact_count

    local entry_fpm = flare_trace.buckets[1].selected_fpm
    local touch_fpm = flare_trace.buckets[compact_count].selected_fpm
    local total_variation = 0
    local worsening_count = 0
    local reversal_count = 0
    local previous_direction = 0
    local signed_curvature_sum = 0
    local curvature_count = 0
    local old_scratch_count = sort_scratch_count
    sort_scratch_count = 0

    for i = 2, compact_count do
        local delta = flare_trace.buckets[i].selected_fpm
            - flare_trace.buckets[i - 1].selected_fpm
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
            local slope1 = (p2.selected_fpm - p1.selected_fpm) / dt1
            local slope2 = (p3.selected_fpm - p2.selected_fpm) / dt2
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
            late_reference_fpm = flare_trace.buckets[i].selected_fpm
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

-- 收集 5 ft 以下终端窗口中的物理速度或 VVI，供物理备用值和 VVI 参考使用。
function log_tools.collect_terminal_fpm_values(touch_time, value_kind)
    local start_time = touch_time - landing_analysis.fpm_validation.agl_window_seconds
    local end_time = touch_time - landing_analysis.fpm_validation.agl_end_guard_seconds
    local max_agl_m = landing_analysis.fpm_validation.terminal_agl_ft / 3.28084
    local count = 0
    local old_count = sort_scratch_count

    for i = 1, sample_buffer.count do
        local sample = sample_at(i)
        if sample.on_ground == 0
            and sample.t >= start_time
            and sample.t <= end_time
            and sample.agl_m >= 0
            and sample.agl_m <= max_agl_m then
            local value = nil
            if value_kind == "local_vy" then
                value = sample.local_vy_mps
            elseif value_kind == "vvi" then
                value = sample.vvi_fpm
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

-- AGL 锚点使用 Theil-Sen 中位斜率：把 5 ft 以下 AGL 高度变化换算为下降率。
-- 它对少量高度跳点和跑道网格噪声不敏感，并且只在着陆分析阶段计算一次。
function log_tools.calculate_agl_closure_fpm(touch_time)
    local start_time = touch_time - landing_analysis.fpm_validation.agl_window_seconds
    local end_time = touch_time - landing_analysis.fpm_validation.agl_end_guard_seconds
    local max_agl_m = landing_analysis.fpm_validation.terminal_agl_ft / 3.28084
    local count = 0

    for i = 1, sample_buffer.count do
        local sample = sample_at(i)
        if sample.on_ground == 0
            and sample.t >= start_time
            and sample.t <= end_time
            and sample.agl_m >= 0
            and sample.agl_m <= max_agl_m
            and count < landing_analysis.fpm_validation.agl_max_samples then
            count = count + 1
            landing_analysis.agl_fit_times[count] = sample.t
            landing_analysis.agl_fit_values[count] = sample.agl_m
        end
    end

    landing_analysis.agl_sample_count = count
    if count < landing_analysis.fpm_validation.agl_min_samples then
        return nil
    end

    local span = landing_analysis.agl_fit_times[count] - landing_analysis.agl_fit_times[1]
    landing_analysis.agl_sample_span_seconds = math.max(0, span)
    if span < landing_analysis.fpm_validation.agl_min_span_seconds then
        return nil
    end

    local old_scratch_count = sort_scratch_count
    sort_scratch_count = 0
    for i = 1, count - 1 do
        for j = i + 1, count do
            local dt = landing_analysis.agl_fit_times[j] - landing_analysis.agl_fit_times[i]
            if dt >= landing_analysis.fpm_validation.agl_min_pair_gap_seconds then
                sort_scratch_count = sort_scratch_count + 1
                sort_scratch[sort_scratch_count] =
                    (landing_analysis.agl_fit_values[j] - landing_analysis.agl_fit_values[i]) / dt
            end
        end
    end

    landing_analysis.agl_pair_count = sort_scratch_count
    if sort_scratch_count < 3 then
        for i = sort_scratch_count + 1, old_scratch_count do
            sort_scratch[i] = nil
        end
        return nil
    end

    table.sort(sort_scratch)
    local slope_mps = scratch_median()
    for i = sort_scratch_count + 1, old_scratch_count do
        sort_scratch[i] = nil
    end
    if slope_mps == nil or slope_mps < -20 or slope_mps > 3 then
        return nil
    end
    return slope_mps * 196.850394
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
    landing_analysis.capture_end_reason = "正在采集"
    landing_analysis.vvi_fpm = 0
    landing_analysis.vvi_min_fpm = 0
    landing_analysis.vvi_fpm_valid = false
    landing_analysis.vvi_sample_count = 0
    landing_analysis.physical_fpm = 0
    landing_analysis.physical_short_fpm = 0
    landing_analysis.physical_fallback_fpm = 0
    landing_analysis.fpm_difference = 0
    landing_analysis.physical_fpm_valid = false
    landing_analysis.physical_sample_count = 0
    landing_analysis.agl_fpm = 0
    landing_analysis.agl_fpm_valid = false
    landing_analysis.agl_sample_count = 0
    landing_analysis.agl_pair_count = 0
    landing_analysis.agl_sample_span_seconds = 0
    landing_analysis.agl_physical_difference = 0
    landing_analysis.agl_vvi_difference = 0
    landing_analysis.fpm_max_pair_difference = 0
    landing_analysis.fpm_selection_reason = ""
    landing_analysis.fpm_method = "等待终端下降率测量"
    landing_analysis.flare_fpm_source = "VVI"
    landing_analysis.pre_vy_mps = 0
    landing_analysis.post_vy_mps = 0
    landing_analysis.velocity_delta_mps = 0
    landing_analysis.baseline_g = 1
    landing_analysis.curve_g = 1
    landing_analysis.local_event_g = 1
    landing_analysis.local_event_g_valid = false
    landing_analysis.local_event_window_start_time = 0
    landing_analysis.local_event_window_end_time = 0
    landing_analysis.local_event_window_span_seconds = 0
    landing_analysis.local_event_sample_count = 0
    landing_analysis.local_event_percentile_index = 0
    landing_analysis.robust_event_g = 1
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

    -- 触地率定义为第一次接触前的瞬时物理垂直速度。用最后 100 ms 离地样本中位数
    -- 抑制单帧抖动，同时避免 250 ms 窗口把拉平前段或带响应滞后的 VVI 当成接地值。
    local contact_count = collect_sample_values(
        math.max(buffer_start_time, touch_time - PHYSICAL_FPM_CONTACT_WINDOW_SECONDS),
        touch_time,
        "local_vy",
        true
    )
    local contact_physical_vy = scratch_median()
    if contact_count >= 3 and contact_physical_vy ~= nil then
        landing_analysis.physical_short_fpm = contact_physical_vy * 196.850394
    end

    -- 较宽的 250 ms 物理 P25 只在接地短窗样本不足时补充为物理候选。
    local fallback_physical_count = log_tools.collect_terminal_fpm_values(touch_time, "local_vy")
    local fallback_physical_vy = scratch_percentile(PHYSICAL_FPM_PERCENTILE)
    if fallback_physical_count >= 3 and fallback_physical_vy ~= nil then
        landing_analysis.physical_fallback_fpm = fallback_physical_vy * 196.850394
    end

    local physical_candidate_window = ""
    if contact_count >= 3 and contact_physical_vy ~= nil then
        landing_analysis.physical_fpm = landing_analysis.physical_short_fpm
        landing_analysis.physical_fpm_valid = true
        landing_analysis.physical_sample_count = contact_count
        physical_candidate_window = "SHORT"
    elseif fallback_physical_count >= 3 and fallback_physical_vy ~= nil then
        landing_analysis.physical_fpm = landing_analysis.physical_fallback_fpm
        landing_analysis.physical_fpm_valid = true
        landing_analysis.physical_sample_count = fallback_physical_count
        physical_candidate_window = "FALLBACK"
    end

    local vvi_count = log_tools.collect_terminal_fpm_values(touch_time, "vvi")
    landing_analysis.vvi_fpm = scratch_median() or approach_data.vs_fpm
    landing_analysis.vvi_sample_count = vvi_count
    landing_analysis.vvi_fpm_valid = vvi_count >= 3
    landing_analysis.vvi_min_fpm = select_min_vvi_fpm(touch_time)

    local agl_fpm = log_tools.calculate_agl_closure_fpm(touch_time)
    landing_analysis.agl_fpm_valid = agl_fpm ~= nil
    landing_analysis.agl_fpm = agl_fpm or 0

    -- AGL 是跨机模选择锚点。物理 FPM 与 VVI 中距离 AGL 更近且差值不超过阈值者胜出；
    -- 如果没有候选值足够接近 AGL，则直接使用 AGL，避免对任一机模数据链做固定偏好。
    local max_agl_difference = landing_analysis.fpm_validation.agl_anchor_max_difference_fpm
    local physical_agl_distance = landing_analysis.physical_fpm_valid
        and abs_value(landing_analysis.physical_fpm - landing_analysis.agl_fpm) or math.huge
    local vvi_agl_distance = landing_analysis.vvi_fpm_valid
        and abs_value(landing_analysis.vvi_fpm - landing_analysis.agl_fpm) or math.huge

    if landing_analysis.agl_fpm_valid then
        if landing_analysis.physical_fpm_valid
            and physical_agl_distance <= max_agl_difference
            and physical_agl_distance <= vvi_agl_distance then
            landing_analysis.fpm_selection_reason = "PHYSICAL_CLOSEST"
            if physical_candidate_window == "SHORT" then
                landing_analysis.fpm_method = "物理 FPM 最接近 AGL，采用接地前100 ms物理值"
            else
                landing_analysis.fpm_method = "物理 FPM 最接近 AGL，采用250 ms物理备用值"
            end
            landing_analysis.flare_fpm_source = "PHYSICAL"
            landing_fpm = round_num(landing_analysis.physical_fpm)
        elseif landing_analysis.vvi_fpm_valid
            and vvi_agl_distance <= max_agl_difference then
            landing_analysis.fpm_selection_reason = "VVI_CLOSEST"
            landing_analysis.fpm_method = "VVI 最接近 AGL，采用 VVI 值"
            landing_analysis.flare_fpm_source = "VVI"
            landing_fpm = round_num(landing_analysis.vvi_fpm)
        else
            landing_analysis.fpm_selection_reason = "AGL_ANCHOR"
            if landing_analysis.physical_fpm_valid and landing_analysis.vvi_fpm_valid then
                landing_analysis.fpm_method = string.format(log_tools.ui_text(
                    "物理 FPM 与 VVI 均偏离 AGL 超过%d fpm，采用 AGL 几何下降率",
                    "Physical FPM and VVI both differ from AGL by more than %d fpm; AGL geometric vertical speed selected"
                ), max_agl_difference)
            elseif landing_analysis.physical_fpm_valid or landing_analysis.vvi_fpm_valid then
                landing_analysis.fpm_method = string.format(log_tools.ui_text(
                    "有效候选值偏离 AGL 超过%d fpm，采用 AGL 几何下降率",
                    "Available candidates differ from AGL by more than %d fpm; AGL geometric vertical speed selected"
                ), max_agl_difference)
            else
                landing_analysis.fpm_method = "物理与 VVI 样本不足，采用 AGL 几何下降率"
            end
            landing_analysis.flare_fpm_source = "AGL"
            landing_fpm = round_num(landing_analysis.agl_fpm)
        end
    elseif landing_analysis.physical_fpm_valid then
        landing_analysis.fpm_selection_reason = "PHYSICAL_FALLBACK"
        landing_analysis.fpm_method = "AGL 几何样本不足，采用物理 FPM 备用值"
        landing_analysis.flare_fpm_source = "PHYSICAL"
        landing_fpm = round_num(landing_analysis.physical_fpm)
    elseif landing_analysis.vvi_fpm_valid then
        landing_analysis.fpm_selection_reason = "VVI_FALLBACK"
        landing_analysis.fpm_method = "AGL 与物理样本不足，采用 VVI 备用值"
        landing_analysis.flare_fpm_source = "VVI"
        landing_fpm = round_num(landing_analysis.vvi_fpm)
    else
        landing_analysis.fpm_selection_reason = "VVI_LAST_RESORT"
        landing_analysis.fpm_method = "三条下降率样本均不足，采用瞬时 VVI 最终备用值"
        landing_analysis.flare_fpm_source = "VVI"
        landing_fpm = round_num(landing_analysis.vvi_fpm)
    end

    landing_analysis.fpm_difference = landing_analysis.physical_fpm_valid
        and landing_analysis.physical_fpm - landing_analysis.vvi_fpm or 0
    landing_analysis.agl_physical_difference = landing_analysis.physical_fpm_valid
        and landing_analysis.agl_fpm_valid
        and landing_analysis.physical_fpm - landing_analysis.agl_fpm or 0
    landing_analysis.agl_vvi_difference = landing_analysis.agl_fpm_valid
        and landing_analysis.vvi_fpm - landing_analysis.agl_fpm or 0
    landing_analysis.fpm_max_pair_difference = math.max(
        abs_value(landing_analysis.fpm_difference),
        abs_value(landing_analysis.agl_physical_difference),
        abs_value(landing_analysis.agl_vvi_difference)
    )
    -- G 冲量复核与 FPM 使用同一条最终采用的接地前速度，避免两条主链口径分叉。
    if landing_analysis.flare_fpm_source == "AGL" then
        landing_analysis.pre_vy_mps = landing_analysis.agl_fpm * 0.00508
    elseif landing_analysis.flare_fpm_source == "VVI" then
        landing_analysis.pre_vy_mps = landing_analysis.vvi_fpm * 0.00508
    elseif contact_count >= 3 and contact_physical_vy ~= nil then
        landing_analysis.pre_vy_mps = contact_physical_vy
    elseif fallback_physical_count >= 3 and fallback_physical_vy ~= nil then
        landing_analysis.pre_vy_mps = fallback_physical_vy
    else
        landing_analysis.pre_vy_mps = landing_analysis.vvi_fpm * 0.00508
    end


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

-- 只计算第一次接触后的固定 160 ms 稳健载荷，不再在完整压缩区间内滑动寻找最大窗口。
-- 固定窗口避免“搜索越久越容易挑到更大值”的系统性上偏。
function log_tools.calculate_local_event_g(start_time, end_time)
    local window_end = math.min(end_time, start_time + landing_analysis.g_local_event.window_seconds)
    local count = collect_sample_values(start_time, window_end, "projected_g", false)
    local event_g = count >= landing_analysis.g_local_event.min_samples
        and scratch_percentile(landing_analysis.g_local_event.percentile) or nil
    local first_valid_time = nil
    local last_valid_time = nil
    for i = 1, sample_buffer.count do
        local sample = sample_at(i)
        if sample.t >= start_time and sample.t <= window_end
            and projected_vertical_g(sample) ~= nil then
            if first_valid_time == nil then first_valid_time = sample.t end
            last_valid_time = sample.t
        end
    end
    local span = first_valid_time ~= nil and last_valid_time - first_valid_time or 0
    if span < landing_analysis.g_local_event.min_span_seconds then event_g = nil end

    landing_analysis.local_event_g_valid = event_g ~= nil
    landing_analysis.local_event_g = event_g or landing_analysis.curve_g
    landing_analysis.local_event_window_start_time = first_valid_time or start_time
    landing_analysis.local_event_window_end_time = last_valid_time or window_end
    landing_analysis.local_event_window_span_seconds = span
    landing_analysis.local_event_sample_count = count
    landing_analysis.local_event_percentile_index = event_g ~= nil
        and math.max(1, math.ceil(count * landing_analysis.g_local_event.percentile)) or 0
    landing_analysis.robust_event_g = landing_analysis.local_event_g
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
    -- 主 G 窗口严格从首个接地帧开始；impact_start_time 仅为冲量积分保留上一离地帧。
    log_tools.calculate_local_event_g(landing_analysis.touch_time, end_time)

    local high_threshold = 1.0 + math.max(0, peak_g - 1.0) * 0.80
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
                        -- g_nrml 是总载荷倍数；垂直速度变化对应净加速度 (G - 1.0)g。
                        -- 接地前基线只描述当时的升力状态，不能代替物理零点 1.0 G。
                        local previous_excess = previous_g - 1.0
                        local current_excess = current_g - 1.0
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

    local equivalent_g = 1.0
        + landing_analysis.velocity_delta_mps
            / (9.80665 * landing_analysis.stop_duration_seconds)
    landing_analysis.equivalent_g = math.max(1.0, math.min(5.0, equivalent_g))

    local samples_valid = impact_count >= 3
        and max_gap <= MAX_VALID_SAMPLE_GAP_SECONDS

    if not samples_valid then
        landing_analysis.confidence = "LOW"
        landing_analysis.used_fallback = true
        landing_analysis.method = "G样本不足，采用最终FPM上限保护后的全段P75备用值"
        landing_g = math.min(landing_analysis.curve_g, fallback_g_cap(landing_fpm))
    else
        if landing_analysis.consistency_error <= CONSISTENCY_HIGH_MAX_ERROR then
            landing_analysis.confidence = "HIGH"
        elseif landing_analysis.consistency_error <= CONSISTENCY_MEDIUM_MAX_ERROR then
            landing_analysis.confidence = "MEDIUM"
        else
            landing_analysis.confidence = "LOW"
        end
        landing_analysis.used_fallback = false
        landing_analysis.method = landing_analysis.local_event_g_valid
            and "采用第一次接触后固定160 ms稳健P75 G；冲量仅用于物理闭合复核"
            or "固定160 ms样本不足，采用第一次压缩全段P75 G"
        landing_g = landing_analysis.robust_event_g
        if landing_analysis.consistency_error > CONSISTENCY_MEDIUM_MAX_ERROR then
            landing_analysis.method = landing_analysis.method .. "；冲量闭合偏差较大，报告保留复核提示"
        end
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
    -- 此标签仅用于 ImGui 设置窗口，因此始终使用英文。
    for i = 1, #POSITION_OPTIONS do
        if POSITION_OPTIONS[i].id == position_id then return POSITION_OPTIONS[i].label end
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
    file:write("# document_language: zh or en; controls TXT text and _CN / _EN filename suffix\n")
    file:write("popup_mode=" .. POPUP_MODE .. "\n")
    file:write("document_language=" .. runtime_state.document_language .. "\n")
    file:write("display_seconds=" .. tostring(DISPLAY_SECONDS) .. "\n")
    file:write("popup_position=" .. POPUP_POSITION .. "\n")
    file:write("popup_layout=" .. POPUP_LAYOUT .. "\n")
    file:write("panel_opacity=" .. tostring(PANEL_OPACITY_LEVEL) .. "\n")
    file:write("detailed_math_log=" .. tostring(DETAILED_MATH_LOG) .. "\n")
    file:write("runway_detection_enabled=" .. tostring(runtime_state.runway_detection_enabled) .. "\n")
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
    local runway_detection_key_found = false
    for line in file:lines() do
        local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if key == "popup_mode" then
            if value == "touchdown" then
                POPUP_MODE = "immediate"
                migrated = true
            elseif value == "immediate" or value == "taxi"
                or value == "stopped" or value == "off" or value == "clean" then
                POPUP_MODE = value
            end
        elseif key == "document_language" and (value == "zh" or value == "en") then
            runtime_state.document_language = value
        elseif key == "interface_language" and (value == "zh" or value == "en") then
            -- 兼容 v1.1.1 早期测试版：读取旧键后立即迁移为 document_language。
            runtime_state.document_language = value
            migrated = true
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
        elseif key == "runway_detection_enabled" then
            runtime_state.runway_detection_enabled = value == "true"
            runway_detection_key_found = true
        elseif key == "debug_mode" then
            DEBUG_MODE = value == "true"
        end
    end
    file:close()
    if not detailed_math_key_found then migrated = true end
    if not runway_detection_key_found then migrated = true end
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
        log_manager_state.scan_error = log_tools.settings_text("无法扫描 LMM_Log，请检查 FlyWithLua 文件权限。", "Unable to scan LMM_Log. Check FlyWithLua file permissions.")
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
        local lower_line = string.lower(line)
        if line:find("聚合轨迹表", 1, true)
            or lower_line:find("aggregated trajectory table", 1, true) then
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

function log_tools.parse_roll_degrees(value)
    local degrees = log_tools.parse_number(value)
    if degrees == nil then return nil end
    local lower_value = string.lower(tostring(value))
    if tostring(value):find("左倾", 1, true) or lower_value:find("left bank", 1, true) then return -abs_value(degrees) end
    if tostring(value):find("右倾", 1, true) or lower_value:find("right bank", 1, true) then return abs_value(degrees) end
    return degrees
end

function log_tools.parse_landing_report(file_name, content)
    content = content:gsub("^\239\187\191", "")
    local fields = log_tools.parse_report_fields(content)
    local file_airport, file_aircraft, file_runway = log_tools.report_filename_identity(file_name)

    local evaluation = log_tools.first_report_field(fields, { "最终评价", "落地评价", "Final rating", "Landing rating" })
    local fpm_text = log_tools.first_report_field(fields, { "触地垂直速度", "触地下降率", "Touchdown vertical speed" })
    local g_text = log_tools.first_report_field(fields, { "最终过载", "最终显示和评分值", "Final load", "Final displayed and rated G" })
    local ias_gs_text = log_tools.first_report_field(fields, { "IAS / GS" })
    local ias = log_tools.parse_number(log_tools.first_report_field(fields, { "指示空速（IAS）", "Indicated airspeed (IAS)" }))
    local gs = log_tools.parse_number(log_tools.first_report_field(fields, { "地速（GS）", "Ground speed (GS)" }))
    if ias_gs_text ~= "" then
        local first, second = ias_gs_text:match(
            "([%+%-]?%d+%.?%d*)%s*/%s*([%+%-]?%d+%.?%d*)"
        )
        ias = tonumber(first) or ias
        gs = tonumber(second) or gs
    end

    local airport_text = log_tools.first_report_field(fields, { "落地机场", "Landing airport" })
    local airport = airport_text:match("^([%w]+)") or file_airport
    local lower_airport_text = string.lower(airport_text)
    if airport == "" or airport_text:find("未能识别", 1, true)
        or lower_airport_text:find("unable to identify", 1, true)
        or lower_airport_text:find("unknown", 1, true) then airport = "UNKNOWN" end
    local aircraft = log_tools.first_report_field(fields, { "机型（ICAO）", "Aircraft (ICAO)" })
    if aircraft == "" then aircraft = file_aircraft end
    if aircraft == "" then aircraft = "UNKNOWN" end
    local runway_text = log_tools.first_report_field(fields, { "触地跑道方向", "Touchdown runway", "Estimated runway", "Touchdown runway direction" })
    local runway = runway_text:match("RWY([%w]+)") or file_runway
    if runway == "" then runway = "--" end
    local heading_text = log_tools.first_report_field(fields, { "飞机磁航向", "Aircraft magnetic heading" })
    local wind_source_text = log_tools.first_report_field(fields, { "风向和风速", "Wind direction and speed" })
    local aoa_text = log_tools.first_report_field(fields, { "迎角", "Angle of attack" })
    local roll_text = log_tools.first_report_field(fields, { "横滚角", "Roll angle" })
    local airport_distance_text = log_tools.first_report_field(fields, { "触地点距机场参考点", "Touchdown distance from airport reference" })
    local runway_length_text = log_tools.first_report_field(
        fields,
        { "跑道长度", "跑道可用长度", "Runway length", "Runway available length" }
    )
    local touchdown_from_threshold_text = log_tools.first_report_field(
        fields,
        { "触地点距跑道入口", "触地点距入口", "Touchdown distance from runway threshold", "Touchdown distance from threshold" }
    )
    local wind_from_deg, wind_speed_kts = wind_source_text:match(
        "来自%s*([%+%-]?%d+%.?%d*)%s*deg[^%d]+([%+%-]?%d+%.?%d*)%s*kt"
    )
    if wind_from_deg == nil then
        wind_from_deg, wind_speed_kts = wind_source_text:match(
            "from%s*([%+%-]?%d+%.?%d*)%s*deg[^%d]+([%+%-]?%d+%.?%d*)%s*kt"
        )
    end

    local version = content:match("StarLux.-v(%d+%.%d+%.?%d*)")
    local legacy = version == nil
    version = version or "Legacy"

    local report = {
        file_name = file_name,
        raw = content,
        fields = fields,
        version = version,
        legacy = legacy,
        timestamp = log_tools.first_report_field(fields, { "落地时间（本地时间）", "Landing time (local)" }),
        evaluation = evaluation ~= "" and evaluation or "未提供",
        explanation = log_tools.first_report_field(fields, { "评价说明", "Rating explanation" }),
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
        tas_text = log_tools.first_report_field(fields, { "真空速（TAS）", "True airspeed (TAS)" }),
        aoa_text = aoa_text,
        aoa_deg = log_tools.parse_number(aoa_text),
        roll_text = roll_text,
        roll_deg = log_tools.parse_roll_degrees(roll_text),
        heading_text = heading_text,
        heading_deg = log_tools.parse_number(heading_text),
        wind_text = log_tools.first_report_field(fields, { "相对风", "Relative wind" }),
        wind_source_text = wind_source_text,
        wind_from_deg = tonumber(wind_from_deg),
        wind_speed_kts = tonumber(wind_speed_kts),
        airport_distance_text = airport_distance_text,
        airport_distance_km = log_tools.parse_number(airport_distance_text),
        runway_length_text = runway_length_text,
        runway_length_m = log_tools.parse_number(runway_length_text),
        touchdown_from_threshold_text = touchdown_from_threshold_text,
        touchdown_from_threshold_m = log_tools.parse_number(touchdown_from_threshold_text),
        surface_text = log_tools.first_report_field(fields, { "道面提示", "Surface advisory" }),
        surface_source = log_tools.first_report_field(fields, { "道面判定来源", "Surface determination source" }),
        bounce_text = log_tools.first_report_field(fields, { "弹跳检测", "Bounce detection" }),
        flare_metric_text = log_tools.first_report_field(fields, { "拉平曲率", "Flare curvature" }),
        flare_metric = log_tools.parse_number(log_tools.first_report_field(fields, { "拉平曲率" })),
        flare_trend = log_tools.first_report_field(fields, { "拉平轨迹结论", "轨迹结论", "Flare trajectory conclusion", "Trajectory conclusion" }),
        flare_duration = log_tools.first_report_field(fields, { "100 ft 至触地时间", "100 ft to touchdown time" }),
        flare_entry = log_tools.first_report_field(fields, { "100 ft 附近下降率", "Vertical speed near 100 ft" }),
        flare_recovery = log_tools.first_report_field(fields, { "下降率净改善量", "Net vertical-speed improvement" }),
        reversal_count = log_tools.first_report_field(fields, { "明显方向反转次数", "Significant direction reversals" }),
        worsening_ratio = log_tools.first_report_field(fields, { "下降率恶化区间比例", "Worsening-interval ratio" }),
        monotonic_efficiency = log_tools.first_report_field(fields, { "单调改善效率", "Monotonic improvement efficiency" }),
        touch_g = log_tools.parse_number(log_tools.first_report_field(fields, { "触地帧过载", "Touchdown-frame load" })),
        peak_g = log_tools.parse_number(log_tools.first_report_field(fields, { "第一次压缩原始峰值", "短窗口原始峰值", "First-compression raw peak", "Short-window raw peak" })),
        curve_g = log_tools.parse_number(log_tools.first_report_field(fields, { "接地后固定 160 ms 稳健 G", "第75百分位曲线 G", "稳健采样值", "Fixed 160 ms robust G after touchdown", "Global P75 curve G", "Robust sampled G" })),
        baseline_g = log_tools.parse_number(log_tools.first_report_field(fields, { "接地前垂直 G 基线", "Pre-touchdown vertical-G baseline" })),
        equivalent_g = log_tools.parse_number(log_tools.first_report_field(fields, { "物理平均 G", "冲量等效 G", "FPM/G 一致性上限", "Physics-average G", "Impulse-equivalent G", "FPM/G consistency cap" })),
        consistency_text = log_tools.first_report_field(fields, { "G 冲量闭合误差", "冲量一致性误差", "G impulse-closure error", "Impulse consistency error" }),
        confidence_text = log_tools.first_report_field(fields, { "数据可信度", "Data confidence" }),
        g_method = log_tools.first_report_field(fields, { "最终 G 采用方式", "Final G method" }),
        impact_samples = log_tools.first_report_field(fields, { "G 有效样本数", "冲击阶段有效样本数", "Valid G samples", "Valid impact samples" }),
        analysis_ms = log_tools.first_report_field(fields, { "落地分析耗时", "Landing analysis time" }),
        trajectory = log_tools.parse_flare_trajectory(content)
    }
    return report
end

function log_tools.status_visuals(status)
    if status == "UNSTABLE" then return "#B51E2E", "UNSTABLE 不良落地" end
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
        return "旧版记录保留当时的评分结论，不使用 1.1 阈值重新评级。"
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

-- 将字符串安全写入 JavaScript 字面量；日志始终保留为本地数据，不经过网络。
function log_tools.js_string(value)
    local escaped = tostring(value or "")
    escaped = escaped:gsub("\\", "\\\\")
    escaped = escaped:gsub('"', '\\"')
    escaped = escaped:gsub("[%z\1-\31]", function(char)
        return string.format("\\u%04X", string.byte(char))
    end)
    escaped = escaped:gsub("\226\128\168", "\\u2028")
    escaped = escaped:gsub("\226\128\169", "\\u2029")
    return '"' .. escaped .. '"'
end

-- 插件内阅读器与独立阅读器共用同一份 HTML 模板。
-- Lua 只生成一次性的本地数据桥接文件，从而避免两套界面长期分叉。
function log_tools.write_viewer_html(report)
    local template_file, template_error = io.open(REPORT_READER_TEMPLATE_PATH, "rb")
    if template_file == nil then
        return false,
            "Missing LMM_Report_Reader.html next to the Lua script: "
            .. tostring(template_error)
    end
    local template_html = template_file:read("*a")
    template_file:close()
    if template_html == nil or template_html == "" then
        return false, "LMM_Report_Reader.html is empty."
    end

    local bridge_marker = "<!-- LMM_LUA_BRIDGE -->"
    local marker_start, marker_end = template_html:find(bridge_marker, 1, true)
    if marker_start == nil then
        return false, "LMM_Report_Reader.html is incompatible: bridge marker not found."
    end
    local viewer_html = template_html:sub(1, marker_start - 1)
        .. '<script src="LMM_Viewer_Data.js"></script>'
        .. template_html:sub(marker_end + 1)

    local data_file, data_error = io.open(LOG_VIEWER_DATA_FILE_PATH, "wb")
    if data_file == nil then return false, tostring(data_error) end
    data_file:write("window.LMM_DEFAULT_LANGUAGE = " .. log_tools.js_string(runtime_state.document_language) .. ";\n")
    data_file:write("window.LMM_LAUNCH_REPORT = {\n")
    data_file:write("  name: " .. log_tools.js_string(report.file_name) .. ",\n")
    data_file:write("  content: " .. log_tools.js_string(report.raw) .. ",\n")
    data_file:write("  lastModified: " .. tostring(os.time() * 1000) .. "\n")
    data_file:write("};\n")
    local data_close_ok, data_close_error = data_file:close()
    if data_close_ok == nil then return false, tostring(data_close_error) end

    local viewer_file, viewer_error = io.open(LOG_VIEWER_FILE_PATH, "wb")
    if viewer_file == nil then return false, tostring(viewer_error) end
    viewer_file:write(viewer_html)
    local viewer_close_ok, viewer_close_error = viewer_file:close()
    if viewer_close_ok == nil then return false, tostring(viewer_close_error) end
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
    local explanations = {}
    if landing_context.centerline_penalty_applied then
        if landing_context.centerline_penalty_level == "unstable" then
            explanations[#explanations + 1] = string.format(
                "偏离中心线 %.1f 米，超过 15 米，直接判定为 %s",
                landing_context.centerline_offset_m,
                status_short(status)
            )
        elseif landing_context.centerline_original_status ~= status then
            explanations[#explanations + 1] = string.format("偏离中心线 %.1f 米，超过 7 米，评价由 ", landing_context.centerline_offset_m)
                .. status_short(landing_context.centerline_original_status)
                .. " 降级为 "
                .. status_short(status)
        else
            explanations[#explanations + 1] = string.format("偏离中心线 %.1f 米，超过 7 米，保持 ", landing_context.centerline_offset_m)
                .. status_short(status)
        end
    end
    if bounce_state.score_applied and bounce_state.original_status ~= bounce_state.result_status then
        if bounce_state.result_status == "UNSTABLE" then
            explanations[#explanations + 1] = "发生弹跳，且至少一次稳健过载超过 1.80 G"
        else
            explanations[#explanations + 1] = "发生弹跳：评级由 "
                .. status_short(bounce_state.original_status)
                .. " 降级为 "
                .. status_short(bounce_state.result_status)
        end
    end
    if #explanations > 0 then return table.concat(explanations, " / ") end
    if status == "UNSTABLE" then
        return "不良落地：下降率超过 300 fpm，或过载超过 1.80 G"
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
        return log_tools.ui_text("水平（0.0 deg）", "Level (0.0 deg)")
    elseif roll_deg < 0 then
        return string.format(log_tools.ui_text("左倾 %.1f deg", "Left bank %.1f deg"), abs_roll)
    end
    return string.format(log_tools.ui_text("右倾 %.1f deg", "Right bank %.1f deg"), abs_roll)
end

local function vertical_speed_log_text(fpm)
    if fpm <= 0 then
        return string.format(log_tools.ui_text("%d fpm（向下 %d fpm）", "%d fpm (down %d fpm)"), fpm, abs_value(fpm))
    end
    return string.format(log_tools.ui_text("+%d fpm（向上）", "+%d fpm (up)"), fpm)
end

local function fpm_source_log_text()
    if landing_analysis.flare_fpm_source == "PHYSICAL" then
        if landing_analysis.fpm_selection_reason == "PHYSICAL_CLOSEST" then
            return log_tools.ui_text(
                "物理 FPM（最接近 AGL）",
                "Physical FPM (closest to AGL)"
            )
        end
        return log_tools.ui_text("物理 FPM（AGL 缺样备用）", "Physical FPM (AGL-sample fallback)")
    elseif landing_analysis.flare_fpm_source == "AGL" then
        return log_tools.ui_text(
            "AGL 几何锚点下降率",
            "AGL geometric anchor vertical speed"
        )
    elseif landing_analysis.fpm_selection_reason == "VVI_CLOSEST" then
        return log_tools.ui_text("VVI（最接近 AGL）", "VVI (closest to AGL)")
    end
    return log_tools.ui_text("VVI（AGL 与物理样本缺失备用）", "VVI (AGL and physical samples unavailable)")
end

local function position_log_label(position_id)
    local labels_zh = {
        top_left = "左上", top_center = "上方居中", top_right = "右上",
        middle_left = "左侧居中", center = "屏幕中央", middle_right = "右侧居中",
        bottom_left = "左下", bottom_center = "下方居中", bottom_right = "右下"
    }
    local labels_en = {
        top_left = "Top left", top_center = "Top center", top_right = "Top right",
        middle_left = "Middle left", center = "Center", middle_right = "Middle right",
        bottom_left = "Bottom left", bottom_center = "Bottom center", bottom_right = "Bottom right"
    }
    local labels = runtime_state.document_language == "en" and labels_en or labels_zh
    return labels[position_id] or labels.middle_left
end

function log_tools.popup_mode_log_text()
    if POPUP_MODE == "immediate" then return log_tools.ui_text("分析完成后立即显示", "Show immediately after analysis") end
    if POPUP_MODE == "taxi" then return log_tools.ui_text("地速低于 30 kt 时显示", "Show after slowing below 30 kt") end
    if POPUP_MODE == "stopped" then return log_tools.ui_text("飞机停稳并持续 10 秒后显示", "Show after stopped for 10 seconds") end
    if POPUP_MODE == "clean" then return log_tools.ui_text("纯净模式（关闭全部自动提示）", "Clean mode (disable all automatic notices)") end
    return log_tools.ui_text("不自动显示", "Do not show automatically")
end

-- TXT 报告在落盘时统一翻译；数值精度、排序与公式不因语言改变。
log_tools.report_translations = {
    { "采用第一次接触后固定160 ms稳健P75 G；冲量仅用于物理闭合复核；冲量闭合偏差较大，报告保留复核提示", "Fixed 160 ms robust P75 G after first contact selected; impulse is used only for physical closure review; closure deviation is large and retained for review" },
    { "采用第一次接触后固定160 ms稳健P75 G；冲量仅用于物理闭合复核", "Fixed 160 ms robust P75 G after first contact selected; impulse is used only for physical closure review" },
    { "接地短窗样本不足，采用5 ft以下250 ms物理速度P25备用值；AGL几何复核差异较大，已保留复核值", "Touchdown-window samples are insufficient; the 250 ms physical-velocity P25 below 5 ft is used as fallback; the AGL geometric cross-check differs substantially and is retained" },
    { "采用接地前100 ms离地物理垂直速度中位数；AGL几何复核差异较大，已保留复核值", "Median airborne physical vertical speed in the 100 ms before touchdown selected; the AGL geometric cross-check differs substantially and is retained" },
    { "采用接地前100 ms离地物理垂直速度中位数", "Median airborne physical vertical speed in the 100 ms before touchdown selected" },
    { "接地短窗样本不足，采用5 ft以下250 ms物理速度P25备用值", "Touchdown-window samples are insufficient; the 250 ms physical-velocity P25 below 5 ft is used as fallback" },
    { "物理短窗出现向上符号，但AGL与VVI均确认仍在下降，采用AGL几何下降率", "The physical touchdown window indicates an upward direction while both AGL and VVI confirm descent; AGL geometric vertical speed selected" },
    { "物理短窗比AGL与VVI均偏轻至少100 fpm，采用AGL几何下降率", "The physical touchdown window is at least 100 fpm lighter than both AGL and VVI; AGL geometric vertical speed selected" },
    { "物理速度样本不足，采用5 ft以下AGL几何下降率备用值", "Physical-velocity samples are insufficient; AGL geometric vertical speed below 5 ft is used as fallback" },
    { "物理与几何样本均不足，采用VVI最终备用值", "Physical and geometric samples are insufficient; VVI is used as the final fallback" },
    { "物理 FPM 最接近 AGL，采用接地前100 ms物理值", "Physical FPM is closest to AGL; the 100 ms pre-touchdown physical value is selected" },
    { "物理 FPM 最接近 AGL，采用250 ms物理备用值", "Physical FPM is closest to AGL; the 250 ms physical fallback is selected" },
    { "VVI 最接近 AGL，采用 VVI 值", "VVI is closest to AGL; VVI selected" },
    { "物理 FPM 与 VVI 均偏离 AGL 超过100 fpm，采用 AGL 几何下降率", "Physical FPM and VVI both differ from AGL by more than 100 fpm; AGL geometric vertical speed selected" },
    { "有效候选值偏离 AGL 超过100 fpm，采用 AGL 几何下降率", "Available candidates differ from AGL by more than 100 fpm; AGL geometric vertical speed selected" },
    { "物理 FPM 与 VVI 均偏离 AGL 超过30 fpm，采用 AGL 几何下降率", "Physical FPM and VVI both differ from AGL by more than 30 fpm; AGL geometric vertical speed selected" },
    { "有效候选值偏离 AGL 超过30 fpm，采用 AGL 几何下降率", "Available candidates differ from AGL by more than 30 fpm; AGL geometric vertical speed selected" },
    { "物理与 VVI 样本不足，采用 AGL 几何下降率", "Physical and VVI samples are insufficient; AGL geometric vertical speed selected" },
    { "AGL 几何样本不足，采用物理 FPM 备用值", "AGL geometric samples are insufficient; physical FPM selected as fallback" },
    { "AGL 与物理样本不足，采用 VVI 备用值", "AGL and physical samples are insufficient; VVI selected as fallback" },
    { "三条下降率样本均不足，采用瞬时 VVI 最终备用值", "All three vertical-speed sources have insufficient samples; instantaneous VVI selected as final fallback" },
    { "G样本不足，采用最终FPM上限保护后的全段P75备用值", "G samples are insufficient; full-event P75 limited by the final-FPM cap is used as fallback" },
    { "固定160 ms样本不足，采用第一次压缩全段P75 G", "Fixed 160 ms samples are insufficient; full first-compression P75 G is used" },
    { "固定窗样本不足，采用全段P75", "fixed-window samples insufficient; full-event P75 selected" },
    { "接地前物理垂直速度", "Pre-touchdown physical vertical speed" },
    { "物理 FPM（最接近 AGL）", "Physical FPM (closest to AGL)" },
    { "物理 FPM（AGL 缺样备用）", "Physical FPM (AGL-sample fallback)" },
    { "VVI（最接近 AGL）", "VVI (closest to AGL)" },
    { "VVI（AGL 与物理样本缺失备用）", "VVI (AGL and physical samples unavailable)" },
    { "AGL 几何锚点下降率", "AGL geometric anchor vertical speed" },
    { "AGL 几何下降率（末段物理低估保护）", "AGL geometric vertical speed (terminal physical-underread guard)" },
    { "AGL 几何下降率（物理方向冲突保护）", "AGL geometric vertical speed (physical-direction conflict guard)" },
    { "AGL 几何下降率（物理样本缺失备用）", "AGL geometric vertical speed (physical-sample fallback)" },
    { "VVI（物理与几何样本缺失备用）", "VVI (physical and geometric samples unavailable)" },
    { "四、着陆数据复核", "4. Landing data review" },
    { "FPM 采用源", "FPM source" },
    { "接地前物理下降率", "Pre-touchdown physical vertical speed" },
    { "AGL 几何复核下降率", "AGL geometric cross-check vertical speed" },
    { "VVI 参考下降率", "VVI reference vertical speed" },
    { "FPM 物理/VVI有效样本", "FPM physical/VVI valid samples" },
    { "最终显示/评分 G", "Final displayed/rated G" },
    { "接地后固定 160 ms 稳健 G", "Fixed 160 ms robust G after touchdown" },
    { "物理平均 G", "Physics-average G" },
    { "G 冲量闭合误差", "G impulse-closure error" },
    { "G 复核结论", "G review result" },
    { "G 有效样本数", "Valid G samples" },
    { "采样不足，已使用备用值", "Insufficient samples; fallback used" },
    { "偏差较大，请结合原始轨迹复核", "Large deviation; review the raw trace" },
    { "通过", "Pass" },
    { "界面显示 = ", "interface display = " },
    { "窗口标记: F5=5ft以下250ms物理FPM/VVI，F80=80ms短窗，V850=850ms最差VVI，AGL=5ft以下几何高度斜率窗口，BASE=接地前G基线，IMPACT=第一次压缩，POST=压缩末端速度。", "Window flags: F5=250 ms physical FPM/VVI below 5 ft; F80=80 ms short window; V850=worst VVI over 850 ms; AGL=geometric-altitude slope window below 5 ft; BASE=pre-touchdown G baseline; IMPACT=first compression; POST=end-of-compression velocity." },
    { "规则: Nice 降为 Stable，Stable 降为 Attention；任一次稳健 G 超过 1.80 时为 UNSTABLE。", "Rule: Nice is downgraded to Stable and Stable to Attention; any robust G above 1.80 is UNSTABLE." },
    { "说明: 本节保存核心计算输入、窗口、排序、索引和公式；所有时间均以第一次触地 T=0 为基准。", "Note: this section preserves core calculation inputs, windows, sorting, indices and formulas; all times use first touchdown T=0." },
    { "UNSTABLE: FPM 或 G 超过任意 Attention 上限。", "UNSTABLE: FPM or G exceeds an Attention limit." },
    { "稳定扎实落地：下降率不超过 250 fpm，且过载不超过 1.50 G", "Solid landing: vertical speed did not exceed 250 fpm and load did not exceed 1.50 G" },
    { "长行程压缩达到采集上限，采用全局P75与160ms局部冲击包络的较大值", "Long-travel compression reached the capture limit; larger of global P75 and 160 ms local envelope selected" },
    { "FPM 与 G 分别分档，最终评价取较严重等级；拉平曲率暂不参与评分。", "FPM and G are rated independently; the more severe band is final. Flare curvature does not affect the rating." },
    { "长行程压缩达到采集上限，局部包络样本不足，采用全局第75百分位曲线G", "Long-travel compression reached the capture limit; local envelope insufficient, global P75 G selected" },
    { "轻柔接地：下降率不超过 100 fpm，且过载不超过 1.20 G", "Soft touchdown: vertical speed did not exceed 100 fpm and load did not exceed 1.20 G" },
    { "评分说明: v1.1.4 的拉平曲率仅用于复盘展示，暂不参与评分。", "Rating note: flare curvature in v1.1.4 is for review only and does not affect the rating." },
    { "需注意：下降率不超过 300 fpm，且过载不超过 1.80 G", "Review advised: vertical speed did not exceed 300 fpm and load did not exceed 1.80 G" },
    { "不良落地：下降率超过 300 fpm，或过载超过 1.80 G", "Adverse landing: vertical speed exceeded 300 fpm or load exceeded 1.80 G" },
    { " 才为高可信；任一组超过阈值立即降低可信度并由 VVI 接管。", " for high confidence; exceeding the threshold on any pair lowers confidence and hands control to VVI." },
    { "终端测量出现差异，VVI与几何轨迹相互接近，采用VVI下降率", "Terminal measurements disagree; VVI agrees with the geometric trajectory and is selected" },
    { "高下降率短窗与VVI差异超过100 fpm，采用VVI并保留全部对照值", "High-sink-rate 80 ms window and VVI differ by more than 100 fpm; VVI selected and all comparison values retained" },
    { "高下降率事件的80 ms物理样本不足，采用VVI并保留全部对照值", "High-sink-rate event has insufficient 80 ms physical samples; VVI selected and all comparison values retained" },
    { "高下降率事件采用触地前80 ms离地物理速度中位数", "High-sink-rate event uses the median airborne physical velocity in the 80 ms before touchdown" },
    { "物理轨迹（高下降率80 ms短窗复核）", "Physical trajectory (80 ms high-sink-rate review)" },
    { "显示值可能按界面位数四舍五入，复算请使用本节保留的高精度值。", "Displayed values may be rounded to interface precision; use the high-precision values retained here for recalculation." },
    { "StarLux 落地率插件 v1.1.4 - 单次落地记录", "StarLux Landing Meter v1.1.4 - Landing Report" },
    { "中可信冲量，采用全局P75与160ms局部冲击包络的较大值", "Medium-confidence impulse; larger of global P75 and 160 ms local impact envelope selected" },
    { "中可信冲量，局部包络样本不足，采用全局第75百分位曲线G", "Medium-confidence impulse; local envelope insufficient, global P75 G selected" },
    { "跑道说明: 依据 scenery_packs.ini 优先级读取 apt.dat，并用跑道端点、触地坐标和地速向量完成几何匹配；位置采用飞机参考点，数值为约值。", "Runway note: apt.dat is read in scenery_packs.ini priority order and matched using runway endpoints, touchdown coordinates and the ground-velocity vector; positions use the aircraft reference point and are approximate." },
    { "跑道说明: 未输出跑道方向和触地点；插件不会使用磁航向猜测跑道。", "Runway note: no runway direction or touchdown point is output; the plugin does not guess a runway from magnetic heading." },
    { "触地跑道方向: 未识别（未使用磁航向猜测）", "Touchdown runway: Not identified (no magnetic-heading guess used)" },
    { "（apt.dat 实测匹配）", " (apt.dat geometry match)" },
    { "（飞机参考点，约）", " (aircraft reference point, approx.)" },
    { "跑道识别来源", "Runway identification source" },
    { "跑道识别可信度", "Runway identification confidence" },
    { "跑道数据源", "Runway data source" },
    { "跑道长度", "Runway length" },
    { "跑道宽度", "Runway width" },
    { "跑道路面", "Runway surface" },
    { "触地点距跑道入口", "Touchdown distance from runway threshold" },
    { "触地点距跑道末端", "Touchdown distance from runway end" },
    { "触地点距跑道中心线", "Touchdown distance from runway centerline" },
    { "触地点中心线有符号偏差", "Signed touchdown centerline deviation" },
    { "触地点中心线方向", "Touchdown centerline side" },
    { "中心线评价", "Centerline assessment" },
    { "反向跑道方向", "Opposite runway direction" },
    { "跑道路面代码", "Runway surface code" },
    { "反向跑道标线代码", "Opposite runway marking code" },
    { "反向跑道标线类型", "Opposite runway marking type" },
    { "跑道标线代码", "Runway marking code" },
    { "跑道标线类型", "Runway marking type" },
    { "反向跑道入口内移", "Opposite displaced threshold" },
    { "跑道入口内移", "Displaced threshold" },
    { "跑道前端防吹坪", "Approach-end blast pad" },
    { "反向跑道防吹坪", "Opposite blast pad" },
    { "反向接地区灯", "Opposite touchdown-zone lights" },
    { "接地区灯", "Touchdown-zone lights" },
    { "反向跑道入口识别灯代码", "Opposite REIL code" },
    { "跑道入口识别灯代码", "REIL code" },
    { "跑道中线灯代码", "Runway centerline-light code" },
    { "跑道边灯代码", "Runway edge-light code" },
    { "跑道道肩代码", "Runway shoulder code" },
    { "无跑道标线", "No runway markings" },
    { "目视跑道标线", "Visual runway markings" },
    { "FAA 非精密进近跑道标线", "FAA non-precision runway markings" },
    { "FAA 精密进近跑道标线", "FAA precision runway markings" },
    { "英国非精密进近跑道标线", "UK non-precision runway markings" },
    { "英国精密进近跑道标线", "UK precision runway markings" },
    { "EASA/ICAO 非精密进近跑道标线", "EASA/ICAO non-precision runway markings" },
    { "EASA/ICAO 精密进近跑道标线", "EASA/ICAO precision runway markings" },
    { "未知跑道标线（代码 ", "Unknown runway markings (code " },
    { "（左正右负）", " (left positive, right negative)" },
    { "偏离中心线 ", "Centerline deviation " },
    { " 米，超过 15 米，直接判定为 ", " m; above 15 m, rated directly as " },
    { " 米，超过 7 米，评价由 ", " m; above 7 m, rating changed from " },
    { " 米，超过 7 米，保持 ", " m; above 7 m, remains " },
    { "中心线偏差未超过 7 米，不影响评分", "Centerline deviation did not exceed 7 m and does not affect the rating" },
    { "未参与评分（跑道未可靠识别）", "Not rated (runway not reliably identified)" },
    { "中心线评分修正已应用", "Centerline rating correction applied" },
    { "中心线评分修正未触发", "Centerline rating correction not triggered" },
    { "中心线评分修正未应用", "Centerline rating correction not applied" },
    { "跑道未可靠识别", "Runway not reliably identified" },
    { "；修正前 ", "; before correction " },
    { "；当前 ", "; current " },
    { " 米", " m" },
    { "精准跑道识别", "Exact runway identification" },
    { "X-Plane apt.dat 几何匹配", "X-Plane apt.dat geometry match" },
    { "用户已关闭精准跑道识别", "Exact runway identification disabled by user" },
    { "无可靠结果", "No reliable result" },
    { "沥青", "Asphalt" },
    { "混凝土", "Concrete" },
    { "草地", "Grass" },
    { "泥土", "Dirt" },
    { "碎石", "Gravel" },
    { "干湖床", "Dry lakebed" },
    { "冰雪", "Snow/ice" },
    { "透明道面", "Transparent surface" },
    { "没有满足最少样本与跨度要求的局部窗口，回退全局P75。", "No local window met the minimum sample and span requirements; falling back to global P75." },
    { "垂直速度 VVI（三项终端测量存在差异，已自动采用）", "VVI (selected because terminal measurements disagree)" },
    { "终端测量结果分散，采用VVI下降率并保留全部对照值", "Terminal measurements are dispersed; VVI selected and all comparison values retained" },
    { "终端测量样本不足，采用VVI下降率并保留全部对照值", "Insufficient terminal samples; VVI selected and all comparison values retained" },
    { "FPM与G分别分档，最终取较严重等级；基础复算结果", "FPM and G are rated separately and the more severe band is selected; base recalculated result" },
    { "|二阶变化|第75百分位，越接近0表示轨迹越平顺", "P75 of absolute second-order change; values closer to 0 indicate a smoother trajectory" },
    { "发生弹跳，且至少一次稳健过载超过 1.80 G", "Bounce detected, with at least one robust load exceeding 1.80 G" },
    { "明显反转门槛: 相邻聚合FPM变化绝对值超过 ", "Significant-reversal threshold: absolute change between adjacent aggregated FPM values exceeds " },
    { "三链阈值: 5 ft以下三组两两差值均 ≤ ", "Three-chain threshold: below 5 ft, all three pairwise differences must be <= " },
    { "三项终端测量结果一致，采用物理轨迹下降率", "Terminal measurements agree; physical-trajectory vertical speed selected" },
    { "0.5秒聚合轨迹表（高精度复算输入）", "0.5 s Aggregated Trajectory Table (High-Precision Recalculation Input)" },
    { "高可信冲量，采用第75百分位曲线G", "High-confidence impulse; global P75 G selected" },
    { "最近三分钟未确认持续降雨或湿滑道面", "No persistent rain or wet runway confirmed in the last three minutes" },
    { "250 ms 物理速度第25百分位", "250 ms physical-velocity P25" },
    { "局部包络窗口样本/跨度/P75索引", "Local-envelope window samples/span/P75 index" },
    { "第二次触地前250ms离地物理速度", "Airborne physical velocity in 250 ms before second touchdown" },
    { "物理样本不足，使用备用一致性上限", "Insufficient physical samples; consistency safety cap used" },
    { "飞机实际降水连续达到阈值，峰值 ", "Aircraft precipitation remained above the threshold; peak " },
    { "5ft以下250ms物理垂直速度", "250 ms physical vertical velocity below 5 ft" },
    { "低可信峰值，主要采用冲量等效G", "Low-confidence peak; impulse-equivalent G is weighted most heavily" },
    { "高震荡规则: 反转次数 >= ", "High-oscillation rule: reversals >= " },
    { "X-Plane 跑道摩擦等级 ", "X-Plane runway-friction level " },
    { "第三链 AGL 高度变化下降率", "Third-chain AGL-derived vertical speed" },
    { "160 ms 局部冲击包络 G", "160 ms local-impact envelope G" },
    { "物理轨迹（三项终端测量一致）", "Physical trajectory (three terminal measurements agree)" },
    { "物理主值与同窗 VVI 差值", "Physical vs windowed VVI difference" },
    { "FPM物理/VVI窗口样本数", "FPM physical/VVI window samples" },
    { "AGL验证样本/斜率对/跨度", "AGL validation samples/slope pairs/span" },
    { "5ft以下250ms VVI", "250 ms VVI below 5 ft" },
    { "压缩末端50ms物理垂直速度", "Physical Vertical Velocity in Final 50 ms of Compression" },
    { "弹跳修正规则已应用；最终结果", "Bounce adjustment applied; final result" },
    { "任一组超过阈值立即回退VVI", "any difference over the threshold immediately falls back to VVI" },
    { "附录A、第二次触地数学复算", "Appendix A. Second-Touchdown Mathematical Recalculation" },
    { "80 ms 物理速度中位数", "80 ms physical-velocity median" },
    { "0.85 s 最差 VVI", "Worst VVI over 0.85 s" },
    { "垂直速度连续三帧进入稳定区", "Vertical speed remained stable for three consecutive frames" },
    { "达到1.20秒安全采集上限", "Reached the 1.20 s safety capture limit" },
    { "5ft以下三链交叉验证复算", "Three-Chain Cross-Validation Recalculation Below 5 ft" },
    { "160ms局部冲击包络复算", "160 ms Local-Impact Envelope Recalculation" },
    { " 为高可信并采用物理FPM", " means high confidence and selects physical FPM" },
    { "二、100英尺后拉平轨迹", "II. Flare Trajectory Below 100 ft" },
    { "三、飞行、位置与环境参考", "III. Flight, Position and Environment" },
    { "100 ft 至触地时间", "100 ft to touchdown time" },
    { "100 ft 附近下降率", "Vertical speed near 100 ft" },
    { " 且（单调改善效率 < ", " and (monotonic improvement efficiency < " },
    { " 或恶化区间比例 >= ", " or worsening-interval ratio >= " },
    { "触地前三分钟实际降水峰值", "Peak precipitation in 3 minutes before touchdown" },
    { "连续达到降水阈值的采样数", "Consecutive precipitation-threshold samples" },
    { "三链终端窗口: 触地前 ", "Three-chain terminal window: " },
    { "物理FPM与AGL链差值", "Physical FPM vs AGL-chain difference" },
    { "样本不足，使用全局P75", "Insufficient samples; global P75 used" },
    { "第二次触地压缩垂直投影G", "Projected vertical G during second-touchdown compression" },
    { "850ms VVI诊断值", "850 ms VVI diagnostic value" },
    { "接地前垂直投影G基线样本", "Pre-Touchdown Projected-Vertical-G Baseline Samples" },
    { "对窗口内每一对样本计算 ", "For every sample pair in the window, compute " },
    { "四、FPM与G算法诊断", "IV. FPM and G Diagnostics" },
    { "五、评分阈值与显示设置", "V. Rating Thresholds and Display Settings" },
    { "拉平曲率: 无有效结果", "Flare curvature: no valid result" },
    { "弹跳期间峰值无线电高度", "Peak radio altitude during bounce" },
    { "持续降雨，道面可能湿滑", "Persistent rain: runway may be wet" },
    { "最终显示/评分 FPM", "Final displayed/rated FPM" },
    { "第二次触地审计是否截断", "Second-touchdown audit truncated" },
    { "选中局部窗口垂直投影G", "Selected Local-Window Projected Vertical G" },
    { "可信度与最终G分支复算", "Confidence and Final-G Branch Recalculation" },
    { "最终取各窗P75最大值", "select the maximum P75 across windows" },
    { " 个样本且跨度不少于 ", " samples spanning at least " },
    { "落地时间（本地时间）", "Landing time (local)" },
    { "落地机场: 未能识别", "Landing airport: Unable to identify" },
    { "弹跳期间最大向上速度", "Maximum upward speed during bounce" },
    { "，或反转次数 >= ", ", or reversals >= " },
    { "风向和风速: 来自 ", "Wind direction and speed: from " },
    { "X-Plane 等级", "X-Plane level" },
    { "道面湿滑，注意摩擦力", "Wet surface: reduced friction" },
    { "同窗 VVI 中位数", "Windowed VVI median" },
    { "VVI与AGL链差值", "VVI vs AGL-chain difference" },
    { "第75百分位曲线 G", "Global P75 curve G" },
    { "中可信度稳健冲击 G", "Medium-confidence robust-impact G" },
    { "接地前垂直 G 基线", "Pre-touchdown vertical-G baseline" },
    { "G 冲量推算速度变化", "G-impulse estimated velocity change" },
    { "第二次触地审计样本数", "Second-touchdown audit sample count" },
    { "80ms物理垂直速度", "80 ms physical vertical velocity" },
    { "第一次压缩垂直投影G", "Projected Vertical G During First Compression" },
    { "冲量梯形积分逐段复算", "Segment-by-Segment Trapezoidal Impulse Recalculation" },
    { "备用一致性G上限公式", "Fallback consistency-G cap formula" },
    { "未发生弹跳；最终结果", "No bounce; final result" },
    { "发生弹跳：评级由 ", "Bounce detected: rating downgraded from " },
    { "下降率恶化区间比例", "Worsening-interval ratio" },
    { "0.25秒聚合轨迹表", "0.25 s Aggregated Trajectory Table" },
    { "0.5秒聚合轨迹表", "0.5 s Aggregated Trajectory Table" },
    { "有符号平均曲率复算", "recalculated signed mean curvature" },
    { "触地点距机场参考点", "Touchdown distance from airport reference" },
    { "第一次压缩原始峰值", "First-compression raw peak" },
    { "第一次压缩结束原因", "First-compression end reason" },
    { "第一次压缩持续时间", "First-compression duration" },
    { "最终 G 采用方式", "Final G method" },
    { "冲击阶段有效样本数", "Valid impact samples" },
    { "等待100英尺采样", "Waiting for 100 ft sampling" },
    { "拉平轨迹聚合点不足", "Insufficient flare buckets" },
    { "检测到垂直速度反向", "Vertical-speed reversal detected" },
    { "第75百分位曲线G", "P75 curve G" },
    { "物理FPM样本有效", "Physical FPM samples valid" },
    { "中可信或长压缩超时", "medium confidence or long-compression timeout" },
    { "一、核心落地结果", "I. Core Landing Results" },
    { "机型（ICAO）", "Aircraft (ICAO)" },
    { "0.25秒聚合点数", "0.25 s aggregated points" },
    { "0.5秒聚合点数", "0.5 s aggregated points" },
    { "预采样原始样本数", "Raw pre-capture sample count" },
    { "轨迹接地基准校准", "Trajectory touchdown-reference calibration" },
    { "拉平轨迹缺少接地点校准后的100英尺样本", "Flare trace lacks a touchdown-calibrated 100 ft sample" },
    { "拉平轨迹校准后样本不足", "Insufficient flare samples after touchdown calibration" },
    { "（飞机参考点接地高度，已从整段轨迹扣除）", " (aircraft-reference touchdown height, subtracted from the full trajectory)" },
    { "是否达到容量上限", "Capacity limit reached" },
    { "明显方向反转次数", "Significant direction reversals" },
    { "拉平曲率逐段复算", "Segment-by-Segment Flare-Curvature Recalculation" },
    { "真空速（TAS）", "True airspeed (TAS)" },
    { "、AGL不高于 ", " before touchdown; AGL no higher than " },
    { "三链最大两两差值", "Maximum pairwise three-chain difference" },
    { "高 G 持续时间", "High-G duration" },
    { "实际垂直速度变化", "Actual vertical-velocity change" },
    { "是否启用备用算法", "Fallback algorithm used" },
    { "完整数学复算附录", "Full mathematical audit appendix" },
    { "拉平轨迹样本不足", "Insufficient flare samples" },
    { "下降率轨迹震荡高", "High vertical-speed oscillation" },
    { "触地绝对模拟时间", "Absolute touchdown simulation time" },
    { "审计快照是否截断", "Audit snapshot truncated" },
    { "压缩前短窗中位数", "Pre-compression short-window median" },
    { "高G持续时间复算", "Recalculated high-G duration" },
    { "平均样本间隔复算", "Recalculated average sample interval" },
    { "最大样本间隔复算", "recalculated maximum sample interval" },
    { "算法保存最大间隔", "stored maximum interval" },
    { "备用一致性G上限", "fallback consistency-G cap" },
    { "所有分支最终执行", "All branches finally apply" },
    { "规则: 滑窗长度", "Rule: sliding-window length" },
    { "六、数学复算区", "VI. Mathematical Recalculation" },
    { "下降率取值说明", "Vertical-speed source rationale" },
    { "弹跳与两次触地", "Bounce and Two Touchdowns" },
    { "轨迹下降率取值", "Trajectory vertical-speed source" },
    { "下降率净改善量", "Net vertical-speed improvement" },
    { "有符号平均曲率", "Signed mean curvature" },
    { "冲量一致性误差", "Impulse consistency error" },
    { "背景透明度档位", "Background opacity level" },
    { "下降率轨迹正常", "Vertical-speed trend normal" },
    { "垂直投影G公式", "Projected-vertical-G formula" },
    { "第一次压缩起点", "First-compression start" },
    { "第一次压缩终点", "First-compression end" },
    { "第一次压缩时长", "First-compression duration" },
    { "审计快照样本数", "Audit snapshot sample count" },
    { "投影G样本峰值", "Projected-G sample peak" },
    { "算法保存曲线G", "stored curve G" },
    { "最终G高精度值", "final high-precision G" },
    { "excess前", "excess-before" },
    { "excess后", "excess-after" },
    { "仅使用离地且 ", "use airborne samples with " },
    { "触地垂直速度", "Touchdown vertical speed" },
    { "拉平轨迹结论", "Flare trajectory conclusion" },
    { "未检测到弹跳", "No bounce detected" },
    { "触地跑道方向", "Touchdown runway" },
    { "两次触地间隔", "Touchdown interval" },
    { "确认离地时间", "Confirmed airborne time" },
    { "原始采样频率", "Raw sampling rate" },
    { "单调改善效率", "Monotonic improvement efficiency" },
    { "末段改善占比", "Late-recovery ratio" },
    { "曲率分析耗时", "Curvature analysis time" },
    { "拉平曲率复算", "recalculated flare curvature" },
    { "跑道摩擦状态", "Runway friction state" },
    { "道面判定来源", "Surface determination source" },
    { "冲量等效 G", "Impulse-equivalent G" },
    { "平均采样间隔", "Average sample interval" },
    { "最大采样间隔", "Maximum sample interval" },
    { "落地分析耗时", "Landing analysis time" },
    { "最终评分耗时", "Final rating time" },
    { "逐样本审计表", "Per-Sample Audit Table" },
    { "弹跳评分比较", "Bounce rating comparison" },
    { "第一次稳健G", "first robust G" },
    { "第二次稳健G", "second robust G" },
    { "VVI中位数", "VVI median" },
    { "压缩后中位数", "post-compression median" },
    { "实际速度变化", "Actual velocity change" },
    { "触地帧原始G", "raw touchdown-frame G" },
    { "样本总体有效", "Samples valid overall" },
    { "最终采用方式", "Final method" },
    { "当前等级余量", "current-band margin" },
    { "外部评分提示", "External rating hint" },
    { "（升序，n=", " (ascending, n=" },
    { "显示四舍五入", "rounded display" },
    { "最小实际跨度", "minimum actual span" },
    { "三组差值全部", "all three differences " },
    { "最大样本间隔", "Maximum sample interval" },
    { " 降级为 ", " to " },
    { "下降率取值", "Vertical-speed source" },
    { "第一次触地", "First touchdown" },
    { "第二次触地", "Second touchdown" },
    { "弹跳前评价", "Rating before bounce adjustment" },
    { "弹跳后评价", "Rating after bounce adjustment" },
    { "原始样本数", "Raw sample count" },
    { "触地下降率", "Touchdown vertical speed" },
    { "轨迹FPM", "TrajectoryFPM" },
    { "物理FPM", "PhysicalFPM" },
    { "曲率绝对值", "Absolute curvature" },
    { "飞机磁航向", "Aircraft magnetic heading" },
    { "触地帧过载", "Touchdown-frame load" },
    { "数据可信度", "Data confidence" },
    { "短窗中位数", "Short-window median" },
    { "最差VVI", "Worst VVI" },
    { "基线中位数", "Baseline median" },
    { "稳健冲击G", "Robust impact G" },
    { "一致性误差", "Consistency error" },
    { "冲量等效G", "Impulse-equivalent G" },
    { "高可信条件", "High-confidence condition" },
    { "中可信条件", "Medium-confidence condition" },
    { "无有效样本", "No valid samples" },
    { "P25索引", "P25 index" },
    { "P75索引", "P75 index" },
    { "算法保存值", "stored algorithm value" },
    { "升序第1项", "ascending item 1" },
    { "最终FPM", "final FPM" },
    { "且高G持续", "and high-G duration" },
    { "显示 = ", "display = " },
    { "算法保存G", "stored G" },
    { "触地前快照", "pre-touchdown snapshot" },
    { "全局P75", "global P75" },
    { "冲击样本数", "Impact sample count" },
    { "最终评价", "Final rating" },
    { "评价说明", "Rating explanation" },
    { "最终过载", "Final load" },
    { "拉平曲率", "Flare curvature" },
    { "弹跳检测", "Bounce detection" },
    { "发生弹跳", "Bounce detected" },
    { "落地机场", "Landing airport" },
    { "（推算）", " (estimated)" },
    { "道面提示", "Surface advisory" },
    { "轨迹结论", "Trajectory conclusion" },
    { "终点序号", "EndIndex" },
    { "飞机文件", "Aircraft file" },
    { "弹窗时机", "Popup timing" },
    { "显示时长", "Display duration" },
    { "屏幕位置", "Screen position" },
    { "窗口布局", "Window layout" },
    { "红色阈值", "red threshold" },
    { "算法峰值", "Algorithm peak" },
    { "高G阈值", "High-G threshold" },
    { "冲量公式", "Impulse formula" },
    { "本次余量", "This margin" },
    { "样本无效", "Invalid samples" },
    { "备用上限", "fallback cap" },
    { "界面显示", "interface display" },
    { "评分复算", "Rating Recalculation" },
    { "窗口标记", "WindowFlags" },
    { "选中窗口", "Selected window" },
    { "样本不足", "Insufficient samples" },
    { "两两差值", "Pairwise differences" },
    { "最大差值", "maximum difference" },
    { "最终来源", "final source" },
    { "局部包络", "local envelope" },
    { "左前侧风", "left-front crosswind" },
    { "右前侧风", "right-front crosswind" },
    { "左后侧风", "left-rear crosswind" },
    { "右后侧风", "right-rear crosswind" },
    { " 的样本", " samples" },
    { "仅保留 ", "retain only " },
    { "滑窗长度", "sliding-window length" },
    { "每窗取P", "take P" },
    { "算法保存", "stored" },
    { "压缩时长", "compression duration" },
    { "触地帧 ", "touchdown frame " },
    { "原始峰值", "raw peak" },
    { "无法确认", "unable to confirm" },
    { "最少样本", "minimum samples" },
    { "相对风", "Relative wind" },
    { "T+秒", "T+s" },
    { "轨迹高度基准", "Trajectory height reference" },
    { "apt.dat 机场标高", "apt.dat airport elevation" },
    { "飞机 MSL 高度减机场标高", "aircraft MSL altitude minus airport elevation" },
    { "X-Plane 地形 AGL（无可用机场标高）", "X-Plane terrain AGL (airport elevation unavailable)" },
    { "俯仰角", "Pitch angle" },
    { "横滚角", "Roll angle" },
    { "T相对", "T-relative" },
    { "复算G", "recalculated G" },
    { "斜率对", "slope pairs" },
    { "可信度", "confidence" },
    { "高G段", "High-G" },
    { "高可信", "high confidence" },
    { "低可信", "low confidence" },
    { " 至 ", " to " },
    { "公式", "Formula" },
    { "迎角", "Angle of attack" },
    { "编号", "Index" },
    { "地面", "Ground" },
    { "选中", "selected" },
    { "样本", "samples" },
    { "跨度", "span" },
    { "索引", "index" },
    { "复算", "recalculated" },
    { "换算", "conversion" },
    { "窗口", "window" },
    { "最少", "at least" },
    { "几何", "geometric" },
    { "物理", "physical" },
    { "判定", "Decision" },
    { "规则", "Rule" },
    { "段号", "Segment" },
    { "G前", "G-before" },
    { "G后", "G-after" },
    { "本段", "segment" },
    { "累计", "cumulative" },
    { "误差", "error" },
    { "上限", "limit" },
    { "终点", "end" },
    { "起点", "start" },
    { "风 ", "Wind " },
    { "顶风", "headwind" },
    { "顺风", "tailwind" },
    { " 秒", " s" },
    { "（", " (" },
    { "）", ")" },
    { "，", ", " },
    { "；", "; " },
    { "。", "." },
    { "×", " x " },
    { "≤", "<=" },
    { "≥", ">=" },
    { "π", "pi" },

}

function log_tools.replace_report_plain(source, old_text, new_text)
    local start_index = 1
    while true do
        local found_start, found_end = string.find(source, old_text, start_index, true)
        if found_start == nil then break end
        source = string.sub(source, 1, found_start - 1)
            .. new_text
            .. string.sub(source, found_end + 1)
        start_index = found_start + string.len(new_text)
    end
    return source
end

function log_tools.english_report_text(value)
    if type(value) ~= "string" or value == "" then return value end
    -- 纯 ASCII 的数值表格行无需遍历术语表，完整数学日志开启时可明显减少写入开销。
    if string.find(value, "[\128-\255]") == nil then return value end
    local output = value
    for i = 1, #log_tools.report_translations do
        local pair = log_tools.report_translations[i]
        output = log_tools.replace_report_plain(output, pair[1], pair[2])
    end
    return output
end

function log_tools.make_report_writer(raw_file)
    if runtime_state.document_language ~= "en" then return raw_file end
    local writer = { raw_file = raw_file }
    function writer:write(...)
        for i = 1, select("#", ...) do
            local value = select(i, ...)
            local ok, write_error = self.raw_file:write(log_tools.english_report_text(value))
            if ok == nil then return nil, write_error end
        end
        return self
    end
    function writer:close()
        return self.raw_file:close()
    end
    return writer
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
        .. "_"
        .. (runtime_state.document_language == "en" and "EN" or "CN")
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
            "[StarLux LMM] %s | %s RWY%s | FPM=%d source=%s physical=%d AGL=%d VVI=%d | G=%.2f fixed160=%.2f physicsAvg=%.2f closure=%.0f%% | Bounce=%s | Surface=%s | IAS/GS=%.0f/%.0f",
            landing_context.aircraft_icao,
            landing_context.airport_id,
            landing_context.runway,
            landing_fpm,
            landing_analysis.flare_fpm_source,
            round_num(landing_analysis.physical_fpm),
            round_num(landing_analysis.agl_fpm),
            round_num(landing_analysis.vvi_fpm),
            landing_g,
            landing_analysis.local_event_g,
            landing_analysis.equivalent_g,
            landing_analysis.consistency_error * 100,
            bounce_state.detected and "YES" or "NO",
            landing_surface.warning_type,
            landing_ias_kts,
            landing_gs_kts
        ))
    end
end

local function collect_audit_values(source, count, start_time, end_time, value_kind, airborne_only, max_agl_m)
    local old_count = sort_scratch_count
    local selected_count = 0
    for i = 1, count do
        local sample = source[i]
        if sample.t >= start_time and sample.t <= end_time
            and (not airborne_only or sample.on_ground == 0)
            and (max_agl_m == nil or (sample.agl_m >= 0 and sample.agl_m <= max_agl_m)) then
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
    return value and log_tools.ui_text("是", "Yes") or log_tools.ui_text("否", "No")
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
    local contact_start = touch_time - PHYSICAL_FPM_CONTACT_WINDOW_SECONDS
    local diagnostic_start = touch_time - VVI_DIAGNOSTIC_WINDOW_SECONDS
    local agl_start = touch_time - landing_analysis.fpm_validation.agl_window_seconds
    local agl_end = touch_time - landing_analysis.fpm_validation.agl_end_guard_seconds
    local terminal_max_agl_m = landing_analysis.fpm_validation.terminal_agl_ft / 3.28084
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
    file:write("编号  T相对(s)    地面  AGL(m)      rawG       pitch       roll        projectedG  localVy(m/s)  physicalFPM   VVI(fpm)   窗口标记\n")
    file:write("--------------------------------------------------------------------------------------------------------------------------------------------\n")
    for i = 1, math_audit.count do
        local sample = math_audit.samples[i]
        local airborne = sample.on_ground == 0
        local in_physical = airborne
            and sample.t >= physical_start
            and sample.t <= agl_end
            and sample.agl_m >= 0
            and sample.agl_m <= terminal_max_agl_m
        local in_contact = airborne and sample.t >= contact_start and sample.t <= touch_time
        local in_diagnostic = airborne and sample.t >= diagnostic_start and sample.t <= touch_time
        local in_agl = airborne
            and sample.t >= agl_start
            and sample.t <= agl_end
            and sample.agl_m >= 0
            and sample.agl_m <= terminal_max_agl_m
        local in_baseline = airborne and sample.t >= baseline_start and sample.t <= impact_start
        local in_impact = sample.t >= impact_start and sample.t <= impact_end
        local in_post = sample.t >= post_start and sample.t <= landing_analysis.end_time
        local flags = table.concat({
            audit_flag(in_physical, "F5"),
            audit_flag(in_contact, "F100"),
            audit_flag(in_diagnostic, "V850"),
            audit_flag(in_agl, "AGL"),
            audit_flag(in_baseline, "BASE"),
            audit_flag(in_impact, "IMPACT"),
            audit_flag(in_post, "POST")
        }, ",")
        file:write(string.format(
            "%4d  %+11.9f  %4d  %10.6f  %.9f  %+10.6f  %+10.6f  %.9f  %+12.9f  %+11.6f  %+10.6f  %s\n",
            i,
            sample.t - touch_time,
            sample.on_ground,
            sample.agl_m,
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
    file:write("\n窗口标记: F5=5ft以下250ms物理备用/VVI参考，F100=接地前100ms物理候选窗，V850=850ms最差VVI诊断，AGL=5ft以下几何锚点，BASE=接地前G参考，IMPACT=第一次压缩，POST=压缩末端速度。\n\n")

    local physical_count = collect_audit_values(
        math_audit.samples,
        math_audit.count,
        physical_start,
        agl_end,
        "local_vy",
        true,
        terminal_max_agl_m
    )
    local physical_index = physical_count > 0
        and math.max(1, math.ceil(physical_count * PHYSICAL_FPM_PERCENTILE)) or 0
    local physical_value = physical_index > 0 and sort_scratch[physical_index] or 0
    write_sorted_scratch(file, "5ft以下250ms物理垂直速度(m/s)", 9)
    file:write(string.format(
        "备用P25索引 = ceil(%d × %.2f) = %d；%.9f m/s × 196.850394 = %.9f fpm；算法备用值 = %.9f fpm\n\n",
        physical_count,
        PHYSICAL_FPM_PERCENTILE,
        physical_index,
        physical_value,
        physical_value * 196.850394,
        landing_analysis.physical_fallback_fpm
    ))

    local contact_count = collect_audit_values(
        math_audit.samples,
        math_audit.count,
        contact_start,
        touch_time,
        "local_vy",
        true
    )
    local contact_value = scratch_median() or 0
    write_sorted_scratch(file, "接地前100ms物理垂直速度(m/s)", 9)
    file:write(string.format(
        "接地主窗中位数(n=%d) = %.9f m/s；换算 = %.9f fpm；最终物理候选值 = %.9f fpm\n\n",
        contact_count,
        contact_value,
        contact_value * 196.850394,
        landing_analysis.physical_fpm
    ))

    local vvi_count = collect_audit_values(
        math_audit.samples,
        math_audit.count,
        physical_start,
        agl_end,
        "vvi",
        true,
        terminal_max_agl_m
    )
    local vvi_value = scratch_median() or 0
    write_sorted_scratch(file, "5ft以下250ms VVI(fpm)", 6)
    file:write(string.format("VVI中位数(n=%d) = %.9f fpm\n\n", vvi_count, vvi_value))

    file:write("接地 FPM 的 AGL 锚点选择\n")
    file:write(string.format(
        "窗口: T-%.3f s 至 T-%.3f s；仅使用离地且 AGL≤%.1f ft 的样本；最少 %d 个样本且跨度不少于 %.3f s。\n",
        landing_analysis.fpm_validation.agl_window_seconds,
        landing_analysis.fpm_validation.agl_end_guard_seconds,
        landing_analysis.fpm_validation.terminal_agl_ft,
        landing_analysis.fpm_validation.agl_min_samples,
        landing_analysis.fpm_validation.agl_min_span_seconds
    ))
    file:write(string.format(
        "对窗口内每一对样本计算 slope=(AGL_j-AGL_i)/(t_j-t_i)，仅保留 dt>=%.3f s；AGL_FPM=median(slope)×196.850394。\n",
        landing_analysis.fpm_validation.agl_min_pair_gap_seconds
    ))
    file:write(string.format(
        "接地主窗物理样本=%d；VVI参考样本=%d；几何样本=%d；斜率对=%d；跨度=%.9f s；物理候选=%.9f；VVI候选=%.9f；AGL锚点=%.9f fpm。\n",
        landing_analysis.physical_sample_count,
        landing_analysis.vvi_sample_count,
        landing_analysis.agl_sample_count,
        landing_analysis.agl_pair_count,
        landing_analysis.agl_sample_span_seconds,
        landing_analysis.physical_fpm,
        landing_analysis.vvi_fpm,
        landing_analysis.agl_fpm
    ))
    file:write(string.format(
        "两两差值: |物理-VVI|=%.9f，|物理-几何|=%.9f，|VVI-几何|=%.9f；最大差值=%.9f fpm。\n",
        abs_value(landing_analysis.fpm_difference),
        abs_value(landing_analysis.agl_physical_difference),
        abs_value(landing_analysis.agl_vvi_difference),
        landing_analysis.fpm_max_pair_difference
    ))
    file:write(log_tools.ui_text(
        string.format(
            "选择规则: AGL 几何下降率作为锚点；物理 FPM 与 VVI 中距离 AGL 最近且差值不超过%d fpm者胜出，两者均超限时直接采用 AGL。AGL 缺样时依次回退到物理候选与 VVI。\n",
            landing_analysis.fpm_validation.agl_anchor_max_difference_fpm
        ),
        string.format(
            "Selection rule: use AGL geometric vertical speed as the anchor; select whichever of physical FPM and VVI is closest to AGL within %d fpm, otherwise use AGL directly. If AGL samples are unavailable, fall back to physical FPM and then VVI.\n",
            landing_analysis.fpm_validation.agl_anchor_max_difference_fpm
        )
    ))
    file:write(log_tools.ui_text(
        string.format(
            "最终来源=%s；取值说明=%s；最终FPM=%d。\n\n",
            landing_analysis.flare_fpm_source,
            landing_analysis.fpm_method,
            landing_fpm
        ),
        string.format(
            "Final source=%s; rationale=%s; final FPM=%d.\n\n",
            landing_analysis.flare_fpm_source,
            log_tools.english_report_text(landing_analysis.fpm_method),
            landing_fpm
        )
    ))

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

    file:write("接地后固定160ms稳健G复算\n")
    file:write(string.format(
        "规则: 从第一次接触起固定窗口长度=%.3f s，最少样本=%d，最小实际跨度=%.3f s；固定窗口取P%.0f，不滑动搜索最大值。\n",
        landing_analysis.g_local_event.window_seconds,
        landing_analysis.g_local_event.min_samples,
        landing_analysis.g_local_event.min_span_seconds,
        landing_analysis.g_local_event.percentile * 100
    ))
    if landing_analysis.local_event_g_valid then
        local local_event_count = collect_audit_values(
            math_audit.samples,
            math_audit.count,
            landing_analysis.local_event_window_start_time,
            landing_analysis.local_event_window_end_time,
            "projected_g",
            false
        )
        local local_event_index = local_event_count > 0
            and math.max(
                1,
                math.ceil(local_event_count * landing_analysis.g_local_event.percentile)
            ) or 0
        local local_event_value = local_event_index > 0 and sort_scratch[local_event_index] or 0
        write_sorted_scratch(file, "固定接地窗口垂直投影G", 9)
        file:write(string.format(
            "固定窗口: T%+.9f 至 T%+.9f s；样本=%d；跨度=%.9f s；P75索引=%d；复算=%.9f G；算法保存=%.9f G。\n",
            landing_analysis.local_event_window_start_time - touch_time,
            landing_analysis.local_event_window_end_time - touch_time,
            local_event_count,
            landing_analysis.local_event_window_span_seconds,
            local_event_index,
            local_event_value,
            landing_analysis.local_event_g
        ))
    else
        file:write("固定160ms窗口不满足最少样本与跨度要求，回退第一次压缩全段P75。\n")
    end
    file:write(string.format(
        "最终稳健G=固定160ms P75 %.9f（全段P75参考 %.9f）=%.9f G。\n\n",
        landing_analysis.local_event_g,
        landing_analysis.curve_g,
        landing_analysis.robust_event_g
    ))

    local high_threshold = 1.0 + math.max(0, landing_peak_g - 1.0) * 0.80
    local replay_impulse = 0
    local replay_high_duration = 0
    local replay_gap_sum = 0
    local replay_gap_count = 0
    local replay_max_gap = 0
    local previous_t = nil
    local previous_g = nil
    file:write("冲量梯形积分逐段复算\n")
    file:write(string.format(
        "高G诊断阈值 = 1.0 + (peak-1.0)×0.80 = %.9f G\n",
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
                local previous_excess = previous_g - 1.0
                local current_excess = sample.projected_g - 1.0
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
        "物理平均G = clamp(1,5, 1.0 + Δv/(9.80665×压缩时长)) = clamp(1,5, 1.0 + %.9f/(9.80665×%.9f)) = %.9f G\n\n",
        landing_analysis.velocity_delta_mps,
        landing_analysis.stop_duration_seconds,
        landing_analysis.equivalent_g
    ))

    local samples_valid = impact_count >= 3
        and landing_analysis.max_sample_gap_seconds <= MAX_VALID_SAMPLE_GAP_SECONDS
    file:write("G采样与最终分支复算\n")
    file:write(string.format("冲击样本数 >= 3: %s（%d）\n", math_boolean_text(impact_count >= 3), impact_count))
    file:write(string.format(
        "最大样本间隔 <= %.3f s: %s（%.9f s）\n",
        MAX_VALID_SAMPLE_GAP_SECONDS,
        math_boolean_text(landing_analysis.max_sample_gap_seconds <= MAX_VALID_SAMPLE_GAP_SECONDS),
        landing_analysis.max_sample_gap_seconds
    ))
    file:write("样本总体有效: " .. math_boolean_text(samples_valid) .. "\n")
    file:write(string.format("冲量闭合复核: <= %.0f%% 为通过，<= %.0f%% 为可复核，超过则提示偏差；复核结果不覆盖有效的实测稳健G。\n", CONSISTENCY_HIGH_MAX_ERROR * 100, CONSISTENCY_MEDIUM_MAX_ERROR * 100))
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
        "样本有效: finalG=固定160ms P75（固定窗不足时回退全段P75）；样本无效: finalG=min(全段P75, FPM备用上限)。物理平均G和冲量闭合误差只用于复核。\n"
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
    file:write("外部评分提示: " .. (EXTERNAL_SCORE_HINT or log_tools.ui_text("无", "None")) .. "\n")
    if landing_context.centerline_penalty_applied then
        file:write("中心线评分修正已应用: " .. landing_context.centerline_warning_text
            .. "；修正前 " .. status_short(landing_context.centerline_original_status)
            .. "；当前 " .. status_short(landing_status) .. "\n")
    elseif landing_context.runway_detected then
        file:write("中心线评分修正未触发: 中心线偏差未超过 7 米，不影响评分\n")
    else
        file:write("中心线评分修正未应用: 跑道未可靠识别\n")
    end
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
    local raw_file, err = io.open(log_path, "w")
    if raw_file == nil then
        if logMsg then
            logMsg("[StarLux LMM] Unable to write landing log: " .. tostring(err))
        end
        return false, tostring(err)
    end
    local file = log_tools.make_report_writer(raw_file)

    file:write("\239\187\191")
    file:write("StarLux 落地率插件 v1.1.4 - 单次落地记录\n")
    file:write("======================================================================\n\n")

    file:write("一、核心落地结果\n")
    file:write("----------------------------------------------------------------------\n")
    file:write("落地时间（本地时间）: " .. landing_timestamp .. "\n")
    file:write("最终评价: " .. status_short(landing_status) .. "\n")
    file:write("评价说明: " .. status_explanation(landing_status) .. "\n")
    file:write("触地垂直速度: " .. vertical_speed_log_text(landing_fpm) .. "\n")
    file:write("下降率取值: " .. fpm_source_log_text() .. "\n")
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
    if landing_context.runway_detected then
        file:write("触地跑道方向: RWY" .. landing_context.runway .. "（apt.dat 实测匹配）\n")
    else
        file:write("触地跑道方向: 未识别（未使用磁航向猜测）\n")
    end
    file:write(string.format("IAS / GS: %.0f / %.0f kt\n", landing_ias_kts, landing_gs_kts))
    file:write("相对风: " .. landing_wind_relative_text .. "\n")
    if landing_context.centerline_penalty_applied then
        file:write("中心线评价: " .. landing_context.centerline_warning_text .. "\n")
    elseif landing_context.runway_detected then
        file:write("中心线评价: 中心线偏差未超过 7 米，不影响评分\n")
    else
        file:write("中心线评价: 未参与评分（跑道未可靠识别）\n")
    end
    file:write("道面提示: " .. (landing_surface.warning_text ~= "" and landing_surface.warning_text or log_tools.ui_text("无", "None")) .. "\n\n")

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
    file:write("原始样本数: " .. tostring(flare_trace.analysis_sample_count) .. "\n")
    file:write("预采样原始样本数: " .. tostring(flare_trace.count) .. "\n")
    file:write("0.25秒聚合点数: " .. tostring(flare_trace.bucket_count) .. "\n")
    file:write("是否达到容量上限: " .. (flare_trace.limited and log_tools.ui_text("是", "Yes") or log_tools.ui_text("否", "No")) .. "\n")
    if flare_trace.height_reference == "APT_ELEVATION" then
        file:write(string.format(
            "轨迹高度基准: apt.dat 机场标高 %.1f ft（飞机 MSL 高度减机场标高）\n",
            flare_trace.reference_elevation_ft
        ))
    else
        file:write("轨迹高度基准: X-Plane 地形 AGL（无可用机场标高）\n")
    end
    file:write(string.format(
        "轨迹接地基准校准: %.2f ft（飞机参考点接地高度，已从整段轨迹扣除）\n",
        flare_trace.touch_reference_ft
    ))
    file:write(string.format("100 ft 至触地时间: %.2f s\n", flare_analysis.duration_seconds))
    file:write("轨迹下降率取值: " .. fpm_source_log_text() .. "\n")
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
    file:write("评分说明: v1.1.4 的拉平曲率仅用于复盘展示，暂不参与评分。\n")
    file:write(string.format("曲率分析耗时: %.3f ms\n\n", flare_analysis.calculation_ms))

    if landing_analysis.math_log_enabled then
        file:write("0.25秒聚合轨迹表（高精度复算输入）\n")
        file:write("T+秒         RA(ft)       轨迹FPM       VVI          IAS        GS         Pitch       AoA         Roll        物理FPM\n")
        file:write("------------------------------------------------------------------------------------------------------------------------\n")
        for i = 1, flare_trace.bucket_count do
            local bucket = flare_trace.buckets[i]
            file:write(string.format(
                "%11.9f  %11.6f  %+13.9f  %+11.6f  %10.6f  %10.6f  %+11.6f  %+10.6f  %+10.6f  %+13.9f\n",
                bucket.t - flare_trace.start_time,
                bucket.agl_ft,
                bucket.selected_fpm,
                bucket.vvi_fpm,
                bucket.ias_kts,
                bucket.gs_kts,
                bucket.pitch_deg,
                bucket.aoa_deg,
                bucket.roll_deg,
                bucket.physical_fpm
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
                local slope1 = (p2.selected_fpm - p1.selected_fpm) / dt1
                local slope2 = (p3.selected_fpm - p2.selected_fpm) / dt2
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
        file:write("0.25秒聚合轨迹表\n")
        file:write("T+秒   RA(ft)   轨迹FPM   VVI   IAS   GS   Pitch   AoA   Roll   物理FPM\n")
        file:write("--------------------------------------------------------------------------------\n")
        for i = 1, flare_trace.bucket_count do
            local bucket = flare_trace.buckets[i]
            file:write(string.format(
                "%5.1f  %7.1f  %8.0f  %5.0f  %4.0f  %4.0f  %+6.1f  %+5.1f  %+5.1f  %+8.0f\n",
                bucket.t - flare_trace.start_time,
                bucket.agl_ft,
                bucket.selected_fpm,
                bucket.vvi_fpm,
                bucket.ias_kts,
                bucket.gs_kts,
                bucket.pitch_deg,
                bucket.aoa_deg,
                bucket.roll_deg,
                bucket.physical_fpm
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
    log_tools.write_runway_reference(file)
    file:write(string.format("真空速（TAS）: %.0f kt\n", landing_tas_kts))
    file:write(string.format("迎角: %.1f deg\n", landing_aoa_deg))
    file:write(string.format("俯仰角: %+.1f deg\n", approach_data.pitch_deg))
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

    file:write("四、着陆数据复核\n")
    file:write("----------------------------------------------------------------------\n")
    file:write("最终显示/评分 FPM: " .. vertical_speed_log_text(landing_fpm) .. "\n")
    file:write("FPM 采用源: " .. fpm_source_log_text() .. "\n")
    file:write("下降率取值说明: " .. landing_analysis.fpm_method .. "\n")
    if landing_analysis.physical_fpm_valid then
        file:write("接地前物理下降率: " .. vertical_speed_log_text(round_num(landing_analysis.physical_fpm)) .. "\n")
    else
        file:write("接地前物理下降率: 样本不足\n")
    end
    if landing_analysis.agl_fpm_valid then
        file:write("AGL 几何锚点下降率: " .. vertical_speed_log_text(round_num(landing_analysis.agl_fpm)) .. "\n")
    else
        file:write("AGL 几何锚点下降率: 样本不足\n")
    end
    file:write("VVI 参考下降率: " .. vertical_speed_log_text(round_num(landing_analysis.vvi_fpm)) .. "\n")
    file:write(string.format(
        "FPM 物理/VVI有效样本: %d / %d\n",
        landing_analysis.physical_sample_count,
        landing_analysis.vvi_sample_count
    ))
    file:write(string.format("最终显示/评分 G: %.2f G\n", landing_g))
    file:write("最终 G 采用方式: " .. landing_analysis.method .. "\n")
    if landing_analysis.local_event_g_valid then
        file:write(string.format("接地后固定 160 ms 稳健 G: %.2f G\n", landing_analysis.local_event_g))
    else
        file:write(string.format(
            "接地后固定 160 ms 稳健 G: %.2f G（固定窗样本不足，采用全段P75）\n",
            landing_analysis.local_event_g
        ))
    end
    file:write(string.format("物理平均 G: %.2f G\n", landing_analysis.equivalent_g))
    file:write(string.format("G 冲量闭合误差: %.1f%%\n", landing_analysis.consistency_error * 100))
    file:write("G 复核结论: " .. (
        landing_analysis.used_fallback and log_tools.ui_text("采样不足，已使用备用值", "Insufficient samples; fallback used")
        or (landing_analysis.consistency_error <= CONSISTENCY_MEDIUM_MAX_ERROR
            and log_tools.ui_text("通过", "Pass")
            or log_tools.ui_text("偏差较大，请结合原始轨迹复核", "Large deviation; review the raw trace"))
    ) .. "\n")
    file:write("G 有效样本数: " .. tostring(landing_analysis.impact_sample_count) .. "\n")
    file:write(string.format("平均采样间隔: %.1f ms\n", landing_analysis.average_sample_gap_seconds * 1000))
    file:write(string.format("最大采样间隔: %.1f ms\n", landing_analysis.max_sample_gap_seconds * 1000))
    file:write("\n")

    file:write("五、评分阈值与显示设置\n")
    file:write("----------------------------------------------------------------------\n")
    file:write(string.format("Nice: FPM ≤ %d，G ≤ %.2f\n", FPM_NICE_MAX, G_NICE_MAX))
    file:write(string.format("Stable: FPM ≤ %d，G ≤ %.2f\n", FPM_STABLE_MAX, G_STABLE_MAX))
    file:write(string.format("Attention: FPM ≤ %d，G ≤ %.2f\n", FPM_ATTENTION_MAX, G_ATTENTION_MAX))
    file:write("UNSTABLE: FPM 或 G 超过任意 Attention 上限。\n")
    file:write("FPM 与 G 分别分档，最终评价取较严重等级；拉平曲率暂不参与评分。\n")
    file:write("弹窗时机: " .. log_tools.popup_mode_log_text() .. "\n")
    file:write("显示时长: " .. tostring(DISPLAY_SECONDS) .. " 秒\n")
    file:write("屏幕位置: " .. position_log_label(POPUP_POSITION) .. "\n")
    file:write("窗口布局: " .. (POPUP_LAYOUT == "vertical" and log_tools.ui_text("竖向", "Vertical") or log_tools.ui_text("横向", "Horizontal")) .. "\n")
    file:write("背景透明度档位: " .. tostring(PANEL_OPACITY_LEVEL) .. "%\n")
    file:write("精准跑道识别: " .. (runtime_state.runway_detection_enabled and log_tools.ui_text("开启", "On") or log_tools.ui_text("关闭", "Off")) .. "\n")
    file:write(
        "完整数学复算附录: "
        .. (landing_analysis.math_log_enabled and log_tools.ui_text("开启", "On") or log_tools.ui_text("关闭", "Off"))
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
    landing_jobs.runway_deadline = landing_jobs.context_after + log_tools.runway_config.timeout_seconds
end

local function resolve_context_safely(now)
    landing_jobs.context_pending = false
    local call_ok, resolve_ok, reason = pcall(resolve_landing_context, now)
    if not call_ok then
        landing_context.airport_id = "UNKNOWN"
        landing_context.airport_name = ""
        landing_context.runway_status = "unavailable"
        log_tools.finish_runway_resolver("unavailable", tostring(resolve_ok))
        if logMsg then
            logMsg("[StarLux LMM] Airport lookup failed; monitoring will continue: " .. tostring(resolve_ok))
        end
    elseif not resolve_ok and logMsg then
        logMsg("[StarLux LMM] Airport not identified: " .. tostring(reason))
    elseif logMsg then
        logMsg(string.format(
            "[StarLux LMM] Airport identified: %s (%s), %.1f km from touchdown; runway resolution %s",
            landing_context.airport_id,
            landing_context.airport_name,
            landing_context.airport_distance_km,
            runtime_state.runway_detection_enabled and "started" or "disabled"
        ))
    end
    refresh_popup_cache()
end

local function process_landing_jobs(now, allow_prefetch_scan)
    if landing_jobs.context_pending == true and now >= landing_jobs.context_after then
        resolve_context_safely(now)
    end

    local runway_state = log_tools.runway_state
    local may_scan = runway_state.mode ~= "prefetch" or allow_prefetch_scan == true
    if runway_state.active and may_scan then
        local call_ok, finished = pcall(log_tools.process_runway_resolver, now)
        if not call_ok then
            log_tools.finish_runway_resolver("unavailable", "apt.dat 解析异常: " .. tostring(finished))
            finished = true
        end
        if finished then
            refresh_popup_cache()
            if logMsg then
                if runway_state.last_mode == "prefetch" and runway_state.last_status == "prefetched" then
                    logMsg("[StarLux LMM] Runway data prefetched for " .. tostring(runway_state.target_airport) .. ".")
                elseif runway_state.last_mode ~= "prefetch" and landing_context.runway_detected then
                    logMsg(string.format(
                        "[StarLux LMM] Runway resolved: %s RWY %s, %.1f m after threshold, confidence %s.",
                        landing_context.airport_id,
                        landing_context.runway,
                        landing_context.touchdown_from_threshold_m,
                        landing_context.runway_confidence
                    ))
                elseif runway_state.last_mode ~= "prefetch" then
                    logMsg("[StarLux LMM] Runway unavailable; core landing data remains valid: " .. tostring(runway_state.last_reason))
                end
            end
        end
    end

    if landing_jobs.log_pending == true and now >= landing_jobs.log_after then
        -- 正常情况下机场查询会先完成；若模拟时间发生跳变，则在写文件前补做一次。
        if landing_jobs.context_pending == true then
            resolve_context_safely(now)
        end
        -- 报告最早在 8 秒写入；若分帧扫描尚未完成，则只等待到独立时间预算耗尽。
        if log_tools.runway_state.active and now < landing_jobs.runway_deadline then
            return
        end
        if log_tools.runway_state.active then
            log_tools.finish_runway_resolver("timeout", "跑道识别超过独立时间预算")
            refresh_popup_cache()
        end
        landing_jobs.log_pending = false

        log_landing_summary()
        local call_ok, write_ok, result = pcall(write_landing_log)
        if call_ok and write_ok then
            -- 新日志直接追加到内存索引，避免每次落地后重新遍历整个文件夹。
            log_tools.register_log_filename(file_name_from_path(result))
            landing_report_notice.file_name = file_name_from_path(result)
            if POPUP_MODE ~= "clean" and runtime_state.replay_active == false then
                landing_report_notice.text = log_tools.ui_text("落地详细报告已生成: ", "Detailed landing report generated: ") .. landing_report_notice.file_name
                landing_report_notice.until_time = now + REPORT_NOTICE_SECONDS
            else
                landing_report_notice.text = ""
                landing_report_notice.until_time = 0
            end
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
    bounce_state.result_status = landing_status
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
    bounce_state.result_status = landing_status

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
    bounce_state.result_status = landing_status

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
            landing_analysis.capture_end_reason = "检测到垂直速度反向"
            landing_analysis.impact_end_time = now
            landing_analysis.end_time = now
            landing_analysis.phase = "analyze_velocity"
        elseif landing_analysis.stop_stable_frames >= IMPACT_STOP_STABLE_FRAMES then
            -- 三帧只用于确认停止状态；物理减速时长截止到第一帧达到停止阈值的时刻。
            landing_analysis.capture_end_reason = "垂直速度连续三帧进入稳定区"
            landing_analysis.impact_end_time = landing_analysis.stop_candidate_time
            landing_analysis.end_time = now
            landing_analysis.phase = "analyze_velocity"
        elseif now >= landing_analysis.capture_deadline then
            landing_analysis.capture_end_reason = "达到1.20秒安全采集上限"
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
    -- 关闭精准跑道功能时连数据源发现也跳过，形成完整的最小更新回退路径。
    if runtime_state.runway_detection_enabled then
        log_tools.discover_apt_sources()
    end
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

    settings_window = float_wnd_create(520, 720, 1, true)
    float_wnd_set_title(settings_window, log_tools.settings_text("StarLux Landing Meter - 打开设置", "StarLux Landing Meter - Settings"))
    float_wnd_set_imgui_builder(settings_window, "ma_build_settings_window")
    float_wnd_set_onclose(settings_window, "ma_settings_window_closed")

    local screen_w = SCREEN_WIDTH or 1920
    local screen_h = SCREEN_HIGHT or 1080
    float_wnd_set_position(settings_window, math.floor((screen_w - 520) / 2), math.floor((screen_h - 720) / 2))
end

function ma_build_settings_window(wnd, x, y)
    imgui.TextUnformatted("Data output language")
    if imgui.RadioButton("Chinese##lmm_language_zh", runtime_state.document_language == "zh") then
        runtime_state.document_language = "zh"; refresh_popup_cache(); float_wnd_set_title(settings_window, "StarLux Landing Meter - Settings"); save_settings()
    end
    imgui.SameLine()
    if imgui.RadioButton("English##lmm_language_en", runtime_state.document_language == "en") then
        runtime_state.document_language = "en"; refresh_popup_cache(); float_wnd_set_title(settings_window, "StarLux Landing Meter - Settings"); save_settings()
    end
    imgui.TextUnformatted("Controls the TXT report language and _CN / _EN filename suffix.")

    imgui.Separator()
    imgui.TextUnformatted(log_tools.settings_text("落地数据弹窗时机", "Landing data popup timing"))
    if imgui.RadioButton(log_tools.settings_text("分析完成后立即显示", "Show immediately after analysis") .. "##lmm_immediate", POPUP_MODE == "immediate") then POPUP_MODE = "immediate"; save_settings() end
    if imgui.RadioButton(log_tools.settings_text("地速低于 30 kt 时显示", "Show after slowing below 30 kt") .. "##lmm_taxi", POPUP_MODE == "taxi") then POPUP_MODE = "taxi"; save_settings() end
    if imgui.RadioButton(log_tools.settings_text("停稳并持续 10 秒后显示", "Show after stopped for 10 seconds") .. "##lmm_stopped", POPUP_MODE == "stopped") then POPUP_MODE = "stopped"; runtime_state.stopped_popup_since = 0; save_settings() end
    if imgui.RadioButton(log_tools.settings_text("不自动显示", "Do not show automatically") .. "##lmm_off", POPUP_MODE == "off") then POPUP_MODE = "off"; show_until = 0; runtime_state.stopped_popup_since = 0; save_settings() end
    if imgui.RadioButton(log_tools.settings_text("纯净模式（关闭全部自动提示）", "Clean mode (disable all automatic popups)") .. "##lmm_clean", POPUP_MODE == "clean") then
        POPUP_MODE = "clean"; show_until = 0; runtime_state.stopped_popup_since = 0
        landing_report_notice.text = ""; landing_report_notice.file_name = ""; landing_report_notice.until_time = 0
        save_settings()
    end

    imgui.Separator()
    imgui.TextUnformatted(log_tools.settings_text("精准跑道与触地点", "Exact runway and touchdown point"))
    local runway_changed, new_runway_value = imgui.Checkbox(log_tools.settings_text("进近阶段预读 apt.dat 并在触地后匹配真实跑道", "Prefetch apt.dat on approach and match the real runway after touchdown") .. "##lmm_runway", runtime_state.runway_detection_enabled)
    if runway_changed then
        runtime_state.runway_detection_enabled = new_runway_value
        if new_runway_value then
            pcall(log_tools.discover_apt_sources)
        else
            log_tools.cancel_runway_resolver("用户已关闭精准跑道识别")
        end
        save_settings()
    end
    imgui.TextUnformatted(log_tools.settings_text("关闭后仍保留 1.1.4 落地算法，不使用磁航向猜测跑道。", "Off keeps the v1.1.4 landing algorithm and never guesses a runway from heading."))

    imgui.Separator()
    imgui.TextUnformatted(log_tools.settings_text("弹窗显示时长", "Popup duration"))
    if imgui.RadioButton(log_tools.settings_text("30 秒", "30 seconds") .. "##lmm_30", DISPLAY_SECONDS == 30) then DISPLAY_SECONDS = 30; save_settings() end
    imgui.SameLine()
    if imgui.RadioButton(log_tools.settings_text("60 秒", "60 seconds") .. "##lmm_60", DISPLAY_SECONDS == 60) then DISPLAY_SECONDS = 60; save_settings() end
    imgui.SameLine()
    if imgui.RadioButton(log_tools.settings_text("120 秒（最大）", "120 seconds (maximum)") .. "##lmm_120", DISPLAY_SECONDS == 120) then DISPLAY_SECONDS = 120; save_settings() end

    imgui.Separator()
    imgui.TextUnformatted(log_tools.settings_text("弹窗位置", "Popup position"))
    if imgui.BeginCombo(log_tools.settings_text("屏幕位置", "Screen position") .. "##lmm_position", position_label(POPUP_POSITION)) then
        for i = 1, #POSITION_OPTIONS do
            local option = POSITION_OPTIONS[i]
            local label = option.label
            if imgui.Selectable(label, POPUP_POSITION == option.id) then POPUP_POSITION = option.id; save_settings() end
        end
        imgui.EndCombo()
    end

    imgui.Separator()
    imgui.TextUnformatted(log_tools.settings_text("弹窗布局", "Popup layout"))
    if imgui.RadioButton(log_tools.settings_text("横向－左侧状态色", "Horizontal - accent on the left") .. "##lmm_horizontal", POPUP_LAYOUT == "horizontal") then POPUP_LAYOUT = "horizontal"; save_settings() end
    if imgui.RadioButton(log_tools.settings_text("竖向－顶部状态色", "Vertical - accent on the top") .. "##lmm_vertical", POPUP_LAYOUT == "vertical") then POPUP_LAYOUT = "vertical"; save_settings() end

    imgui.Separator()
    imgui.TextUnformatted(log_tools.settings_text("背景透明度", "Background opacity"))
    if imgui.RadioButton("25%##lmm_opacity_25", PANEL_OPACITY_LEVEL == 25) then PANEL_OPACITY_LEVEL = 25; save_settings() end
    imgui.SameLine()
    if imgui.RadioButton("50%##lmm_opacity_50", PANEL_OPACITY_LEVEL == 50) then PANEL_OPACITY_LEVEL = 50; save_settings() end
    imgui.SameLine()
    if imgui.RadioButton("100%##lmm_opacity_100", PANEL_OPACITY_LEVEL == 100) then PANEL_OPACITY_LEVEL = 100; save_settings() end

    imgui.Separator()
    local changed, new_debug_value = imgui.Checkbox(log_tools.settings_text("显示测量调试详情", "Show measurement debug details") .. "##lmm_debug", DEBUG_MODE)
    if changed then DEBUG_MODE = new_debug_value; save_settings() end

    imgui.Separator()
    imgui.TextUnformatted(log_tools.settings_text("TXT 报告详细程度", "TXT report detail"))
    local math_changed, new_math_value = imgui.Checkbox(log_tools.settings_text("包含完整数学复算（文件更大）", "Include full mathematical audit (larger TXT files)") .. "##lmm_math", DETAILED_MATH_LOG)
    if math_changed then DETAILED_MATH_LOG = new_math_value; save_settings() end
    imgui.TextUnformatted(log_tools.settings_text("关闭：简洁报告；开启：完整可复算内容。", "Off: concise report. On: complete reproducible calculations."))
    if imgui.Button(log_tools.settings_text("预览弹窗 5 秒", "Preview popup for 5 seconds") .. "##lmm_preview", 220, 28) then refresh_popup_cache(); show_until = current_sim_time() + 5 end
    imgui.Separator()
    imgui.TextUnformatted(settings_save_ok and log_tools.settings_text("设置已自动保存。", "Settings are saved automatically.") or log_tools.settings_text("警告：设置保存失败，请检查 FlyWithLua Log.txt。", "Warning: settings could not be saved. Check FlyWithLua Log.txt."))
    imgui.TextUnformatted(log_tools.settings_text("每次完成的落地将保存为 TXT 文件：", "Each completed landing is saved as a TXT file in:"))
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

    imgui.TextUnformatted(log_tools.settings_text("落地记录", "Landing records"))
    imgui.TextUnformatted(
        string.format(
            log_tools.settings_text("已索引 %d 条记录。点击记录可打开可视化报告。", "%d record(s) indexed. Click a record to open the visual report."),
            record_count
        )
    )
    if imgui.Button(log_tools.settings_text("刷新索引", "Refresh index") .. "##lmm_refresh", 140, 26) then
        local refresh_ok = log_tools.refresh_log_index()
        log_manager_state.notice = refresh_ok
            and string.format(log_tools.settings_text("索引已刷新：%d 条记录。", "Index refreshed: %d record(s)."), #log_manager_state.records)
            or log_manager_state.scan_error
    end
    imgui.SameLine()
    if imgui.Button(log_tools.settings_text("打开 LMM_Log 文件夹", "Open LMM_Log folder") .. "##lmm_folder", 180, 26) then
        local open_ok, open_error = log_tools.open_viewer_in_default_browser(LOG_DIRECTORY_PATH)
        log_manager_state.notice = open_ok and log_tools.settings_text("已打开 LMM_Log 文件夹。", "Opened LMM_Log folder.") or tostring(open_error)
    end

    if log_manager_state.scan_error ~= "" then
        imgui.TextUnformatted(log_manager_state.scan_error)
    end
    imgui.Separator()

    if record_count == 0 then
        imgui.TextUnformatted(log_tools.settings_text("未找到落地记录。", "No landing records found."))
        imgui.TextUnformatted(log_tools.settings_text("完成一次落地，或将 LMM_*.txt 复制到 LMM_Log。", "Complete a landing or copy an LMM_*.txt file into LMM_Log."))
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
                    log_manager_state.notice = log_tools.settings_text("可视化报告已打开：", "Visual report opened: ") .. record.name
                else
                    local error_text = call_ok and result or open_ok
                    log_manager_state.notice = log_tools.settings_text("无法打开报告：", "Unable to open report: ") .. tostring(error_text)
                    if logMsg then
                        logMsg("[StarLux LMM] Viewer error: " .. tostring(error_text))
                    end
                end
            end
            imgui.SameLine()
            if imgui.Button(log_tools.settings_text("删除", "Delete") .. "##lmm_delete_" .. tostring(i), 100, 30) then
                log_manager_state.pending_delete = record.name
                log_manager_state.notice = ""
            end
        end
    end

    if log_manager_state.pending_delete ~= "" then
        imgui.Separator()
        imgui.TextUnformatted(log_tools.settings_text("永久删除此 TXT？", "Permanently delete this TXT?"))
        imgui.TextUnformatted(log_tools.shorten_log_filename(log_manager_state.pending_delete, 84))
        if imgui.Button(log_tools.settings_text("确认删除", "Confirm delete") .. "##lmm_confirm", 150, 28) then
            local target_name = log_manager_state.pending_delete
            local call_ok, delete_ok, result = pcall(log_tools.delete_indexed_log, target_name)
            if call_ok and delete_ok then
                log_manager_state.notice = log_tools.settings_text("已删除：", "Deleted: ") .. target_name
            else
                local error_text = call_ok and result or delete_ok
                log_manager_state.notice = log_tools.settings_text("删除失败：", "Delete failed: ") .. tostring(error_text)
                log_manager_state.pending_delete = ""
            end
        end
        imgui.SameLine()
        if imgui.Button(log_tools.settings_text("取消", "Cancel") .. "##lmm_cancel", 100, 28) then
            log_manager_state.pending_delete = ""
        end
    end

    imgui.Separator()
    if imgui.Button(log_tools.settings_text("< 上一页", "< Previous") .. "##lmm_prev", 110, 26) and log_manager_state.page > 1 then
        log_manager_state.page = log_manager_state.page - 1
        log_manager_state.pending_delete = ""
    end
    imgui.SameLine()
    imgui.TextUnformatted(
        string.format(log_tools.settings_text("第 %d / %d 页", "Page %d / %d"), log_manager_state.page, page_count)
    )
    imgui.SameLine()
    if imgui.Button(log_tools.settings_text("下一页 >", "Next >") .. "##lmm_next", 110, 26) and log_manager_state.page < page_count then
        log_manager_state.page = log_manager_state.page + 1
        log_manager_state.pending_delete = ""
    end

    if log_manager_state.viewer_busy then
        imgui.TextUnformatted(log_tools.settings_text("正在生成本地可视化报告……", "Generating local visual report..."))
    elseif log_manager_state.notice ~= "" then
        imgui.TextUnformatted(log_manager_state.notice)
    end
    imgui.TextUnformatted(log_tools.settings_text("可视化仅在本机运行，不会上传落地数据。", "Visualizer runs locally. No landing data is uploaded."))
end

add_macro("StarLux LMM | 打开设置/Open Setting", "ma_open_settings_window()")
create_command(
    "starlux/lmm/open_settings",
    "Open StarLux LMM settings / 打开设置",
    "ma_open_settings_window()",
    "",
    ""
)
add_macro("StarLux LMM | 落地记录/Landing Record", "ma_open_log_manager()")

-- =========================
-- 核心逻辑
-- =========================

function ma_landing_meter_update()
    local now = current_sim_time()

    -- 每帧通过 XPLM 句柄读取一次所有必需数据，避免重复读取。
    local vs_fpm = lmm_get_float("vs_fpm")
    local local_vy_mps = lmm_get_float("local_vy_mps")
    local y_agl_m = lmm_get_float("y_agl_m")
    local elevation_m = lmm_get_double("elevation_m")
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
    local trace_altitude_ft = log_tools.flare_reference_height_ft(elevation_m, radio_alt_ft)
    local gs_kt = mps_to_kt(groundspeed_mps)
    local is_replay = lmm_get_int("is_in_replay") ~= 0

    -- 回放中的接地状态跳变不属于新的真实飞行，禁止采样、触发和写入报告。
    -- 退出回放时再清空一次瞬时状态，避免把回放末帧与实时首帧拼成一次假落地。
    if is_replay then
        if runtime_state.replay_active == false then
            runtime_state.replay_active = true
            armed = false
            landing_complete = false
            landing_analysis.phase = "idle"
            reset_sample_buffer()
            reset_math_audit()
            reset_flare_trace()
            reset_bounce_state()
            runtime_state.stopped_popup_since = 0
            runtime_state.deferred_popup_done = false
            show_until = 0
            landing_jobs.context_pending = false
            landing_jobs.log_pending = false
            log_tools.cancel_runway_resolver("replay")
            landing_report_notice.text = ""
            landing_report_notice.file_name = ""
            landing_report_notice.until_time = 0
            if logMsg then logMsg("[StarLux LMM] Replay detected; landing capture suspended.") end
        end
        was_on_ground = on_ground
        return
    elseif runtime_state.replay_active then
        runtime_state.replay_active = false
        armed = false
        landing_complete = false
        landing_analysis.phase = "idle"
        reset_sample_buffer()
        reset_math_audit()
        reset_flare_trace()
        reset_bounce_state()
        runtime_state.stopped_popup_since = 0
        runtime_state.deferred_popup_done = false
        show_until = 0
        landing_report_notice.text = ""
        landing_report_notice.file_name = ""
        landing_report_notice.until_time = 0
        was_on_ground = on_ground
        if logMsg then logMsg("[StarLux LMM] Replay ended; waiting for a fresh approach.") end
        return
    end

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
        runtime_state.deferred_popup_done = false
        runtime_state.stopped_popup_since = 0
    end

    -- 5000 ft 以下每 5 秒确认附近机场，并在后台分帧预读 apt.dat。
    -- 跑道几何只缓存，不会在真正触地前生成跑道号或触地点。
    pcall(
        log_tools.update_runway_prefetch,
        now,
        radio_alt_ft,
        on_ground,
        local_vy_mps,
        gs_kt,
        armed
    )

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
        trace_altitude_ft,
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
            y_agl_m,
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

        finish_flare_trace(now, trace_altitude_ft)
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

    -- 延迟弹窗模式只在分析完成后计时；停稳模式要求地速连续 10 秒不超过 1 节。
    if POPUP_MODE == "taxi" and landing_complete == true and runtime_state.deferred_popup_done == false then
        if gs_kt <= TAXI_POPUP_SPEED_KT then
            show_until = now + DISPLAY_SECONDS
            runtime_state.deferred_popup_done = true
        end
    elseif POPUP_MODE == "stopped" and landing_complete == true and runtime_state.deferred_popup_done == false then
        if on_ground == 1 and gs_kt <= runtime_state.stopped_speed_kt then
            if runtime_state.stopped_popup_since <= 0 then
                runtime_state.stopped_popup_since = now
            elseif now - runtime_state.stopped_popup_since >= runtime_state.stopped_hold_seconds then
                show_until = now + DISPLAY_SECONDS
                runtime_state.deferred_popup_done = true
                runtime_state.stopped_popup_since = 0
            end
        else
            runtime_state.stopped_popup_since = 0
        end
    elseif POPUP_MODE ~= "stopped" then
        runtime_state.stopped_popup_since = 0
    end

    -- 分阶段处理机场查询、报告写入和完成提示。
    process_landing_jobs(
        now,
        on_ground == 0 and radio_alt_ft > log_tools.runway_config.prefetch_min_agl_ft
    )

    was_on_ground = on_ground
end

-- =========================
-- 数据窗绘制
-- =========================

function ma_landing_meter_draw()
    -- 回放期间不绘制任何自动提示，避免旧提示跨越回放状态残留。
    if runtime_state.replay_active then return end
    local now = current_sim_time()
    local screen_w = SCREEN_WIDTH or 1920
    local screen_h = SCREEN_HIGHT or 1080
    local popup_visible = show_until > 0 and now <= show_until

    if popup_visible then
        local panel_w = HORIZONTAL_PANEL_W
        local panel_h = HORIZONTAL_PANEL_H
        local show_surface_warning = landing_surface.wet_warning and landing_status == "NICE"
        local show_bounce_warning = bounce_state.detected
        local show_centerline_warning = landing_context.centerline_penalty_applied
        local extra_line_count = 0
        if show_centerline_warning then
            extra_line_count = extra_line_count + 1
        end
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
        if show_centerline_warning then
            if landing_context.centerline_penalty_level == "unstable" then
                glColor4f(0.92, 0.24, 0.24, 1.0)
            else
                glColor4f(0.92, 0.62, 0.10, 1.0)
            end
            draw_string(
                text_x,
                line_y1 - line_gap * alert_line_index,
                popup_cache.centerline_text
            )
            alert_line_index = alert_line_index + 1
        end
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
            local debug_line1 = string.format("DBG FPM source:%s", landing_analysis.flare_fpm_source)
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
    if POPUP_MODE ~= "clean"
        and landing_report_notice.until_time > now
        and landing_report_notice.file_name ~= "" then
        local notice_w = math.min(500, screen_w - 40)
        local notice_h = 36
        local notice_x = math.floor((screen_w - notice_w) / 2)
        local notice_y = 38

        XPLMSetGraphicsState(0, 0, 0, 1, 1, 0, 0)
        glColor4f(0.03, 0.16, 0.09, 0.78)
        glRectf(notice_x, notice_y, notice_x + notice_w, notice_y + notice_h)
        draw_panel_border(notice_x, notice_y, notice_w, notice_h, 0.08, 0.50, 0.24)
        glColor4f(1, 1, 1, 0.98)
        landing_report_notice.text = log_tools.ui_text("落地详细报告已生成: ", "Detailed landing report generated: ") .. landing_report_notice.file_name
        draw_string(notice_x + 12, notice_y + 12, landing_report_notice.text)
    end
end

do_every_frame("ma_landing_meter_update()")
do_every_draw("ma_landing_meter_draw()")

if logMsg then
    logMsg(string.format(
        "[StarLux LMM] v1.1.4 loaded successfully with %d direct XPLM DataRefs.",
        #LMM_DATAREF_SPECS
    ))
end

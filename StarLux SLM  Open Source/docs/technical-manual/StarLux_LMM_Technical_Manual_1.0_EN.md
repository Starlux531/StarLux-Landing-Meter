# StarLux LMM Technical Manual

Manual 1.0 Final | Plugin 1.1.8 | English edition

Published: 2026-09-14. An implementation reference for reviewing flights, maintaining the plugin and porting its data interfaces.

Source baseline: GitHub commit `6a1c62ab433a764afecb14e98fb7f1b4b91f548e`. Manual and plugin versions are independent. This is not a manual for plugin 1.0, and it does not include unpublished 1.1.9 implementation work.

For flight simulation only. Ratings are this project's review rules, not airline-approved training standards. They cannot replace an aircraft manual, real-aircraft inspection or airworthiness assessment.

## 01 Scope and migration from the old manual

This document supersedes the core-algorithm manual based on 0.8.2. Although that document's cover included V1.0, it was marked PRE-1.0. Its algorithms must not be used to reconstruct 1.1.8 results. The old PDF remains available as historical material.

| Area | Old 0.8.2 description | Current 1.1.8 implementation |
| --- | --- | --- |
| Final FPM | Mainly pre-touch physical-velocity P25 | Physical short window, VVI and AGL trend cross-selection |
| Final G | Curve/equivalent-G blend by closure quality | Fixed 160 ms post-contact P75 preferred; equivalent G is diagnostic |
| Impulse reference | Positive excess load and pre-touch baseline | Signed `(G_projected - 1) * g` |
| Trace | Ends at first touch; 0.5 s buckets | Extended touchdown capture; 0.25 s buckets |
| Runway | Approximate naming from magnetic heading | apt.dat geometry, position and ground-velocity matching |
| Controls and power | No current complete interface chain | Three inputs, surfaces, per-engine throttle and N1 |
| UI and reports | Earlier display and text output | Bilingual UI, local synchronized analyzer, comparison and playback |

Standard targets X-Plane 12.4.4+ and uses SDK 440 native font/window capabilities. Compatibility targets earlier X-Plane 12 versions and uses the legacy UI path. They are not two separate landing algorithms. Algorithm descriptions here refer to `StarLux_LMM_v1.1.8.lua`; UI limitations are covered in section 13.

Read source identity first, timing and fallback status second, and the numerical result last. Three displayed decimal places do not establish three-decimal-place physical accuracy.

Sources: [S1 main script](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua), [S3 installation and compatibility](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/README_1.1.8.md).

## 02 Data contract and sampling layers

The main script reads core DataRefs through XPLM handles. Optional array channels support FlyWithLua data tables and direct XPLM array access. Handles are reused rather than registering another set of global DataRefs every frame.

| Signal | DataRef | Use in this implementation |
| --- | --- | --- |
| Physical vertical velocity | `sim/flightmodel/position/local_vy` | m/s; positive upward, negative descending |
| VVI | `sim/flightmodel/position/vh_ind_fpm` | fpm; candidate and report cross-check |
| Terrain AGL | `sim/flightmodel/position/y_agl` | m; triggers, geometric anchor and fallback height |
| MSL elevation | `sim/flightmodel/position/elevation` | m; trace reference against airport elevation |
| Ground contact | `sim/flightmodel/failures/onground_any` | Any-contact flag, not separate main/nose gear detection |
| Normal load | `sim/flightmodel/forces/g_nrml` | Raw G, subsequently projected using pitch and roll |
| Attitude | `sim/flightmodel/position/theta`, `phi`, `alpha` | Pitch, roll and angle of attack in degrees |
| Position and motion | `sim/flightmodel/position/latitude`, `longitude`, `local_vx`, `local_vz`, `groundspeed` | Coordinates, horizontal velocity and ground speed |
| Time | `sim/time/total_running_time_sec` | Event/window/job clock; falls back to `os.clock()` if unavailable |
| Frame period and replay | `sim/time/framerate_period`, `sim/time/is_in_replay` | Index budget and replay suppression |

Short names in shared-directory rows omit repeated prefixes only; verify complete names when porting. IAS/TAS, wind speed/direction, magnetic heading, precipitation and runway friction also provide report context. They are not additional grading inputs. Wind comes from the corresponding simulator indicator fields, not a reconstructed three-dimensional wind field along the approach.

There are three different sampling layers. The core touchdown ring holds 256 frame-callback samples. Trace/control sampling targets 0.10 s with 720 slots. Display trajectory data is then aggregated into 0.25 s buckets, up to 320 buckets. Low frame rates do not generate replacement real samples; the achieved rate can be lower than the target.

The UI name “RA” needs care: the trigger variable `radio_alt_ft` is actually converted from `y_agl`, not read directly from the cockpit radio-altimeter instrument. It is not guaranteed to equal tire clearance. Displayed trace height may instead use the airport MSL reference described in section 06.

Important limitation: optional controls/power have validity flags and can produce N/A, but core getters can return zero for missing handles and log the missing interfaces. “Missing data can never become zero” is not a current guarantee. Missing contact, time or height interfaces call the measurement into question; their zero fallbacks must not be interpreted as real flight states.

Conversion constants: `1 m/s = 196.850394 fpm`; `1 m = 3.28084 ft`; `1 m/s = 1.943844 kt`; `g = 9.80665 m/s²`. Negative FPM retains the descent sign; grading uses its magnitude.

Source: [S1 interfaces and buffers](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua#L169).

## 03 Event lifecycle and time origins

| Stage | Condition and action |
| --- | --- |
| Arming | Airborne, terrain AGL > 20 ft, GS > 50 kt, with no active bounce monitor |
| Approach snapshot | While armed, airborne and below 500 ft, update pre-touch attitude, wind and speed |
| Trace preparation | Confirm descent using both vertical-speed channels; begin the roughly 140 ft prebuffer |
| First contact t0 | Previous frame airborne, current frame grounded, armed, GS > 35 kt; freeze time, aircraft, position and ground-velocity vector |
| First compression | Capture vertical velocity and G until settling, upward reversal or the 1.2 s deadline |
| Staged analysis | Calculate FPM, G and closure diagnostics; wait for extended trace completion and analyze flare characteristics |
| Finalization tf | Update rating/display cache and schedule deferred context/report jobs |
| Deferred jobs | Begin context resolution at tf + 3 s; attempt report generation at tf + 8 s, subject to runway-job waiting |

The 3 s and 8 s delays start when `finalize_landing_analysis(now)` schedules the jobs, not strictly at t0. Matching timeouts and chunked writing add further delay. A file appearing exactly eight seconds after touchdown is not an implementation guarantee.

The 256-sample core ring is updated when armed at AGL <= 120 ft, during first-compression capture, bounce monitoring or second-contact capture. It stores recent frames, not a fixed number of seconds. At very high frame rates it may retain too little history for every diagnostic window; at low frame rates windows may contain too few samples.

First compression ends immediately when vertical velocity exceeds +0.05 m/s. Otherwise, three consecutive frames at >= -0.05 m/s identify settling; the compression endpoint is the first of those three frames. The final deadline is t0 + 1.2 s. The impulse start can include the last airborne frame up to 50 ms before t0, while the fixed G window still begins strictly at t0.

Entering and leaving replay clears arming, analysis, trace, bounce and pending-job state so replay is not treated as another landing. The implementation does not establish complete segmentation correctness for every pause, time jump and aircraft-position jump combination; test these separately.

Popup modes are immediate after analysis, GS <= 30 kt, grounded with GS <= 1 kt continuously for 10 s, no automatic display, and clean mode. Popup appearance is not the sampling time and does not prove that every airport field is already available.

Sources: [S1 main loop](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua#L9197), [analysis state machine](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua#L8720).

## 04 Final descent rate: candidates and fallbacks

### 4.1 Three candidate families

Physical short window: the median airborne `local_vy` in `[t0 - 0.10, t0]`, requiring at least three samples. If insufficient, use physical-velocity P25 from the terminal window, again requiring at least three samples.

The terminal window is `[t0 - 0.25, t0 - 0.04]`, restricted to airborne samples with terrain AGL from 0 to 5 ft. The VVI candidate is the median in this window. If insufficient, the approach-snapshot VVI is retained but marked as an invalid candidate, available only as the final fallback.

AGL geometric anchor: collect up to 64 terminal-window samples, requiring at least four samples spanning at least 0.16 s. For all pairs separated by >= 0.035 s, calculate `(h_j - h_i) / (t_j - t_i)`. Require at least three pairs; take their median slope and accept results from -20 to +3 m/s. This is a Theil-Sen-style robust trend estimate, not a copy of cockpit VVI.

### 4.2 Selection

| Order | When a valid AGL anchor exists |
| --- | --- |
| 1 | Choose valid physical FPM if within 30 fpm of AGL and no farther away than VVI |
| 2 | Otherwise choose valid VVI if within 30 fpm of AGL |
| 3 | If neither qualifies, choose the AGL trend itself |

Physical FPM wins an equal-distance tie. Without a valid AGL anchor, the priority is valid physical, valid VVI, then approach-snapshot VVI. The 30 fpm threshold is a selection rule, not an established measurement-error bound.

The selected result is rounded to integer fpm, with half values away from zero, before grading. Pre-impact velocity for impulse review retains the unrounded selected source value. Reconstructing impulse from the rounded report FPM alone need not produce an identical result.

### 4.3 Hand-checkable examples

These are synthetic examples, not real flight or user-log results. With valid physical -104 fpm, VVI -65 fpm and AGL -63 fpm, the distances are 41 and 2 fpm: choose VVI -65. With physical -70, VVI -56 and AGL -63, both distances are 7: choose physical -70.

P25/P75 select sorted element `ceil(N * p)` using one-based indexing, without linear interpolation. The ordinary median averages the two central values for even sample counts. Different percentile conventions in external software will produce differences.

AGL trends can be affected by terrain changes, aircraft reference-point geometry, gear attitude and frame rate. The anchor is a geometric cross-check, not an independent precision sensor. Likewise, the contact flag is not a dedicated main-gear force switch.

Source: [S1 velocity analysis](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua#L4940).

## 05 G: fixed window and impulse-closure review

### 5.1 Raw load and projection

Raw `g_nrml` is accepted only for `0.2 < G <= 5.0`; other samples do not enter valid G statistics. The approximate per-frame vertical projection is:

`Gv = G_normal * cos(pitch) * cos(roll)`, with angles converted to radians.

This projects normal load using attitude; it does not include the full three-axis body-load vector. It is neither a rigorous total earth-vertical acceleration nor a landing-gear load sensor. Raw touchdown G, bucketed trace G and final G are different statistics.

### 5.2 Final-value path

The fixed window is `[t0, min(compression_end, t0 + 0.160 s)]`. Its P75 is used only with at least five valid samples and a first-to-last span >= 0.040 s. An early compression endpoint can truncate it: “160 ms” does not mean every event contains a full 160 ms.

If that window is insufficient, use Gv P75 over the first compression interval. The full interval must itself contain at least three valid samples with a maximum adjacent valid-sample gap <= 0.050 s. If full-interval quality fails, final G becomes the smaller of full-interval P75 and the FPM fallback cap. If no full-interval P75 exists, the code uses its touchdown-G fallback.

`Gcap = 1 + abs(FPM_integer) * 0.00508 / (0.42 * 9.80665) + margin`

The margin is 0.08 for abs(FPM) <= 100; 0.12 for <= 250; 0.16 for <= 300; otherwise 0.22. Final G is clamped to 1 through 5. This is a protective low-quality estimate, not a measured impact peak.

### 5.3 Impulse is diagnostic, not a blend weight

Post-contact velocity is median `local_vy` in `[max(t0, end_time - 0.05), end_time]`, falling back to zero if absent. `end_time` is the confirming frame: with three stable frames, it is later than `impact_end_time`, which is backdated to the first stable frame. `deltaV = max(0, v_after - v_before)` and `T = max(0.03, impact_end_time - impact_start_time)`.

Adjacent valid samples are integrated using the trapezoidal rule:

`I = sum( ((Gv_i - 1) + (Gv_(i+1) - 1)) / 2 * 9.80665 * dt )`

Only segments with `0 < dt <= 0.10 s` are integrated. Negative contributions below 1 G are retained. The pre-touch baseline is diagnostic and does not replace 1 in this equation. Maximum sample gap is separately checked against the 50 ms quality threshold.

`error = abs(I - deltaV) / max(deltaV, 0.20)`; `G_equiv = clamp(1 + deltaV / (9.80665 * T), 1, 5)`.

With valid full-interval samples, error <= 25% is HIGH, <= 60% is MEDIUM, and larger error is LOW. Insufficient samples also produce LOW, but invoke the fallback cap. These are different situations: large closure error with valid samples retains the fixed-window/full-interval P75. It does not blend equivalent G into the result and does not itself activate the FPM cap.

Synthetic example: sorted fixed-window samples `[1.00, 1.08, 1.12, 1.20, 1.34]` with sufficient span yield element 4, or 1.20 G, rather than the maximum 1.34 G. If deltaV = 0.5 m/s and I = 0.2 m/s, error is 60%, classified MEDIUM; this does not change a valid P75.

Sources: [S1 sanitizing and projection](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua#L4187), [G calculation](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua#L5302).

## 06 Extended trace, height calibration and flare metrics

### 6.1 Recording interval

While armed and airborne, reference height from 0 to 140 ft and both physical FPM and VVI <= -50 fpm continuously for 0.20 s start the prebuffer. Sampling targets one point per 0.10 s, scheduling the next point at “now + 0.10 s” without backfilling missed frames. At 720 samples, the trace is marked limited; it does not roll over or act as an unlimited black box.

Before first touch, reference height >= 150 ft, both vertical-speed channels >= +100 fpm continuously for 1 s, or capture lasting over 120 s cancels the trace. Valid flare analysis also requires at least 12 raw points and four aggregated buckets.

First contact forces an anchor sample and capture continues. It normally ends after continuous ground contact >= 2 s. Another airborne episode resets this timer; the hard post-touch deadline is t0 + 8 s. This bounded extension does not guarantee coverage of an arbitrarily long bounce or rollout. Trace touch count tracks contact-flag transitions, not validated bounces.

### 6.2 Height and time alignment

When airport elevation is available, the preferred reference is aircraft MSL elevation minus apt.dat airport elevation; otherwise it is terrain AGL. A running trace keeps its chosen reference. Airport elevation supplies a flat reference, not the complete runway slope profile.

If the trace reference height at first touch is from 0 to 60 ft, it is subtracted from the whole trace as the aircraft reference offset. Otherwise the offset is zero. Corrected heights are clamped at zero. T+0 is the first existing sample at corrected height <= 100 ft, not an interpolated exact crossing. Thus event t0 and chart T+0 are different time origins.

### 6.3 Aggregation and curvature

Data is averaged into 0.25 s buckets without filling empty buckets. The main FPM trace follows the physical or VVI source selected for final FPM. If AGL was selected, FPM is constructed from neighboring corrected-height buckets. The touchdown anchor bucket is relocated to t0, height zero and final integer FPM. Its G is the touchdown instantaneous fallback value, not necessarily final robust G.

For three adjacent buckets up to first contact: `s1 = (f2-f1)/dt1`, `s2 = (f3-f2)/dt2`, and `C = (s2-s1)/((dt1+dt2)/2)`, accepting only dt1 and dt2 > 0.10 s. The flare-curvature metric is `P75(abs(C))`, with dimensions fpm/s². It is a second time difference of vertical speed, not geometric flight-path curvature or an energy curve.

Net recovery is touchdown FPM minus entry FPM. Monotonic efficiency is positive recovery divided by `max(total absolute change, 1)`. Worsening ratio counts adjacent FPM changes below -20. Direction reversals ignore changes of 20 fpm or less. At least five reversals, or at least three with efficiency < 0.55 or worsening ratio >= 0.40, trigger a stronger oscillation description. Recovery after the 70% time point is also reviewed.

These descriptions do not change NICE/STABLE/ATTENTION/UNSTABLE ratings and cannot directly establish pilot proficiency or aircraft-specific flare acceptance standards.

Sources: [S1 height reference](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua#L3571), [trace and flare analysis](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua#L4433).

## 07 Bounce, ratings and centerline adjustments

### 7.1 Base rating

| Rating | abs(FPM) upper limit | G upper limit |
| --- | --- | --- |
| NICE | 100 fpm | 1.20 |
| STABLE | 250 fpm | 1.50 |
| ATTENTION | 300 fpm | 1.80 |
| UNSTABLE | Above 300 | Above 1.80 |

FPM and G are classified independently and the more severe band wins; they are not averaged. Equality remains in the stated band. FPM is already integer-rounded, while G comparisons use the internal value, not its two-decimal display. For example, -299 fpm / 1.24 G is ATTENTION, not STABLE; -100 / 1.20 is NICE, and -101 / 1.20 is STABLE.

`classify_landing` retains an external severity-hint parameter that can worsen a result, but the current implementation is not a configurable airline-standards engine. Default thresholds are project rules.

### 7.2 Bounce detection

First touch starts candidate monitoring for up to 6 s. On returning to the ground after another airborne episode, that episode must last >= 0.12 s and reach either terrain AGL >= 0.5 ft or upward velocity >= 0.15 m/s to qualify. This height test uses raw terrain AGL, not the zero-corrected trace height.

A confirmed second contact is sampled for 0.35 s; G is projected-value P75 over that interval. Second-touch FPM is physical-velocity P25 over the preceding 0.25 s of airborne samples, not the first-contact three-candidate selection chain. Once started, second-G capture may finish beyond the candidate-monitor deadline. A normally finished trace with no confirmed bounce can also end candidate monitoring early, so not every landing is monitored for the full six seconds.

The grading chain handles one confirmed secondary contact. A bounce changes NICE to STABLE and STABLE to ATTENTION; ATTENTION remains unchanged. An existing UNSTABLE result, first final G > 1.80, or second-contact P75 G > 1.80 produces UNSTABLE. Second FPM is retained for review but does not independently rerun the base FPM bands.

### 7.3 Centerline adjustment

Applied once only after a successful runway match: absolute deviation <= 7 m makes no change; > 7 and <= 15 m worsens the non-red rating by one band, capped at ATTENTION; > 15 m produces UNSTABLE. Distance is from the recorded aircraft touchdown position, not the position of a specific tire.

Centerline and bounce are independent one-time adjustments and can stack. Synthetic example: base NICE becomes STABLE after a confirmed bounce and ATTENTION with an additional 8 m deviation. Exactly 7 m does not worsen the rating; exactly 15 m still uses the one-band rule; 15.1 m becomes UNSTABLE. A late runway result may update the initial popup rating. The analyzer reviews the final report.

Sources: [S1 base grading](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua#L4068), [bounce](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua#L8533), [centerline](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua#L3394).

## 08 Airport candidates and runway geometry

Prefetch checks run every 5 s while armed and airborne, with AGL from 100 to 5000 ft, physical vertical velocity < -0.1 m/s and GS > 50 kt. The primary airport-navigation candidate is limited to 40 km. Nearby discovery uses eight probe positions on a 5 km radius and retains airports within 15 km of the aircraft. It probes again after moving 2 km or after 30 s. The normal queue limit is 12; priority insertion is not a strict memory hard cap.

After touchdown, the frozen position is used to find an airport-navigation candidate within 15 km, read apt.dat geometry and compare available cached alternatives. The current entry path returns early if no such nearby navigation candidate exists; cached geometry alone does not guarantee recovery. Neither the FMS destination nor SimBrief is read.

Scenery sources follow enabled priority in `scenery_packs.ini`, skip disabled packs and handle Global Airports. Land-runway row 100 supplies endpoints, width, displaced thresholds and relevant markings. Water-runway row 101 and helipad row 102 do not provide this same matching path.

### 8.1 Geometry

A local east/north plane is constructed around touchdown using Earth radius 6,371,000 m and cosine-latitude longitude scaling. Motion direction is normalized from `(local_vx, -local_vz)`, requiring at least 2 m/s. Magnetic heading is not used to guess a runway designation.

Let u point from endpoint 1 to endpoint 2, p point from endpoint 1 to touchdown, and L be runway length. `s = dot(p,u)`; `c = u_e*p_n - u_n*p_e`; `a = abs(dot(u, velocity_unit))`.

Eligibility requires L >= 100 m, width > 0, `abs(c) <= width/2 + 45 m`, `-150 <= s <= L+150 m` and a >= 0.35. Candidates are compared using:

`score = abs(c) + 4 * max(0, -s, s-L) + 220 * (1-a)`, lower being better.

A different runway at the same airport, or another compared cached airport, within a score gap < 25 of the best result makes the match ambiguous and rejected. This score is not a probability. An incomplete candidate set means a single best candidate is not proof of global uniqueness.

### 8.2 Reading the output

Motion direction selects the runway end; its number and L/R/C suffix come from apt.dat. Distance beyond threshold uses s or L-s minus the corresponding displaced threshold. Remaining distance reaches the physical far end; it is not declared LDA or an approved stopping-performance distance.

A point within physical runway length, with `abs(c) <= width/2 + 8 m` and a >= 0.75, is HIGH; other accepted matches are MEDIUM. These are geometric match labels, not statistical confidence intervals or certified accuracy. Off-runway tolerances help identification; acceptance does not make the touchdown operationally acceptable.

Prefetched geometry alone does not change ratings. The final successful match enables centerline adjustment. Disabled precise matching or a failed match retains its status and core landing data without inventing a runway from magnetic heading.

Sources: [S1 source discovery and prefetch](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua#L2139), [runway parsing and matching](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua#L3186).

## 09 Persistent index and performance budgets

The filename is still `LMM_Apt_Index_v1.cache`, but its internal format version is 2. Do not infer format from its name. It holds per-source airport identifiers and apt.dat byte offsets, not copies of all scenery or a complete global runway-geometry database.

After source discovery, file size and a lightweight content fingerprint are checked. Five 1024-byte probes near the start, 25%, 50%, 75% and end produce a rolling checksum. Unchanged source shards are reused; added or changed sources rebuild their shards; removed, disabled or reprioritized sources are merged into the effective source set again. Version 2 also stores progress for resuming and checkpoints roughly every 30 s.

This reduces repeated scanning but is not a full-file hash. A same-sized file changed only outside the probes can be missed. When investigating a replaced scenery that is not reflected correctly, close XP, retain a backup and regenerate the cache. Cache validity is not unconditional.

Background building advances only in safe states, such as on the ground at GS <= 5 kt, or at AGL >= 6000 ft with absolute vertical velocity <= 3 m/s. Active precise scans, landing analysis, bounce processing and pending reports take priority. Initial building can wait for a suitable flight phase rather than running continuously at full speed from script load.

| Smoothed FPS tier | 64 KiB blocks per step | Minimum interval |
| --- | --- | --- |
| < 20 | 1 | 0.40 s |
| 20 to < 30 | 1 | 0.15 s |
| 30 to < 45 | 2 | 0.10 s |
| 45 to < 60 | 3 | 0.075 s |
| >= 60 | 4 | 0.05 s |

FPS is derived from frame-period reciprocal and clamped to 5 through 240. Initial smoothed FPS is capped at 30. Smoothing uses 0.25 when FPS falls and 0.06 when it rises, backing off faster than it increases work. The maximum 256 KiB per step is a byte/scheduling budget, not a hard CPU-time limit or a promise of no performance impact.

Cache saving processes at most 2048 lines per batch and uses a temporary file, backup and END completeness marker during replacement. The percentage is work progress, not a precise remaining-time estimate. An index ready in memory and its final disk save are not necessarily simultaneous.

Precise airport parsing is a separate incremental job with a normal 128 KiB read block. Prefetch can run for up to 300 s; post-landing resolution has a 30 s budget. The report's independent runway deadline starts from the scheduled context time. Low FPS, slow storage or many sources can still cause timeouts; failure must be explicit rather than blocking the report indefinitely.

Sources: [S1 index configuration](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua#L1376), [cache handling](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua#L2282).

## 10 Control inputs and surface response

Each axis collects candidates in the following order, then uses activity over the sampled segment to select one. Raw values are accepted only with magnitude <= 1.5, then clamped to [-1,1]. A valid zero remains zero; it is not a missing-data marker.

| Axis | First candidate | Second candidate | Third candidate |
| --- | --- | --- | --- |
| Pitch | `sim/joystick/yoke_pitch_ratio` | `sim/cockpit2/controls/yoke_pitch_ratio` | `sim/joystick/FC_ptch` |
| Roll | `sim/joystick/yoke_roll_ratio` | `sim/cockpit2/controls/yoke_roll_ratio` | `sim/joystick/FC_roll` |
| Yaw | `sim/joystick/yoke_heading_ratio` | `sim/cockpit2/controls/yoke_heading_ratio` | `sim/joystick/FC_hdng` |

Any one of these indicates activity: range >= 0.006, cumulative absolute adjacent change >= 0.02, or maximum magnitude >= 0.02. The first active candidate wins; if none is active, the first available candidate is used. A constant nonzero input can qualify, preserving a held input.

This helps when an aircraft leaves the preferred interface stationary but updates a fallback. It is still a heuristic: an FC channel may include flight-control processing rather than raw USB stick position. Hardware input, autopilot commands, flight-control commands and physical surfaces must not be treated as identical without validation.

Surfaces use `elevator1_deg` indices 8/9, `aileron1_deg` indices 0/1 and `rudder1_deg` indices 10/11 under `sim/flightmodel2/wing/`. Angles retain their raw signs. These are the current generic wing-array assumptions, not guaranteed mappings to every custom aircraft's animated mesh or actual surface combination.

Arrays prefer FlyWithLua zero-based tables. Direct XPLM access reads from zero through the requested index and accommodates returned table indexing. A readable interface does not automatically validate ENG2 or a particular surface's physical mapping; exercise left and right channels independently.

Control sampling targets roughly 100 ms within the trace, suitable for overall input/response trends but not reliable sub-100 ms latency measurement. The panel's visual pitch inversion represents push/pull direction and does not rewrite raw log signs.

Source: [S1 optional interfaces and source selection](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua#L228).

## 11 Engines, throttle and aircraft adapters

Aircraft context is refreshed when a new trace starts, supporting aircraft changes within one XP session. The count read from `sim/aircraft/engine/acf_num_engines` is bounded; the current recorder captures at most four engines. The analyzer's ability to parse additional columns does not mean the recorder already captures more than four.

### 11.1 N1 provider priority

| Aircraft family | Dedicated provider implemented in 1.1.8 | If unavailable |
| --- | --- | --- |
| Matched FlightFactor family | `1-sim/eng/N1/L`, `1-sim/eng/N1/R` | Generic chain |
| Zibo / LevelUp | `laminar/B738/engine/indicators/N1_percent_1`, `N1_percent_2` under the same prefix | Generic chain |
| ini A300 | `A300/engine/engine1_N1`, `A300/engine/engine2_N1` | Generic chain |
| Rotate MD-11 | `Rotate/aircraft/systems/eng_n1` array | Generic chain |
| ToLiss | No separate dedicated N1 provider | Generic chain |
| Other/unmatched aircraft | No selected dedicated provider | Generic chain |

These are implemented probe paths in public source, not a claim of validation across every aircraft/version from each developer. Aircraft identity/ICAO matching and required handles must qualify before a provider is selected. Compare against the actual cockpit instrument.

The generic chain is `sim/cockpit2/engine/indicators/N1_percent`, then `sim/flightmodel/engine/ENGN_N1_`. Each engine/sample checks the valid range 0 through 200. An invalid dedicated value can fall back to generic data; if none is valid, it is missing. This wide range rejects obvious corruption, not a plausible value that differs from the cockpit.

The report records the set of sources used during the segment, not complete per-sample, per-engine provenance. Do not multiply generic N1 by an arbitrary fixed ratio to force instrument agreement, or interpret N1 percent as thrust percent.

### 11.2 Throttle and Airbus detents

The script reads `throttle_ratio`, `throttle_jet_rev_ratio` and `throttle_beta_rev_ratio` under `sim/cockpit2/engine/actuators/`, choosing forward/reverse/Beta handling using `acf_en_type`. Types 5/7 prefer the jet-reverse axis; types 0/1/9/10 prefer Beta/reverse. Negative values are preserved, not universally clipped to zero through one.

The current ToLiss branch uses `AirbusFBW/throttle_input` and `AirbusFBW/THRLeverMode`. Family styling can identify Airbus-like axes, but valid detents depend on dedicated data. An Airbus ICAO alone does not guarantee usable detents.

Lever mapping is ordered: < -0.001 is REV; magnitude <= 0.015 is IDLE; >= 0.97 is TOGA; 0.80 through 0.93 is FLX/MCT; 0.62 through 0.75 is CL; otherwise MANUAL; invalid is N/A. These are implementation ranges, not an aircraft developer's contractual detent specification.

### 11.3 Power type is not aircraft energy state

The analyzer can parse N1, EPR, propeller and torque types and use appropriate scales. The 1.1.8 Lua recorder, however, still centers its general output on N1; it does not implement universal automatic EPR/propeller/torque acquisition. Display-format support must not be described as implemented acquisition coverage.

Throttle position, N1, EPR, power and total aircraft energy have different physical meanings. They cannot simply be combined into a dimensionless “thrust support” value. There is no current composite energy-rating or energy-curve algorithm, and power channels do not change landing ratings.

Sources: [S1 engine providers and sampling](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua#L268), [S2 power parsing](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/LMM_Report_Reader.html#L790).

## 12 TXT reports, diagnostics and disk writing

Reports are stored locally in `LMM_Log`, with airport, aircraft, runway, timestamp and `_CN`/`_EN` in the filename. The timestamp is frozen wall-clock date/time, whereas analysis windows use running time. These clocks are not interchangeable. Reports are not a fixed-offset binary protocol: parsers must recognize bilingual keys, column headers and missing values.

| Layer | Contents and review scope |
| --- | --- |
| Summary | Final FPM, G, rating, aircraft, weather, airport and runway status |
| Diagnostics | Three FPM candidates and selection reason; fixed/full/equivalent G, closure error and method |
| Trajectory table | Roughly 0.25 s aggregated data, touchdown anchor and extended capture |
| Control table | Roughly 0.10 s valid channels, per-engine columns and source descriptions |
| Optional mathematical audit | Frame samples and calculations around first/second contact, subject to bounded buffers |

An ordinary aggregated TXT cannot fully reconstruct the original per-frame P75, Theil-Sen pair set or impulse integral. For strict reproduction, enable the relevant mathematical-audit option before the flight and check sample counts, spans and limited flags. Showing Debug information does not automatically provide every unaggregated original sample.

See section 03 for scheduling delays. The entire text payload is first built in one protected call, then written at up to 8192 bytes per frame. Completion is announced only after the file closes successfully. Improvements come from deferral and chunked disk writes; payload construction is not a per-frame coroutine and has no guaranteed hard execution-time budget.

Write failure is logged and flight monitoring continues. Interruption may leave a partial report. The analyzer or an external consumer should check required fields, table completeness and usable sample counts rather than treating file existence as proof of completeness.

Successful writing appends the in-memory record index instead of rescanning the directory. Normally the landing popup flashes “Landing report generated” three times; Debug enables detailed bottom-of-screen paths. A pending centerline field can update later, so placeholder text in the first popup is not the final report.

Sources: [S1 payload construction](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua#L7810), [incremental jobs](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua#L8335).

## 13 Analyzer, UI and interpretation limits

`LMM_Report_Reader.html` is the bundled local analyzer. The separate `Starlux_Analyzer_落地分析器.html` opens without XP and isolates its browser-preference space. Reading a TXT neither rewrites the original report nor uploads the flight record.

Primary/comparison traces, 100 ft parameters, controls, surfaces, throttle instruments, XYZ indicators and the mini runway share a chart time position. Playback supports a minimum of 0.25x and progress scrubbing. It browses existing samples rather than recalculating flight dynamics. Without hover/playback positioning, neutral instruments may be an idle presentation, not measured zero input.

Different-unit curves are normalized independently; the same parameter shares a range between primary and comparison records. Overlapping curves with different units do not represent equal physical quantities. Use hover values, units, raw tables and source labels. A common full-scale power gauge is also not a physical cross-aircraft thrust normalization.

Fused mode combines controls into the 100 ft chart. Its Pitch/Roll become control parameters, replacing the original aircraft attitude angles. Check labels, units and legends before interpreting them; separated mode makes input versus attitude easier to distinguish.

The mini runway aligns existing timing and ground-speed integration information; it is not a ground track reconstructed from per-frame coordinates. The main runway view retains matched geometry, but width, markings and lighting symbols are adapted for readability. Its generic 7.5-degree pitch reference is not an aircraft-specific tail-strike limit.

RGB themes, presets, horizontal layout, zoom and fusion settings change presentation, not ratings. Curve colors may adapt to the background while fixed warning meanings are retained. Color must not replace rating text, line styles and numerical interpretation.

Standard uses one global Chinese/English setting for settings, popups, database notices, reports and an analyzer launched from the plugin. Historical Chinese reports can be reviewed in the English analyzer, while raw TXT, user-named presets and unrecognized free text may remain in their original language. Compatibility retains English legacy settings/record controls. Chinese reports and normal-size popups are supported, not a promise of complete native Chinese size support in old controls.

The installer queries GitHub/Gitee release catalogs and downloads packages; flight records are not used for update checks. Download hashes are not code signatures. Refer to release installation instructions for installation and backup boundaries.

Sources: [S2 analyzer](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/LMM_Report_Reader.html), [S3 release guide](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/README_1.1.8.md).

## 14 Review, testing and porting requirements

### 14.1 Recommended review order

1. Record XP, FlyWithLua, LMM and aircraft versions; confirm one active LMM main script and inspect missing-DataRef logs.
2. Verify raw contact time and transitions, ruling out replay, position jumps and discontinuous time. Do not compare a post-touch screenshot with a pre-touch statistic.
3. Recalculate candidates and validity using section 04, checking final source and integer rounding.
4. Separate raw G, attitude projection, fixed P75, full-interval quality and fallback choice, then inspect closure. LOW alone does not establish an invalid rating.
5. Verify scenery priority, frozen position, motion direction, displaced threshold and centerline distance before checking bounce/centerline adjustments.
6. Move only one input axis or engine lever at a time; compare left/right channels, zero input, reverse and detents, retaining the corresponding TXT.

### 14.2 Minimum test matrix

| Test | Implementation behavior to inspect |
| --- | --- |
| No-bounce touchdown | Normally about two seconds of continued recording; final result and touchdown anchor retained |
| Brief contact chatter | No confirmed bounce unless duration and height/upward-velocity conditions qualify |
| Confirmed second touch | Secondary sampling and one adjustment, not unlimited accumulated touch penalties |
| Low FPS / missing frames | Visible fallback method when fixed-window or full-interval quality is insufficient |
| High FPS | Check that the 256-sample ring covers required time windows |
| Parallel runways / missing airport | Explicit ambiguity or missing-candidate failure, not invented runway labels |
| Added / disabled / replaced scenery | Unchanged shards reused, changed shards updated, cache rebuilt when necessary |
| ENG1 / ENG2 exercised separately | Independent values and correct sources, not copied ENG1 values |
| CN / EN and both UI editions | Same data algorithm with explicit compatibility-language limitations |
| Interrupted write or exit | Partial reports and incomplete caches not treated as complete |

This is a proposed verification matrix, not a claim that this manual was tested in-simulator on every aircraft and frame-rate combination. Work for this edition consists of public-source review, document numerical checks and layout checks. Physical data accuracy still requires traceable simulator test records.

### 14.3 A port requires more than renaming variables

A new platform must separately map contact state, upward-positive velocity, load definition, reference-point height, frame clock, surfaces and engine channels. Preserve explicit units, missing-value flags, timestamps, statistical windows and provenance. First validate percentiles, rounding, boundaries and fallbacks with shared synthetic samples, then validate physical meaning with measured records.

Fields called “G”, “AGL” or “N1” in another SDK/simulator are not necessarily equivalent. The normal-load projection approximation, aircraft-provider differences and AGL reference issues do not disappear by rewriting in C++/XPL. Full three-axis loads, per-sample provenance, more power types, strict execution-time budgets, platform ports and longer-flight capture are future research areas, not delivered 1.1.8 capabilities.

## 15 Source index and revision history

Links are pinned to one commit so subsequent main-branch edits do not silently change this manual's reference. Prefer function names over line numbers when navigating.

| Topic | Main-script locator |
| --- | --- |
| Acquisition contract and aircraft adapters | `LMM_DATAREF_SPECS`, `LMM_CONTROL_REFS` |
| Percentile and median | `scratch_percentile`, `scratch_median` |
| First-touch FPM | `analyze_landing_velocity` |
| Fixed-window G and impulse | `calculate_local_event_g`, `analyze_landing_impulse` |
| Extended trace and flare | `start_flare_trace`, `update_flare_trace`, `analyze_flare_curve` |
| Bounce and base grading | `process_bounce_monitor`, `classify_landing` |
| Runways and cache | `parse_runway_row`, `runway_state`, `runway_config` |
| Deferred jobs and disk writes | `schedule_landing_jobs`, `process_landing_jobs`, `process_incremental_landing_log_write` |
| Main event loop | `ma_landing_meter_update` |

S1: [1.1.8 main Lua script](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/StarLux_LMM_v1.1.8.lua). S2: [bundled HTML analyzer](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/LMM_Report_Reader.html). S3: [1.1.8 installation and compatibility](https://github.com/Starlux531/StarLux-Landing-Meter/blob/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/README_1.1.8.md). S4: [UI modules](https://github.com/Starlux531/StarLux-Landing-Meter/tree/6a1c62ab433a764afecb14e98fb7f1b4b91f548e/LMM_UI_118).

Baseline SHA-256 values identify the working-copy bytes read for this edition:

`StarLux_LMM_v1.1.8.lua`

`9acfc57f4f410c5aa6123845e4aa9a3dfa44338f5f4cafb6631ad10218445a44`

`LMM_Report_Reader.html`

`6dfefa42d0f662dba9ed2f4105903f2e1168c17dd2616f6a3f2ed5a3c8decfa7`

Git checkout line-ending conversion can change byte hashes; the commit is the primary implementation identifier. Chinese and English editions share section numbers, formulas and boundaries. Update both Markdown sources, regenerate both PDFs and record the plugin version/source commit for future revisions.

Revision: 2026-09-14, Manual 1.0 Final. Replaces the 0.8.2 prerelease algorithm description with 1.1.8 FPM/G, extended trace, bounce, centerline, airport caching, control/power interfaces and local-analyzer boundaries. This release changes documentation only, not the plugin, installer or landing algorithms.

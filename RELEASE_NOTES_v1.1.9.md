# StarLux LMM 1.1.9 · 正式版 / Stable

发布日期 / Release date: 2026-09-23

## 中文

1.1.9 将落地复盘扩展为从进近至低速滑跑的完整过程。本版基于 beta10 最终功能正式发布。

- **连续录制**：下降进入 2500 ft 地形 AGL 后开始，全程记录可用的轨迹、FPM、G、姿态、操纵、舵面及发动机数据；接地后地速低于 30 kt 连续两秒结束。低空载入、存档恢复和数据缺段会如实标记；机场海拔不作为启动高度。即时弹窗与后台连续录制独立。
- **完整复盘**：完整记录并入原时间轴，支持 100 ft 聚焦、全程、播放、平移与显式缩放。触地俯视图显示滑跑路线，落地俯视图显示全程航迹、同步位置与风箭头；右侧竖向图放大选定区间的 LOC / 中线偏差，保留风向切换。旧 TXT 继续可读。
- **风与 ILS 参考**：风按可配置间隔记录，实时覆盖层独立逐帧显示当前位置风。ILS 采用 XP 导航资料推导的几何参考，不依赖机模接收机；分析器固定显示 LOC / GS，无有效参考时为 INOP。游戏覆盖层不显示 ILS。
- **弹跳与滑跑评分**：弹跳识别不再受首次触地后六秒窗口限制；最终报告同步完整会话结果。仅对可靠跑道几何、地面 GS ≥60 kt 样本判定中线偏差与左右摆动，过滤低速脱离。规则见下表。
- **游戏界面**：独立操纵 / 油门 / N1 覆盖层支持拖动、边缘缩放、配色及折叠；贴边快捷按钮可沿侧边拖动。操纵区保持正方形，绿色输入点、两侧外段黄色 Roll 虚线与固定长度风箭头同时保留。N1 反推显示 R 与红色数值。调试模式可检查和选择输入来源。AP / AT 监测和断开提示已移除。
- **性能与安装**：覆盖层按帧更新并复用绘图缓冲；分析器悬停复用静态绘图，避免重复计算完整记录。完整包内置安装器 1.0.1，支持清理旧插件文件、诊断、修复、备份和保留配置安装。

| 滑跑触发条件（仅地面 GS ≥60 kt） | 处理 |
| --- | --- |
| 同一连续高速段左右两侧均超过 5 m，峰峰摆幅 >10 m | 非红降一级；单侧回中不计，路程不累计 |
| 绝对中线偏差 >5 m / >7 m | 非红降一级 / 至少黄色 |
| 超过 9 m 后连续 3 秒未回到 ±7 m 内 | 红色 |
| 连续 5 秒未回到 ±3 m 内 | 非红降一级 |

各项只触发一次，普通降级最多到黄色；原有红色不会提升。中英文报告保留处罚原因和触发证据。已有触地 FPM / G 算法保留。

### 下载与兼容

- **国内完整包**：`StarLux_LMM_Installer_1.1.9_CN.zip`。
- **海外完整包**：`StarLux_LMM_Installer_1.1.9_EN.zip`，归档内所有文件名为英文 / ASCII。两包包含相同安装器与四种插件载荷。
- **已有安装器**：联网刷新版本，选择 `1.1.9`。Standard / Compatibility × CN / International 四个小 ZIP 为可识别安装载荷；无需下载全部。
- **Standard**：Windows x64、XP 12.4.4+、FlyWithLua NG+。**Compatibility**：旧 XP 12，使用传统设置控件和数字覆盖层。CN / International 只影响首次默认语言，已有配置优先。Windows 安装器不支持 macOS / Linux。
- `Starlux_Analyzer_1.1.9.zip` 为独立分析器；`StarLux_LMM_Installer_Only_1.1.9.zip` 为安装器单独下载。FlyWithLua 不随包分发。发布资产附 `SHA256SUMS.txt`。

大盘分析仍为独立验证原型，不纳入本次正式安装包；游戏内实时 G 曲线及进一步机模适配留待后续。自定义机模未提供的输入仍可能缺失；ILS REF 是几何复盘参考而非实测射频信号。

## English

Version 1.1.9 is stable, based on the final beta10 implementation.

- Continuous recording from a descending 2500 ft terrain-AGL approach through grounded rollout below 30 kt for two seconds. Low-altitude loading, resumed flights and missing intervals are identified rather than reconstructed. Available position, FPM, G, attitude, control, surface, engine and wind data share one timeline.
- Full-flight playback, a 100 ft focus, explicit zoom/pan, touchdown rollout mapping, landing plan view and a magnified vertical detail chart. Historical TXT reports remain readable. Static chart reuse reduces hover work.
- Recorded wind history plus independently refreshed live wind arrows. LOC/GS analysis uses XP navigation geometry, not aircraft receiver state. Analyzer instruments remain visible and show INOP without valid reference; live overlays contain no ILS instruments.
- Bounce monitoring covers the continuous landing session instead of a six-second cutoff. Rollout grading uses reliable runway geometry and grounded GS >=60 kt only: excursions >5 m step down one non-red grade; >7 m means at least yellow; >9 m followed by three seconds outside +/-7 m means red; five seconds outside +/-3 m adds one non-red step. Both sides beyond 5 m and a span >10 m count as a sway event. Each rule latches once; ordinary steps cap at yellow. Existing touchdown FPM/G calculations remain unchanged.
- Movable/resizable/collapsible input, throttle and N1 widgets; draggable edge shortcuts; square input pad, bright-green input marker, outer-quarter Roll dashes, fixed-size wind arrows and red reverse-thrust N1 indications. Debug mode exposes input-source selection. AP/AT monitoring, servo substitution and disconnect alerts are removed.

**Download:** choose the CN or EN complete offline bundle, both including installer 1.0.1 and four plugin variants. EN uses ASCII archive filenames. Existing installers can discover the four `StarLux_LMM_v1.1.9-*.zip` assets online. Standard targets Windows x64 / XP 12.4.4+ / FlyWithLua NG+; Compatibility targets older XP 12 with legacy controls and numeric overlays. Existing settings take precedence over CN/International defaults. FlyWithLua is not bundled; the installer is Windows-only. Checksums are provided.

The standalone trends prototype is outside this stable bundle. Aircraft-specific input availability, additional platform support and live G plots remain future work. Offline regression and package checks do not certify every aircraft or simulator configuration.

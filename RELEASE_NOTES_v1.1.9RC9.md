# StarLux LMM 1.1.9RC9 · 公开稳定发行 / Public stable release

## 1.1.9RC9 · 公开稳定发行 · 2026-10-10

累计范围：**公开版 1.1.9rc4 → 1.1.9RC9**；安装器 **1.0.3 → 1.0.4**。上一公开版为 `v1.1.9rc4`（2026-09-30），本次插件 Latest 更新为 `v1.1.9RC9`。RC5–RC8 的本地迭代按最终行为合并，不重复列出已替换的方案；本次同步发布中英文 RC9 包和安装器 1.0.4。

### 接地分析与弹跳识别

- 改进长起落架、延迟压缩和宽峰接地的 G 值观察：保留原短峰固定窗口，出现持续且有速度或高度证据支持的延迟载荷峰时，使用相应稳健窗口；单次观察有时间上限，不直接用单帧尖峰替代评分。
- 修复局部高度基准和物理垂直速度不一致时的低弹跳漏判，以及快速连续触地漏判。连续触地分别记录事件，普通弹跳按既定规则降级，后续严重接地仍可升级为红色。
- 报告补充接地事件、观察窗口、质量、观测峰值和弹跳证据；分析器显示再次触地标记。保持旧日志原有评分，不以低频轨迹强行重算。

### 游戏内弹窗、实时组件与设置

- 默认显示模式为「触地后立刻弹出」：触地即展示完整弹窗，G 值观察期间动态更新，确定着陆值后固定；弹窗不再等待地速降到 30 kt，后台仍继续记录后续弹跳与滑跑。
- 独立「即时演算」模式排在显示选项首位：记录器从约 2,500 ft AGL 启动时显示紧凑 G/FPM 状态面板，并提示记录器开始工作、记录中；触地后展开完整弹窗，结果生成闪烁两次，按设置关闭。地速低于 30 kt、停稳 10 秒和不自动显示等模式保留。
- 新增独立实时 G、FPM 及 G+FPM 组件；黄/红等级用相应数字颜色提示，峰值单独保留。显示按帧刷新，不增加文件记录频率，关闭面板不影响记录。
- FPM 数值标明来源。独立 FPM 组件支持多选 VVI、物理垂直速度和 AGL 高度变化估算，新配置默认全选；即时演算单独选源，默认 VVI。保留已有用户设置，缺失来源不猜测。
- 贴边快捷按钮移到通用设置的语言选项后；取消「贴右侧」选项，新配置默认允许拖动，可关闭布局编辑。
- 实时视图改为分组、多列布局，直接选择实时 FPM / G / G+FPM，以及油门杆 / N1 / 油门杆+N1；减少空白，保留操纵与风向设置。
- 兼容版快捷按钮默认淡色小方框，可调整大小、透明度、明暗或隐藏；兼容版设置、记录等游戏内界面统一英文，语言选项仅控制报告输出，避免中文乱码。

### 网页分析器

- 预览图与中英文即时演算动画已更新，保留旧图集。G 双指针展示触地读数与接地观测峰值的差距，便于识别延迟压缩等过程中单一读数隐藏的信息；不是置信区间，不改变既有 FPM/G 评分。

- 2026-10-10 同版本默认项调整：每次打开分析器自动启用 OSM 底图、路径风向和竖向细节，右侧默认风向，地图首次完整路线视图缩放为 0.71×；已有安装同步采用这些启动默认值，不清除其他保存偏好。当前会话仍可切换视图；地图按需加载及离线回退保留。

- 落地俯视图增加可选 OpenStreetMap 底图，由 OpenFreeMap 提供；按真实经纬度同步展示航迹、跑道、风和 LOC 几何参考。
- 俯视图支持单独放大及模块内回放控制，保留竖向细节与同步时间轴；悬停不改变视区，网络或 WebGL 不可用时回退原轨迹图。
- 地图库随 HTML 内置，地图按需初始化，复用浏览器缓存及有限瓦片缓存，分离静态图层与动态游标并使用样本空间索引；底图数据仍需联网，飞行日志在本地处理。
- 载荷卡并列显示「触地瞬时」和「观测峰值」，对比记录同步展示；G 严重度条使用两个指针与连接区间，修正刻度位置。缺少峰值的旧日志显示未记录，不补零、不取全程滑跑最大值。
- 拉平曲率增加「数值越小拉平越平顺」；下降率轨迹震荡高显示橙色，正常显示绿色，缺失结论保持中性色。
- 评分构成恢复原有 FPM/G 主导关系说明，保留中心线和滑跑等原有优先提示。本次定稿不更改评分规则，也不改变游戏内 G 弹窗展示；网页「触地瞬时」继续使用原报告显示字段。

### 性能、导出与状态提示

- 提前准备触地弹窗，复用文字宽度、字体度量和布局；可整行容纳的内容跳过逐字换行测量，减少触地展开时的集中排版开销。
- 报告采用分段生成、稳定章节缓存与有界分块写入。后台工作随帧时间及任务耗时调整批次，触地初期保护和慢磁盘减量保留；优化批次合并，避免过度延后报告导出。
- 分离最后一次写入与提交，校验会话及数据版本，保留临时文件、旧报告和中断恢复片段；报告计算使用独立缓冲区，不干扰实时接地分析。
- 落地弹窗原提示行在导出期间显示「报告导出中，请勿关闭游戏」，完成后原位替换为「落地报告已生成」，失败也在同一行说明。早期摘要不会误报完整报告已完成。
- 调试模式提供低频、有界的 RC9 PERF 耗时汇总，便于核查弹窗和导出开销；不常态逐帧刷日志。

### 配套安装器 1.0.4（相对 1.0.3）

- 安装器更新按钮合并至顶部更新卡片；有新版时红色闪烁并可点击，显示「安装器有新版本，点击此处更新安装器」，无更新、检查中或忙碌时不可点击。
- 保留配置、纯净重装、取消分别使用绿、橙、红边框；下一步将确认安装放在首位，使用绿色渐变脉冲边框，取消保持红色。
- 安装变更清单默认优先显示替换、删除、新增和重置；点击列标题可排序，文件大小按真实字节数排列。
- 保留的飞行记录默认折叠，可展开查看；涉及删除等变更的记录仍直接显示，复制清单包含全部文件。
- 内嵌压缩后的机场照片；启动以完整照片和「starlux slm」展示 1.5 秒动画，之后照片持续作为毛玻璃背景。背景缓存与局部按钮重绘减少额外开销。
- 完整 CN/EN 安装包均携带当前 RC9 的 Standard/Compatibility × 中/英文四种载荷，保留既有文件诊断、详细输出、完全卸载及事务恢复能力。

### 后续版本

RC9 进入稳定阶段，下一版本直接进入 **1.2.0 原生 XPL 重写**，脱离 FlyWithLua，并为多平台移植打基础。1.1.x 不再安排后续错误修复版本，问题记录留作 1.2.0 参考。第三方更新器、基础 QAR 事件及进近平面图导航层仍属后续计划，不包含在 RC9。

验证记录与发布检查见 [RC9 发布准备](docs/1.1.9RC9_发布准备.md)。离线检查不等于所有机模、机场与存储环境均已实机验收。

## English — changes since public 1.1.9rc4

October 10 default adjustment: every analyzer launch enables OSM, wind along track and vertical detail, with the wind profile selected and initial map scale at 0.71×. Existing installations receive the same launch defaults without clearing other saved preferences. Session controls, lazy loading and offline fallback remain available.

RC9 is the **public stable release dated October 10, 2026**. Bundled installer: **1.0.4**, replacing 1.0.3. Intermediate local iterations are consolidated into their final behavior.

- Bounded touchdown observation supports delayed compression and broader load peaks while preserving short-impact behavior. Sustained evidence is required; isolated spikes do not automatically become the rated G. Low rebounds and rapid successive contacts are detected more reliably, with event windows, quality and bounce evidence included in reports.
- The default **Show immediately at touchdown** mode opens the full popup at contact, updates values during bounded landing analysis, then holds the determined landing values while rollout recording continues. It no longer waits for 30 kt.
- Separate **Live calculation** starts a compact recorder panel around 2,500 ft AGL, shows recording status, expands at touchdown and flashes twice when the result is ready. Existing low-speed, stopped and manual display modes remain available.
- Optional live G, FPM and combined widgets refresh per frame without adding high-frequency file samples. FPM values identify their source. The independent widget supports VVI, physical vertical speed and AGL-derived estimates together, all selected for new configurations; live calculation has its own source selection, defaulting to VVI.
- Edge shortcuts move under General after language settings. New layouts are draggable by default. Grouped, responsive live-view settings provide direct G/FPM and throttle/N1 combination choices. Compatibility interfaces remain English, with report language selected separately; pale shortcuts can be resized, adjusted or hidden.
- The plan view gains an optional OpenStreetMap basemap supplied by OpenFreeMap, independent enlargement and synchronized playback. Local map-library assets, on-demand loading, bounded caches and separate static/dynamic layers reduce repeated work. Map data needs internet access; failures fall back to the original trace view. Flight records remain local.
- Web load cards and comparisons show instantaneous touchdown and observed-peak G separately, with a two-marker range on the severity bar. Missing observations remain unavailable. The instantaneous label continues to use the report display field. The usual FPM/G dominance explanation is restored; this finalization does not change grading or the in-game G popup.
- Flare curvature explains that lower values indicate a smoother flare. High trajectory oscillation is orange, normal is green and unavailable conclusions remain neutral.
- Cached/prepared popup layouts reduce concentrated touchdown work. Incremental report generation, reusable sections and adaptive bounded writes spread background work across frames; export batching is tuned to avoid excessive delay while retaining contact and slow-storage protection.
- The landing popup displays **Exporting report - please do not close X-Plane** in the normal report-status row, replacing it when export succeeds or fails. Session checks, temporary commits and recovery fragments protect report consistency. Optional low-frequency RC9 PERF diagnostics help investigate remaining stalls.
- Installer 1.0.4 combines self-update with the top update card, which flashes red and becomes clickable only when an update is available. Green/orange/red action borders distinguish keep-settings, clean-reinstall and cancel; install confirmation comes first with a green pulse.
- File review prioritizes changes, supports column sorting and collapses preserved flight records while keeping destructive changes visible. A 1.5-second full-photo startup animation transitions to a persistent cached frosted background. CN and ASCII-path EN bundles include all four RC9 variants.

The next release line is **1.2.0**, a native XPL rewrite moving beyond FlyWithLua and preparing for multiple platforms. No further 1.1.x bug-fix releases are planned. Third-party updater integration, basic QAR events and advanced navigation layers remain future work. Offline checks do not establish simulator FPS gains or universal aircraft compatibility.

## 新版预览 / New previews

接地载荷会随着轮胎接触、起落架压缩和可能的再次触地而变化，单一读数容易隐藏后续峰值。RC9 并列显示报告中的触地读数与接地事件观测峰值，并以双指针连接，方便看清两者差距。因此它比孤立的一个数值提供了更多可核查的接地信息；该区间不是统计置信区间，原始观测峰值也不直接替代评分 G，评分继续结合既有 FPM/G 规则。网页“触地瞬时”目前沿用报告显示字段，不代表重新提取了原始触地单帧。

Landing load changes through wheel contact, gear compression and possible subsequent contacts. A single reading can hide a later peak. RC9 shows the report's touchdown display value alongside the observed touchdown-event peak, connected by two markers, making their difference visible and easier to inspect. This provides more context than one isolated number; it is not a statistical confidence interval, and the raw peak does not automatically replace the rated G. Existing FPM/G grading remains unchanged. “Instantaneous touchdown” currently uses the report display field, not a newly extracted touchdown-frame sample.

### 触地弹窗与观测峰值 / Touchdown popup and observed peak

弹窗显示带来源的 FPM、着陆 G 与单独保留的观测峰值；即时演算提前显示记录状态，触地后展开完整结果。

Source-labeled FPM, landing G and the observed peak appear together. Live calculation starts with recorder status and expands at touchdown.

![RC9 触地弹窗](https://raw.githubusercontent.com/Starlux531/StarLux-Landing-Meter/v1.1.9RC9/docs/images/rc9-touchdown-popup.png)

### OSM 地图与同步复盘 / OSM map and synchronized review

默认启用 OSM、路径风向与竖向细节，支持独立放大及同步播放；截图展示用户切换至 LOC 几何参考并放大的视图，并非初始默认倍率。

OSM, wind along track and vertical detail start enabled, with independent enlargement and synchronized playback. This screenshot shows a zoomed-in LOC-reference view; the default side view is wind, with an initial map scale of 0.71×.

![RC9 OSM 与 LOC 复盘](https://raw.githubusercontent.com/Starlux531/StarLux-Landing-Meter/v1.1.9RC9/docs/images/rc9-osm-plan.png)


![G range](https://raw.githubusercontent.com/Starlux531/StarLux-Landing-Meter/v1.1.9RC9/docs/images/rc9-g-range.png)

![CN live calculation](https://github.com/Starlux531/StarLux-Landing-Meter/releases/download/v1.1.9RC9/RC9-Live-Calculation-CN.gif)

![EN live calculation](https://github.com/Starlux531/StarLux-Landing-Meter/releases/download/v1.1.9RC9/RC9-Live-Calculation-EN.gif)

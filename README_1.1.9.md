# StarLux LMM 1.1.9 正式版 / Stable release

2026-09-23：1.1.9 正式发布，以 beta10 的最终功能为基线。覆盖层、连续录制、风序列、完整复盘与 GS ≥60 kt 滑跑评分已纳入本版。安装器可从 GitHub 发现四种 UI / 语言载荷；完整离线包内置安装器 1.0.1。

Released on 2026-09-23, based on the final beta10 implementation. Includes live overlays, continuous recording, wind history, synchronized analysis and rollout grading at GS >=60 kt. Four UI/language packages are discoverable by the installer; offline bundles include installer 1.0.1.

[下载正式版 / Download](https://github.com/Starlux531/StarLux-Landing-Meter/releases/tag/v1.1.9) · [发行说明 / Release notes](https://github.com/Starlux531/StarLux-Landing-Meter/blob/v1.1.9/RELEASE_NOTES_v1.1.9.md)

[开发计划](docs/StarLux_LMM_v1.1.9_开发计划.md) · [工作区与检查命令](docs/WORKSPACE.md)

适用于 Windows 64 位 X-Plane 12，依赖 FlyWithLua NG+。本版仍为 Lua 插件，不是独立的 C++ XPL 插件。接地 FPM／G 计算保持原算法；1.1.9 另建连续记录与滑跑几何流程。

For Windows x64 and X-Plane 12 with FlyWithLua NG+. This is a Lua plugin, not a standalone C++ XPL plugin. Touchdown FPM/G calculation is preserved; continuous recording and rollout geometry are separate new workflows.

## 最终覆盖层行为（beta10 定稿）：外侧横滚虚线、移除 AP / AT 提示

- 黄色 Roll 虚线改为左右外侧各 25%，中间 50% 留空。水平时末端与固定十字横轴末端对齐，仍随实际横滚姿态旋转；十字区、窗口和文字尺寸保持不变。
- 根据机模实测反馈，彻底删除 beta9 新增的 AP / AT 状态探测、伺服输入读取、AP 黄圈、AP / AT 字样及断开红闪。操纵标记始终使用已选输入来源的鲜绿色标记；来源无效时显示不可用。
- 保留逐发动机反推 `R1` / `R2` 和红色 N1 数值，保留实时风、YAW、调试来源、贴边拖动、字体透明度及折叠恢复。
- 精简后的只读显示模块仅处理横滚姿态、反推及回放保护，缓存句柄；仅显示油门或关闭相关组件时不读取这些状态。兼容版同样移除 AP / AT 文字和红闪，保留反推红字。

English: Roll dashes occupy the outer quarter on each side, leaving the middle half clear and rotating with bank. All beta9 AP/AT monitoring, servo substitution, labels, rings and disconnect flashes are removed. Selected pilot input stays bright green; reverse-thrust indications, wind, sizing, edge dragging, opacity and collapse/restore remain.

## beta9 保留的交互改进

- 两个快捷按钮各自沿屏幕边缘上下拖动，拖动不会打开菜单；松开保存位置。透明度同时作用于背景、边线和字体，悬停显示清晰文字。
- 标准图形覆盖层右上角 `−` 可折叠为半透明名称条，点击名称条恢复。折叠不改变保存的大小和坐标；标题拖动、边缘缩放及原大小按钮保持可用。
- N1 按发动机显示反推，标签变为 `R1` / `R2`，数字变红；不把螺旋桨 beta 区当成反推。兼容版保留既有数字界面及对应反推文字。

## beta8：滑跑中心线正式考核

仅使用可靠跑道几何与地速 **GS ≥60 kt** 的地面样本（60 kt 计入）。沿跑道方向左正右负。

| 触发条件 | 处理 |
| --- | --- |
| 同一连续高速滑跑段左右两侧均超过 5 m，峰峰摆幅超过 10 m | 非红降一级；不累计走过的距离，单侧回中不算摇摆 |
| 偏差绝对值 >5 m | 非红降一级 |
| 偏差绝对值 >7 m | 至少黄色 ATTENTION，原红色不会提升 |
| 曾超过 9 m，连续 3 秒未回到 ±7 m 内 | 红色 UNSTABLE；回到 ±7 m 内解除计时 |
| 连续 5 秒未回到 ±3 m 内 | 非红降一级 |

每项每次落地最多触发一次；5 m 与 7 m 是同一偏差项目的递进处理。不同普通项目可以叠加，最多至黄色。既有触地 FPM/G、触地点偏差和弹跳规则保留；本项不降低已存在的红色严重程度。

低于 60 kt、离地、暂停、回滑或数据间隙会打断连续判定，不清除已经确认的处罚。两侧符号翻转说明中途经过中心区域，不将这段误算成连续未回中。跑道异步识别期间最多缓存 600 个样本（约一分钟），识别后补判；无可靠跑道则注明未参与。

中英文 TXT 写明规则、阶段、评分、最大偏差、跨度、连续超限时间和每项触发时刻 / 地速。即时弹窗保持阶段快照，滑跑触发时刷新等级，录制结束后重建最终报告。分析器展示已记录的滑跑处罚，不用新规则重评旧日志。

English: grounded GS >=60 kt only. Both sides beyond +/-5 m with >10 m span: one non-red step. Absolute offset >5 m: one step; >7 m: at least ATTENTION. An excursion beyond 9 m starts a 3 s timer, cancelled only on recovery to <=7 m; expiry sets UNSTABLE. Remaining outside +/-3 m for 5 s adds one non-red step. Rules latch once; ordinary steps cap at ATTENTION. Gaps, low speed and airborne phases interrupt timers. Reports preserve event evidence and distinguish provisional and final states.

## 正式发行包 / Release packages

| 文件 / File | 用途 / Purpose |
| --- | --- |
| `StarLux_LMM_Installer_1.1.9_CN.zip` | 国内完整离线包：安装器和 version 文件夹 / Complete offline bundle |
| `StarLux_LMM_Installer_1.1.9_EN.zip` | 海外完整离线包：所有归档路径使用英文 / Offline bundle with ASCII filenames |
| `StarLux_LMM_Installer_Only_1.1.9.zip` | 安装器单独下载 / Installer only |
| `Starlux_Analyzer_1.1.9.zip` | 独立分析器 / Standalone analyzer |
| `StarLux_LMM_installer_安装器.exe` | 仅安装器；联网选择版本 / Installer only; select an online release |
| `StarLux_LMM_v1.1.9-Standard-CN.zip` | XP 12.4.4+ 标准 UI，默认中文 / Standard UI, Chinese default |
| `StarLux_LMM_v1.1.9-Standard-International.zip` | XP 12.4.4+ 标准 UI，默认英文 / Standard UI, English default |
| `StarLux_LMM_v1.1.9-Compatibility-CN.zip` | XP 12、12.4.4 之前，旧 UI 兼容，默认中文输出 / Pre-12.4.4 legacy UI, Chinese output default |
| `StarLux_LMM_v1.1.9-Compatibility-International.zip` | 同上，默认英文 / Same legacy edition, English default |
| `Starlux_Analyzer_落地分析器.html` | 双击独立运行，不需要模拟器或安装器 / Standalone analyzer; no simulator or installer required |
| `analyzer-presets.json` | 随包预设的可读备份 / Readable copy of bundled presets |

CN 与 International 只改变首次安装时的默认语言；已有 `LMM_Settings.cfg` 优先，升级不会覆盖用户的语言、设置、日志或机场缓存。两个 UI 版本主脚本文件名相同，切换时替换，不可同时启用。

CN and International differ only in the default language when no settings file exists. Existing settings, language, logs and airport cache are preserved. Both UI editions use the same main-script filename: replace the edition, never run two copies.

标准版依赖 SDK 440 和完整字库能力，缺少能力时自动回退。兼容版明确禁用新的 SDK 440 字体接口，即使在新 XP 上运行也使用传统 UI。旧 FlyWithLua ImGui 字库不能保证中文，因此兼容版设置和记录窗口使用英文控件；中文报告保留，中文落地弹窗使用标准字号。兼容版不承诺新原生 UI 的连续中文字号和真实字重能力。

Standard requires SDK 440 and the font API; unavailable capabilities trigger fallback. Compatibility explicitly skips SDK 440 font calls, including on newer XP. Legacy FlyWithLua's ImGui atlas cannot guarantee CJK glyphs, so compatibility settings/records use English controls. Chinese reports remain supported and the Chinese popup uses the normal font size. Native continuous Chinese font sizing and true font weights are not available in legacy UI.

## 新功能试用 / Trying the new features

在设置的“实时视图”页开启独立组件、编辑布局或设置风间隔；调试模式提供逐轴来源切换，保存机模选择后与其他配置一起写入 `LMM_Settings.cfg`。默认贴边按钮可打开设置／记录栏，也可隐藏或换边。

录制从 2500 ft 地形 AGL 或低空载入的有效片段开始；即刻接地弹窗不会中断长记录。接地后地速严格低于 30 kt 连续两秒结束，无需出口网络；加速、离地、暂停或间隙会重置计时。原始流保留在 `LMM_Log/.LMM_Recording_*.part`，恢复方法和限制见[开发验证](docs/StarLux_LMM_v1.1.9_开发验证.md)。分析器把完整记录并入原 100 ft 图表，支持缩放、横向浏览与播放跟随；主图风速为可选项，风向与侧风移至落地俯视图。“触地俯视图”显示滑跑，“落地俯视图”显示全进近路线及同步风箭头，可放大查看中线偏差。缺段本身不扣分。

Enable widgets, edit their layout and adjust wind sampling in Settings → Live view. Debug mode adds per-axis source selection. Aircraft profiles share the existing settings file. Continuous recording runs independently of the touchdown popup and ends after two grounded seconds below 30 kt. The analyzer integrates the full recording into the existing timeline and retains a 100 ft focus.

FF777 专有输入尚未完成适配确认；旧 UI 的覆盖层为英文数字显示，未达到标准版图形／外观编辑等效。游戏内 G 曲线留待后续。滑跑降级已纳入 1.1.9 正式版；离线检查不代表覆盖所有机模与实际飞行情景。

FF777-specific input support, legacy graphical parity and in-game G curves remain future work. Version 1.1.9 is stable; offline checks do not certify every aircraft and flight scenario.

## 安装 / Install

1. 退出 X-Plane，解压完整安装包。顶层只有安装器 EXE 和 `version`。把文件夹放在有写入权限的位置即可，不必放在模拟器目录。
2. 运行安装器，核对自动找到的 XP 根目录，也可手动选择包含 `X-Plane.exe` 与 `Resources/plugins` 的目录。
3. 从版本列表选择标准版或兼容版。`【最新 / Latest】` 表示当前成功读取到的本地／在线目录中的最高版本，不代表兼容你选择的 XP；请核对兼容范围。首次打开默认选择最高版本的标准中文版，已有选择在刷新时保留。
4. 缺少 FlyWithLua 时由用户决定自动下载、选择本地官方 NG+ ZIP 或取消。离线 LMM 包不含 FlyWithLua；下载依赖仍需要联网。
5. 确认后安装；旧主脚本及被替换文件备份到安装器旁的 `backup`。保留此目录，以便安装器的“恢复备份”恢复。

Exit X-Plane, extract the bundle into a writable folder, run the installer and verify the detected simulator root. Select the edition matching your XP version. The bilingual Latest badge means the highest version in the successfully loaded catalog, not automatic simulator compatibility. A missing FlyWithLua dependency requires your consent to download or import. Modified files are backed up beside the installer; keep the backup folder for restoration. Existing user settings and landing reports are not overwritten.

手动安装单个插件 ZIP：只把 `payload` 内的文件复制到 `Resources/plugins/FlyWithLua/Scripts/`。先移出旧版 LMM 主脚本，保留用户配置与日志。`LMM_UI_119` 必须保持完整，不可把模块单独放到 Scripts 顶层。

Manual installation: copy the contents of `payload` into `Resources/plugins/FlyWithLua/Scripts/`, remove the older active LMM main script first, and retain your settings/logs. Keep the complete `LMM_UI_119` folder; do not place its modules at Scripts level.

## 菜单、语言与分析器 / Menus, language and analyzer

- FlyWithLua 菜单保留两个入口：`StarLux LMM | 设置 / Settings` 和 `StarLux LMM | 落地记录 / Landing records`。
- 标准版只有一个全局语言设置，统一界面、落地弹窗、TXT 输出以及从插件打开的分析器。切换语言后重新打开报告；历史 TXT 不会被改写。旧版 UI 例外见上方兼容说明。
- 设置按通用、位置、配色、字体、工具分组；滑块带明确拖柄，删除操作二次确认。
- 插件仍使用 `LMM_Report_Reader.html`。独立的 `Starlux_Analyzer_落地分析器.html` 无外部依赖；可任意移动，选择本地 TXT 进行分析／对比，自己选择中英文。
- 独立版使用单独的浏览器存储命名空间，不改动插件分析器的语言、缩放或个人预设。浏览器可能按文件位置隔离存储；移动文件或换浏览器后，已有个人设置未必跟随。
- 两个分析器内置作者授权的 5 个预设：默认、黑暗玫瑰、巨峰葡萄、未来展厅、水晶紫罗兰。仅在该分析器没有保存过预设时提供初始列表；不覆盖、重置或合并已有用户预设。名字在英文界面也保持原名。预设仅含 RGB、缩放、布局与曲线选择，不含飞行数据、个人 ID 或创建时间。旧“深／浅色”字段已去除。

Two separate menu entries open Settings and Landing records. Standard uses a single global language for plugin UI, popup, reports and plugin-launched analysis. Reopen the report after changing language; existing TXT files stay untouched. The standalone HTML has an independent settings namespace and its own language switch, with no external assets required. Both analyzers seed five author-provided presets only when no saved preset list exists; existing lists are never overwritten. Chinese preset names remain unchanged in English UI. Presets contain only theme/layout/chart choices, no flight data or personal identifiers.

## 更新、安全与限制 / Updates, safety and limitations

安装器只查询官方 GitHub／Gitee 仓库的 Releases；下载失败时尝试同名同版本备用源。两个平台是否同步取决于发布方，不能把尚未上传的版本视为已有镜像。文件有 SHA-256 校验和安装回滚，但安装器 EXE 尚未代码签名，Windows 可能提示未知发布者；不要关闭安全软件。插件和分析器不上传飞行记录，安装器仅联网查询版本／下载文件。

The installer reads official GitHub/Gitee Releases and falls back to an available matching archive. Mirror availability depends on publication; a new GitHub release is not automatically a Gitee release. File hashes and rollback are provided, but the EXE is not code-signed and Windows may show an unknown-publisher warning. Do not disable security software. Flight data remains local; only the installer queries/downloads releases.

当前标准 beta 的模拟器运行正常由作者确认。本次正式版离线回归不等于对所有 XP／机模／显卡组合的实测；旧版兼容包仍建议在目标旧 XP 中先预览弹窗、打开设置、重载脚本再飞行。无需也不应修改算法来切换 UI。

The author has confirmed the preceding standard beta working in their simulator. Release regression checks are offline, not a certification of every XP/aircraft/GPU combination. Preview the popup, open settings and reload the script in your target simulator before flight, especially for legacy UI. Switching UI editions does not change landing algorithms.

代码 MIT；随包 LMM UI 字体遵循 SIL OFL 1.1，许可位于 `LMM_UI_119/fonts/OFL.txt`。

Code: MIT. Bundled LMM UI fonts: SIL OFL 1.1; see `LMM_UI_119/fonts/OFL.txt`.

### 本轮安装与交互修订

正式离线包内置安装器 **1.0.1**，升级／修复会备份并移除旧 LMM UI 文件、空目录及确认属于 StarLux 的旧版本 README，保留配置、日志、机场缓存和未知用户文件。安装器无需删除整套 FlyWithLua。接地弹窗可直接拖动，松开保存位置；设置中的九宫格／复位可恢复锚点。

图表下方提供“100 ft／全程”、缩放和时间窗滑块；Ctrl＋滚轮缩放，Shift＋滚轮横移。俯视图点击路线可定位，1–64 倍缩放由 Ctrl＋滚轮、按钮或倍率选择控制；悬停只改变时间游标，视区和纵轴范围保持稳定。主动播放时可开启位置跟随。

落地俯视图加粗路线与跑道，风箭头以浅色叠在轨迹上，放大后仍按可见范围绘制。beta4 起“路径风向”和“竖向细节”可分别开关；默认竖向图展示飞机相对 LOC／跑道中线的偏差，也可切换为风向，与主图时间窗和游标同步。主图中的风参数只保留风速，XYZ 输入图同时显示相对机头的风吹向箭头及右侧磁来向／风速。地图使用真来向；箭头指气流吹去的方向。虚线为跑道延长中线，不代表已记录实际 LOC 信号；跑道设置最小显示宽度以便阅读，路线坐标仍等比例。

新记录从 2500 ft AGL 到滑跑结束，按 10 Hz 保留可用的物理 FPM、VVI、轨迹 FPM 来源、六个舵面角度、油门杆位置和卡位，以及原有的操纵、姿态、动力、位置等通道。海拔 6000 ft 的机场同样按离地 2500 ft 启动；低空载入标记前段缺失。旧日志中未记录的数据无法补回，继续显示缺失。覆盖层输入按模拟器帧更新，不再固定为 20 Hz；磁盘录制采样独立，实际显示流畅度仍需实机验证。

Zoom uses Ctrl + wheel, explicit buttons or magnification controls. Hover only seeks time and does not change map position or chart scales. Pale track wind arrows remain visible when zoomed. From beta4, the vertical detail shows aircraft LOC or runway-centerline deviation using the same time window and cursor, with a selectable wind-direction view. The main chart retains wind speed. The XYZ pad shows nose-relative wind flow, with magnetic wind-from direction and speed on its right. New recordings include available FPM/VVI, control surfaces and lever/detent channels throughout the approach and rollout. Start height is 2500 ft AGL, including high-elevation airports. Missing historical channels remain unavailable. Overlay inputs update per simulator frame; disk samples remain at 10 Hz. Live simulator validation is pending.

### beta7：固定风箭头、分析器 ILS 与长弹跳

- 游戏内风箭头固定 48 像素长度，箭头头部固定 8 像素；不再随角度、风速或组件大小拉伸。网页箭头固定 32 个绘图单位，时间轴与地图缩放不改变箭头长度。风速继续通过数值和绿／金／红颜色表达。
- 游戏覆盖层移除全部 LOC／GS 点、菱形和 ILS 标签，保留正方形操纵区、风和 YAW。ILS 数据仍用于记录和分析器复盘。
- 分析器操纵仪表固定为 200 像素操作区，LOC 200×28、GS 32×200；无参考、数据过期、在地面或超出有效几何范围时分别显示 INOP，不隐藏、不挤压仪表。有效时恢复四点、中线及偏差菱形。这里依然是 XP 导航资料的 **几何参考**，不是实测机载接收机电波。
- 弹跳监测与完整落地会话绑定，解除首次接地后 6 秒截止和 100 ft 节选结束时的提前停止。仍保留 0.12 秒离地和高度增量／向上速度证据门槛；数据中断／换会话／回放不跨段拼接。低于 30 kt 连续接地两秒结束；触地后复飞需在触地高度以上 300 ft、向上速度超过 3 m/s 持续五秒确认（完整记录另保留 3000 ft 及总时长保护），不再把低空长弹跳直接当作复飞。
- 首次有效二次触地仍使用原 FPM／G 和一次弹跳降级规则。确认后保持本次落地状态至记录结束，避免后续弹跳被重新当作一份新落地。最终 TXT 在导出前刷新早期摘要；即刻弹窗仍表示当时的快照。
- 对已经保存的完整旧记录，分析器会补充弹跳证据提示，保留原 TXT 及历史评分，不把缺失数据补成已确认信号。

Live wind arrows now have fixed length; live ILS indications have been removed. The analyzer keeps fixed LOC/GS instruments visible and displays INOP independently when the geometric reference is unavailable. Bounce monitoring follows the landing session instead of a six-second cutoff, with continuity and go-around guards. The final export refreshes any early no-bounce summary. Older full logs receive a retrospective evidence note while their original rating is retained.

### beta6：正方形操纵区域（历史，游戏内 ILS 已在 beta7 移除）

修正 beta5 的长方形十字操作区：横、纵轴共用同一个长度与输入比例，居中放置在信息栏之间，拖拽缩放后仍保持 1:1。默认 180 像素窗口、无 ILS 时操作区为 122 × 122 像素；比原先 110 × 110 的区域更大。风向／风速、YAW、有效 LOC／GS 和调试来源继续保留，ILS 刻度贴近操作区；边缘缩放、位置拖动和传统尺寸控件保持可用。

The input pad now stays square at every widget size. Both axes use the same scale, with a centred 122 × 122 pad in the default 180-pixel widget without ILS. Wind, YAW, valid LOC/GS and debug readouts remain visible. Edge resizing and existing size controls are retained.

### beta5：紧凑输入布局与边缘缩放（历史，操作区比例已由 beta6 修正）

标准版操纵输入区减少留白，横纵轴分别利用可用空间；风箭头维持真实角度，风向／风速、YAW 和有效 LOC／GS 刻度各自保留区域。默认 180 像素、无 ILS 的十字由 110 × 110 扩为 164 × 122 像素。

标准版摇杆、油门、N1 组件以及落地弹窗支持拖动四边／四角等比例调整大小，无需开启编辑布局。边缘内侧 6 像素为缩放把手，右下角有淡色标记；组件 120–360 像素，落地弹窗字体 10–32 像素并自动排版。缩放固定对侧、受桌面边界限制，松开后保存到原设置文件。现有尺寸滑条、字号按钮和拖动位置功能继续使用。设置／记录窗口继续使用原生窗口边框缩放。兼容版维持原有显示和交互，不提供这次 SDK 440 无边框窗口的连续缩放。

Standard widgets and the touchdown popup can be resized from any edge or corner without enabling layout editing. A small lower-right grip identifies the handles. Opposite edges stay anchored, screen bounds are respected, and preferences are saved on release. Existing size/font controls remain available. Wind arrows retain their true angle on the expanded input pad. Legacy compatibility rendering retains its existing interactions.

### beta4：保留竖向区间细节与鼠标性能

右侧“竖向细节”默认开启，独立放大当前时间区间，补充等比例俯视图。默认显示 LOC 几何偏差；没有已记录的 ILS 参考时显示跑道中线偏差（米），可切换回风向曲线。没有跑道几何时仍保留时间窗口并说明缺失，不伪造中线。风向保持 −90°～+90° 横向偏角，持续顶风不会跳边。

Ctrl + 滚轮或“区间 + / −”改变时间窗；LOC／中线的横向量程按所选区间确定，悬停只定位时间，不改变比例。主图、竖向图、操纵仪表和俯视图共享时间游标。

鼠标事件合并为每个浏览器绘制帧一次，使用最后位置。参数与舵面图不再随鼠标重算曲线／重建图例／清空 Canvas，而由独立游标层更新；主题、指标、时间区间和尺寸改变仍会重绘。航迹前缀缓存及空间索引减少整条航迹遍历。

The vertical detail stays visible by default and magnifies the selected time interval. It shows LOC geometric deviation when available, otherwise runway centerline deviation in metres; wind direction remains selectable. Ctrl + wheel or Interval + / − controls the time window. Lateral scales fit the selected interval and stay fixed while hovering. Pointer events coalesce to one update per browser frame; static charts and legends are reused while cursors and instruments update.

### beta3：ILS 几何参考与同步航迹

从 XP 当前导航资料匹配目标跑道的 LOC／GS，记录台站坐标、真航向、下滑角、高程和来源；无需机模导航接口或调谐操作。俯视图绘制紫色 LOC 参考线，右侧默认展示飞机相对 LOC 的实际横向偏差（左负右正，时间向上）。蓝线不再表示风，风仅以箭头叠在对应时刻的飞机位置上。俯视图悬停同步时间游标；Ctrl + 滚轮及缩放按钮控制倍率，悬停不移动视区。

网页和原生操纵覆盖层下方／右侧显示 LOC／GS 的四点刻度、中线和菱形；菱形表示修正方向。无参考、地面、背向进近或超出几何计算范围时不显示对应指示；只有 LOC 的跑道不显示 GS。风箭头统一调淡：≤10 kt 绿色，>10 至 20 kt 浅金色，>20 kt 红色。

这是 **ILS REF 几何参考**，不是机载接收机信号，也不声称模拟遮挡或电波覆盖。点距采用明确的参考刻度（LOC 1.25°／点、GS 0.35°／点），不代表台站真实标定灵敏度。GS 使用飞机海拔高度与台站高程。未知／不支持的导航覆盖层、资料冲突或跑道匹配不明确时，beta7 起仪表显示 INOP，不猜测下滑角。旧报告没有参考快照时只显示已有路线与风，不能恢复当时的 ILS 信号。兼容 UI 保持既有文字界面，beta7 起图形 ILS 指示仅用于网页分析器。

ILS references are matched against XP navdata and verified against its navigation database, independently of aircraft radio tuning. The plan shows the LOC reference; the synchronized blue trace shows aircraft LOC deviation, with wind arrows at aircraft positions. Four-dot LOC/GS indicators use correction-direction diamonds. From beta7, unavailable facilities show INOP independently; live overlays no longer show ILS. Pale arrows are green at ≤10 kt, gold above 10 through 20 kt, and red above 20 kt.

**ILS REF is geometric analysis, not received radio signals.** Display scales are 1.25°/dot LOC and 0.35°/dot GS reference scales, not measured station sensitivity. Old logs without an ILS snapshot cannot restore it; unsupported or conflicting navdata is left unavailable. Flight validation remains pending.

### beta2：持续顶风的曲线连续性（风曲线已在 beta3 改为 LOC 航迹）

原先完整方向角在 −180°／+180° 附近跳边，导致连续顶风被画成两侧断线。默认风图现使用 −90°～+90° 横向偏角，沿跑道轴为 0°，左吹为负、右吹为正；顶风与顺风由箭头和迎风分量区分。不改变原始风数据，不平滑阵风，真正缺段及静风仍留空。

The default wind plot now uses a −90° to +90° lateral angle, avoiding artificial breaks around the ±180° headwind boundary. Zero means flow along the runway axis; arrows and the headwind component distinguish headwind from tailwind. Raw wind data and real gaps are preserved.

### beta1：游戏内实时风与开发包编号

操纵组件默认叠加浅金色风箭头，箭头表示相对机头的风吹向；顶部“风来自”显示来向与风速。`T` 为真方向，`M` 为磁方向；末尾 `I` 表示已回退到仪表风。读取飞机当前位置的瞬时风，每帧更新，不受录制风间隔影响、不做长时间平滑。接近静风（小于 0.05 kt）隐藏方向箭头，失效时显示 N/A。可在“实时视图”中关闭“实时风向叠加”。兼容界面显示风向／风速文字。

实时层优先读取 `sim/weather/aircraft/wind_now_speed_msc` 与 `wind_now_direction_degt`，配合同帧真航向绘制；失败时使用已有仪表风和磁航向。查找句柄后缓存，开启时每帧额外两次标量读取，关闭时不读取；缺失句柄每秒最多重试一次。箭头仅增加三个四边形，复用顶点缓冲。日志继续使用原有风源和配置的写入间隔，实时显示不会增加写盘次数。

未上传 GitHub 的交付从 **1.1.9-beta1** 开始，依次递增 beta2、beta3；当前编号维护在 `development.json`；正式版使用 `version: 1.1.9` 与 `channel: stable`。清单版本、ZIP／安装目录名、安装后的 `StarLux_LMM_v1.1.9.lua`、报告标题和分析器版本标识一致。构建会检查源码版本，四种 UI／语言包共用同一小版本号。旧的未编号开发产物保留为历史文件，新交付使用 `dist/1.1.9/`；源码编辑入口仍为 `StarLux_LMM_v1.1.9.lua`，构建时按实际版本命名安装文件。

安装器已有 beta 数字排序能力，无需更新安装器程序；1.1.9 正式版排在所有 1.1.9-betaN 之后。此前误用正式编号的本地 1.1.9 开发版首次迁移到 beta1 时可能显示“安装较旧版本”，这是旧编号造成的；选择 beta1 本地包安装即可替换旧主脚本、保留设置和日志。后续 beta2、beta3 按正确顺序比较。

The input widget now shows a live wind-flow arrow and wind-from/speed readout. It prefers instantaneous aircraft weather, independent of recording intervals; T/M denote true/magnetic direction and I marks instrument fallback. Only two additional cached scalar reads per enabled frame and three reused-buffer quads are needed. Unpublished deliveries use 1.1.9-betaN consistently across manifests, archives, installed scripts, report headers and the analyzer badge. The first migration from the old unnumbered 1.1.9 development build may show a downgrade notice because that old name sorts as a final release.

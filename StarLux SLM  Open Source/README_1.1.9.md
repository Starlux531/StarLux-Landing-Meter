# StarLux LMM 1.1.9RC9 · 安装与使用 / Installation

插件 **1.1.9RC9**，安装器 **1.0.4**。RC9 于 2026-10-10 公开稳定发行。累计更新见随包 `RELEASE_NOTES_v1.1.9RC9.md`（若提供）或项目 CHANGELOG。

## 安装

1. 完整解压 CN 或 EN 安装包，保留安装器和相邻的 `version` 文件夹。
2. 运行安装器，选择正确的 X-Plane 目录和 RC9 载荷。Standard 要求 XP 12.4.4+；Compatibility 使用传统界面，游戏内统一英文，报告可选中文或英文。
3. 一般升级选择「保留配置」。需要重置设置时选择「纯净重装」；两者按预览保留飞行记录。核对文件变更后点击绿色「确认安装」。
4. 不要只替换 Lua 主脚本；包括 `core_touchdown.lua`、`core_work.lua` 在内的模块、网页和字体必须完整安装。

安装器会列出相关文件和需要修复的具体原因。飞行记录默认折叠，点击可展开；点击列标题排序。「输出详细」可展示完整操作过程。遇到失败请先导出诊断包，保留 `backup`、`logs` 及安装状态文件，按安装器恢复流程操作。

## 主要使用变化

- 默认「触地后立刻弹出」，观察完成后固定着陆值；即时演算从记录开始显示紧凑状态，触地后展开。二者均不等待 30 kt，后台滑跑记录继续。
- 弹窗内「报告导出中，请勿关闭游戏」在完整报告提交后原位切换为已生成提示。
- 实时 G/FPM 和油门/N1 可独立或组合显示；新配置的独立 FPM 三种来源默认全选，即时演算默认 VVI，已有设置保留。
- 贴边快捷按钮位于通用设置的语言选项后，默认布局可拖动；兼容版可调整按钮大小、透明度和明暗或隐藏，隐藏后通过 Plugins 菜单打开设置。
- 分析器每次打开默认启用 OSM 底图、路径风向和竖向细节，右侧显示风向，地图初始缩放 0.71×；已有安装同步生效，其他偏好保留。支持单独放大及同步回放。地图库内置，底图需联网；不可用时仍可查看原轨迹图。日志不上传。
- 网页并列显示触地瞬时/观测峰值，G 严重度显示双指针区间；沿用原报告评分。拉平曲率提供解释，轨迹震荡高为橙色，正常为绿色。

## English

Plugin **1.1.9RC9**, installer **1.0.4**: public stable release dated October 10, 2026. Extract the complete CN or ASCII-path EN bundle and keep the installer beside `version/`. Select RC9 and the appropriate UI variant. Standard requires XP 12.4.4+; Compatibility uses English in-sim interfaces with separately selectable report language.

Use **Keep settings** for a normal upgrade, inspect the file review and confirm installation. Do not replace only the main Lua file: all modules, fonts and analyzer assets are required. Preserve recovery folders and export installer diagnostics if an operation fails.

Touchdown display opens at contact and holds determined landing values independently of rollout recording. Live calculation starts a compact recording panel earlier. Export status appears inside the landing popup. FPM widgets offer labeled VVI, physical and AGL-derived sources; existing preferences remain intact. The optional OSM map needs internet access, while flight records stay local and the original trace view remains available offline.

Next version: **1.2.0 native XPL rewrite**. No further 1.1.x bug-fix releases are planned. Aircraft-specific behavior and real simulator performance remain subject to flight validation.

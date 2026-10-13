# StarLux LMM 1.1.8beta — X-Plane 12.4.4 字体适配

本版更新接地弹窗、中文设置窗口和统一语言。仍运行于 FlyWithLua，不是完整 XLua 移植，也不是独立 C++ XPL 插件。沿用 1.1.7 的数据采集、着陆分析、发动机适配和机场索引；网页分析器仅增加插件全局语言联动。

## 当前设置与记录 UI 修订（20260912-ui-refresh）

- 恢复两个独立 FlyWithLua 菜单：`StarLux LMM | 设置 / Settings`、`StarLux LMM | 落地记录 / Landing records`。菜单名称固定双语，窗口内容仍跟随唯一的全局语言；另提供 `starlux/lmm/open_records` 快捷命令。
- 原生设置分为通用、位置、配色、字体、工具五页；使用独立功能卡片、标题、青绿色选中态和悬停边框。修复短标签被错误折成两行的问题。
- RGB 与字号采用可见的轨道、白色带纹理拖柄和独立数值；颜色预览块不再接收按钮点击。滑块位置与命中范围一致，滚动条拖动保持抓取位置。
- 记录列表固定保留删除列，窄窗口只换行记录文字；删除操作为红色，并保留原有二次确认。翻页保持同行排列，无可用上一／下一页时显示禁用状态。
- 精简与操作无关的算法解释、字重说明与重复提示；失败信息仍保留，详细字体诊断仅在 Debug 时显示。
- **本次不改接地弹窗、字体资产、记录算法或安装器 EXE。** 更新的是主 Lua 中的设置／记录构建器、菜单及 `LMM_UI_118/dialog.lua`，二者必须一起替换。
- `dist/StarLux_LMM_Installer_UI.zip` 使用原来已验证的安装器 EXE，仅预置新的 `version/1.1.8beta-ui-refresh`；旧发行包保留不覆盖。安装时确认构建标记为 `20260912-ui-refresh`。
- 完成 16 项离线 LuaJIT 回归及 520／860／1200 宽度下的双语布局检查；离线绘图预览不等于真实 X-Plane Vulkan 渲染，仍请实机验收菜单、拖动和滚动。

## 当前语言修订

- 解决旧 beta 将 API 版本值误当 Log.txt 构建号比较的问题。已安装 12.4.4 也会被旧条件拒绝，显示 `Requires X-Plane 12.4.4 / SDK 440` 并进入旧字体回退。现在以 SDK ≥ 440 和完整必需函数探测决定能力，同时记录实际 API 版本值。
- 只有一个“全局语言 / Global language”，统一控制设置、记录管理器、接地弹窗、数据库状态、新生成的 TXT 及插件打开的分析器。内部继续沿用 `document_language` 配置键，避免破坏原设置。
- 设置和记录窗口改用原生 Panel Graphics 中文字库；支持按钮、单选、多选、下拉列表、滑块拖动、滚轮与右侧滚动条。字库文件必须与主脚本一起更新。
- 即使回退，也不再因字号变成英文：兼容中文弹窗采用标准 Unicode 字号，保留用户保存的原生字号。
- 全局语言仍统一控制窗口与输出；菜单现已按上方 UI 修订恢复两个独立的双语入口。
- 从插件打开的阅读器跟随全局语言，不再提供第二个语言开关；单独打开 HTML 时仍可自行选语言。已打开的网页不会实时读取 Lua 设置，改变全局语言后请从插件重新打开报告；历史 TXT 内容不会重写。

## 安装

1. 建议先退出 X-Plane。备份现有 `LMM_Settings.cfg`，将旧 LMM 主脚本移至 FlyWithLua 的 `Scripts (disabled)` 等不自动执行的目录。不要同时启用两个 LMM 版本，也不要仅把旧 `.lua` 改成另一个 `.lua` 文件名留在 Scripts。
2. 将新版 `StarLux_LMM_v1.1.8beta.lua`、整个 `LMM_UI_118` 文件夹及 `LMM_Report_Reader.html` 放入 `Resources/plugins/FlyWithLua/Scripts/`，更新旧 beta 的对应文件。不要只替换 Lua 主文件。
3. 保留已有 `LMM_Settings.cfg` 和 `LMM_Log`。本升级包不包含或覆盖这些用户文件。
4. 启动 X-Plane 12.4.4，从 FlyWithLua 的 `StarLux LMM | 设置 / Settings` 打开设置；原生路径显示五个页签，先执行“预览弹窗 5 秒”。落地记录从另一个独立菜单进入。

安装后目录应为：

```text
FlyWithLua/Scripts/
  StarLux_LMM_v1.1.8beta.lua
  LMM_UI_118/
    native_popup.lua
    dialog.lua
    layout.lua
    fonts/
      LMMUI-Regular.otf
      LMMUI-Medium.otf
      LMMUI-Bold.otf
      OFL.txt
      manifest.json
  LMM_Report_Reader.html       ← 更新为本次语言联动版
  LMM_Settings.cfg            ← 保留原有设置
  LMM_Log/                    ← 保留原有报告与缓存
```

不要将 `LMM_UI_118` 内部的 Lua 文件单独移动到 Scripts 顶层；它们是主脚本加载的模块，不是独立插件。

## 使用与回退

- 新后端提供 10–32 连续字号，原“小／标准／大”迁移为 10／14／18。中文不再因选择小号或大号而强制变成英文。
- 常规／中等／加粗使用独立字重；三种字重采用共同尺寸包络，所以改变粗细不会撑大框或改变换行。
- 边框按实际文字宽高决定，长内容自动换行；九宫格位置和上下左右微调继续有效。新窗口坐标以 X-Plane boxel 为准，因此高 DPI 下微调单位的物理像素距离可能与旧窗口不同。
- 报告生成提示继续在弹窗内闪烁三次，闪烁期间保留位置；中心线字段继续由原算法异步更新。
- 视口过小时临时缩小字号，不修改保存的偏好；连最小显示字号也无法容纳时以省略号结束，查看 TXT 可获得完整内容。
- `Compatibility` 可手动切回旧弹窗绘制；新接口、模块、字体或退出钩子不可用时也会自动回退。兼容中文弹窗只采用标准字号，不改变语言。手动选兼容弹窗不销毁原生设置窗口及字库。
- 设置中会显示原生后端状态或失败原因，FlyWithLua／X-Plane 日志中也有 `[StarLux LMM]` 提示。
- 完整回退：退出模拟器，移出 1.1.8beta 主脚本，重新启用 1.1.7；无需删除日志或机场缓存。可恢复备份设置。未被加载的 `LMM_UI_118` 文件夹可以保留。

## 安装后验收

本版已通过离线测试，尚未完成模拟器内视觉及飞行测试。请先预览后飞行：

1. 中文和英文分别选择 10、14、18、24、32，检查字形完整、行间不重叠、边框无大片多余留白。
2. 相同内容／字号下切换三种粗细，确认框的位置、宽高和换行保持一致。
3. 检查横／竖弹窗、九种位置、四向微调；窗口改变尺寸以及 XP 100%／150%／200% UI 缩放后不超出屏幕。多屏负原点也需验证。
4. 检查四个等级的自定义颜色、黑／白／自动字体色，以及中心线“计算中→结果”。
5. 完成一次着陆：报告生成闪三次，Debug 模式才显示原底部完整路径；回放时不残留原生窗口。
6. 在弹窗显示和隐藏时分别重载 FlyWithLua，再预览；应只显示一个弹窗，无 Lua quarantine、重复窗口或退出崩溃。
7. 若显示异常，先选 Compatibility 并保存日志，不要在运行中删除模块或字体。
8. 中文／英文切换后，检查设置及记录窗口标题、位置名称、颜色／评级标签、文件操作提示；两种语言分别生成报告，核对 `_CN`／`_EN` 及从插件打开的阅读器语言一致。

## 开发说明

### 实现边界

- 原生窗口以 `XPLMCreateWindowEx` 创建，`contentType = xplm_WindowContentTypePanelGraphics (1)`。字体和图形只在此窗口回调内绘制；绝不在原 OpenGL 的 `do_every_draw` 中直接调用 Panel Graphics 绘图。
- 原主脚本只负责提供显示快照、已有位置计算和设置；原始采样、分析与索引不迁移。
- 初始化验证 SDK ≥ 440 和全部符号，不拿 XPLMGetVersions 的 XP 返回值比较构建号。三个字重只加载一次，文字尺寸按状态变化缓存；无需 CEF、联网或运行时下载字体。
- `do_on_exit` 在正常重载／关闭前注销窗口，再释放 FFI 回调和字体。根据 FlyWithLua 官方 `ResetLuaEngine`／`XPluginDisable` 与本机 `FlyWithLua.exit` 的顺序核对。
- 顶层局部声明不增加；新增主脚本函数挂在已有 `log_tools` 上，FFI 与排版代码分模块。
- 接口绑定已针对本机 Windows 64 位和官方头文件验证；Linux／macOS 的库定位分支尚未实机验证。SDK 测试版接口未来若变动，需要重新核对 ABI，不保证所有后续版本。
- 使用全局桌面边界进行定位；非矩形多屏布局的空白区域仍可能影响锚点选择，需要按实际布局验收。

### 官方依据

- [XLua 2.0 API](https://xlua-api.docs.staging.x-plane.com/)
- [SDK 440 API](https://xpsdk-api.docs.staging.x-plane.com/)
- [字体接口](https://xpsdk-api.docs.staging.x-plane.com/docs-xplm/XPLMPanelGraphics/panel_graphics_fonts.html)
- [窗口接口](https://xpsdk-api.docs.staging.x-plane.com/docs-xplm/XPLMDisplay/window_api.html)
- [SDK 440b1 头文件包](https://www.x-plane.com/wp-content/uploads/2026/09/XPSDK440b1.zip)

特别注意：本次下载的 C 头文件使用 `int visible`、`contentType`；staging 网页存在 `bool visible`、`windowContentType` 的展示差异。绑定以 C 头文件为准。64 位结构大小为 112，contentType 偏移为 88。

### 字体与复现

字体来自 [Noto CJK 官方仓库](https://github.com/notofonts/noto-cjk/tree/main/Sans)，遵循 SIL OFL 1.1。衍生子集改名为 LMM UI，保留版权和授权；三个字体共约 1 MB。源文件及成品 SHA-256 见 `fonts/manifest.json`。

字库覆盖当前 Lua 源文件中文字形、ASCII 与必要符号。运行时尝试把 XP 自带完整 CJK Regular 加为后备；子集之外的字符可能采用常规字重。模拟器字体不随包分发。

离线工具使用 Python、fonttools 4.65.0、lupa 2.8 的 LuaJIT 2.1。开发依赖存放 `.tools/python`，不需要随插件安装。运行：

```text
python tools/build_ui_fonts.py
python tests/test_ui_118.py
node tests/test_reader_language.cjs
```

构建字体前，将 Noto CJK SC 的 Regular／Medium／Bold OTF 和 Sans/LICENSE 保存到 `.tools/font-sources/`，许可证文件命名 `OFL.txt`。字体变更后必须更新覆盖测试和 manifest。

测试使用隔离的 SDK 替身，不加载真实 XPLM DLL；可验证 ABI 声明、生命周期、布局、回退和主脚本集成，但不能替代模拟器中的渲染与飞行验收。

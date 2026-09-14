# StarLux LMM 1.1.8 正式版 / Stable release

[技术手册 1.0：中英文 PDF 与 Markdown / Technical Manual 1.0](docs/technical-manual/README.md)

适用于 Windows 64 位 X-Plane 12，依赖 FlyWithLua NG+。本版仍为 Lua 插件，不是独立的 C++ XPL 插件。1.1.8 沿用 1.1.7 的落地采集、评分与机场索引算法。

For Windows x64 and X-Plane 12 with FlyWithLua NG+. This is a Lua plugin, not a standalone C++ XPL plugin. Version 1.1.8 retains the landing capture, scoring and airport-index algorithms from 1.1.7.

## 下载选择 / Choose a download

<p align="center"><a href="docs/images/QQ20260914-105006.png"><img src="docs/images/QQ20260914-105006.png" alt="Author-provided StarLux installer and updater interface" width="900"></a></p>

作者提供的最新安装/更新界面。安装器与插件版本号独立；功能以实际下载版本为准。 / Latest author-provided install/update UI. Installer and plugin versions are independent; features depend on the downloaded build.

| 文件 / File | 用途 / Purpose |
| --- | --- |
| `StarLux_LMM_Installer_1.1.8.zip` | 完整离线安装包：安装器和 version 文件夹 / Complete offline installer bundle |
| `StarLux_LMM_installer_安装器.exe` | 仅安装器；联网选择版本 / Installer only; select an online release |
| `StarLux_LMM_v1.1.8-Standard-CN.zip` | XP 12.4.4+ 标准 UI，默认中文 / Standard UI, Chinese default |
| `StarLux_LMM_v1.1.8-Standard-International.zip` | XP 12.4.4+ 标准 UI，默认英文 / Standard UI, English default |
| `StarLux_LMM_v1.1.8-Compatibility-CN.zip` | XP 12、12.4.4 之前，旧 UI 兼容，默认中文输出 / Pre-12.4.4 legacy UI, Chinese output default |
| `StarLux_LMM_v1.1.8-Compatibility-International.zip` | 同上，默认英文 / Same legacy edition, English default |
| `Starlux_Analyzer_落地分析器.html` | 双击独立运行，不需要模拟器或安装器 / Standalone analyzer; no simulator or installer required |
| `analyzer-presets.json` | 随包预设的可读备份 / Readable copy of bundled presets |

CN 与 International 只改变首次安装时的默认语言；已有 `LMM_Settings.cfg` 优先，升级不会覆盖用户的语言、设置、日志或机场缓存。两个 UI 版本主脚本文件名相同，切换时替换，不可同时启用。

CN and International differ only in the default language when no settings file exists. Existing settings, language, logs and airport cache are preserved. Both UI editions use the same main-script filename: replace the edition, never run two copies.

标准版依赖 SDK 440 和完整字库能力，缺少能力时自动回退。兼容版明确禁用新的 SDK 440 字体接口，即使在新 XP 上运行也使用传统 UI。旧 FlyWithLua ImGui 字库不能保证中文，因此兼容版设置和记录窗口使用英文控件；中文报告保留，中文落地弹窗使用标准字号。兼容版不承诺新原生 UI 的连续中文字号和真实字重能力。

Standard requires SDK 440 and the font API; unavailable capabilities trigger fallback. Compatibility explicitly skips SDK 440 font calls, including on newer XP. Legacy FlyWithLua's ImGui atlas cannot guarantee CJK glyphs, so compatibility settings/records use English controls. Chinese reports remain supported and the Chinese popup uses the normal font size. Native continuous Chinese font sizing and true font weights are not available in legacy UI.

## 安装 / Install

1. 退出 X-Plane，解压完整安装包。顶层只有安装器 EXE 和 `version`。把文件夹放在有写入权限的位置即可，不必放在模拟器目录。
2. 运行安装器，核对自动找到的 XP 根目录，也可手动选择包含 `X-Plane.exe` 与 `Resources/plugins` 的目录。
3. 从版本列表选择标准版或兼容版。`【最新 / Latest】` 表示当前成功读取到的本地／在线目录中的最高版本，不代表兼容你选择的 XP；请核对兼容范围。首次打开默认选择最高版本的标准中文版，已有选择在刷新时保留。
4. 缺少 FlyWithLua 时由用户决定自动下载、选择本地官方 NG+ ZIP 或取消。离线 LMM 包不含 FlyWithLua；下载依赖仍需要联网。
5. 确认后安装；旧主脚本及被替换文件备份到安装器旁的 `backup`。保留此目录，以便安装器的“恢复备份”恢复。

Exit X-Plane, extract the bundle into a writable folder, run the installer and verify the detected simulator root. Select the edition matching your XP version. The bilingual Latest badge means the highest version in the successfully loaded catalog, not automatic simulator compatibility. A missing FlyWithLua dependency requires your consent to download or import. Modified files are backed up beside the installer; keep the backup folder for restoration. Existing user settings and landing reports are not overwritten.

手动安装单个插件 ZIP：只把 `payload` 内的文件复制到 `Resources/plugins/FlyWithLua/Scripts/`。先移出旧版 LMM 主脚本，保留用户配置与日志。`LMM_UI_118` 必须保持完整，不可把模块单独放到 Scripts 顶层。

Manual installation: copy the contents of `payload` into `Resources/plugins/FlyWithLua/Scripts/`, remove the older active LMM main script first, and retain your settings/logs. Keep the complete `LMM_UI_118` folder; do not place its modules at Scripts level.

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

代码 MIT；随包 LMM UI 字体遵循 SIL OFL 1.1，许可位于 `LMM_UI_118/fonts/OFL.txt`。

Code: MIT. Bundled LMM UI fonts: SIL OFL 1.1; see `LMM_UI_118/fonts/OFL.txt`.

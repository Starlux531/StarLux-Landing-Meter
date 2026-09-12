# StarLux LMM 1.1.8

## 中文

**文件名提示：**GitHub 会去掉直接上传的 HTML／EXE 文件名中的中文。下载 `Starlux_Analyzer_1.1.8.zip` 可得到完整名称的 `Starlux_Analyzer_落地分析器.html`；下载 `StarLux_LMM_Installer_Only_1.1.8.zip` 可得到 `StarLux_LMM_installer_安装器.exe`。完整安装包内的名称也保留。直接下载入口显示双语标签，内容一致；校验清单中的中文名称对应解压后／原始名称。

1.1.8 正式发布：标准版适配 X-Plane 12.4.4+ 的原生中文字库与 UI；新增面向 12.4.4 之前 XP 12 的旧 UI 兼容包。保留现有落地算法，不改变已有飞行日志。

- 恢复独立的设置、落地记录菜单；设置功能分区、滑块辨识度、记录列表与删除确认同步优化。
- 标准版全局语言统一界面、落地弹窗、TXT 和插件打开的分析器；中文字号、字重不再引起语言跳变。
- 安装器支持本地／GitHub／Gitee 版本选择，最高版本的所有发行变体标注 `【最新 / Latest】`，显示 UI 兼容范围和默认语言。旧文件备份，设置、日志、机场缓存保留。
- 独立 `Starlux_Analyzer_落地分析器.html` 可直接运行；插件内 `LMM_Report_Reader.html` 不变更名称。两者设置空间隔离。
- 内置作者授权的 5 个真实预设：默认、黑暗玫瑰、巨峰葡萄、未来展厅、水晶紫罗兰。不覆盖已有预设列表，不含个人浏览器数据或飞行日志。
- GitHub 首页更新 6 张作者截图和 1 张原始 GIF，分区排版，完整长图可展开查看。

**下载建议：**优先选择 `StarLux_LMM_Installer_1.1.8.zip`；解压后顶层只有安装器和 version 文件夹。仅下载 EXE 时需要联网下载插件；完整包不包含 FlyWithLua，缺失时需用户同意下载或导入。

**兼容注意：**Standard 面向 XP 12.4.4+。Compatibility 面向旧 XP 12，跳过 SDK 440 字体接口，设置与记录使用传统英文控件，中文报告及标准字号中文弹窗保留。CN／International 只影响无配置时的默认语言；已有配置始终优先。兼容版不能提供新的连续中文字号能力。

## English

**Filename note:** GitHub strips Chinese characters from direct HTML/EXE asset names. `Starlux_Analyzer_1.1.8.zip` preserves `Starlux_Analyzer_落地分析器.html`; `StarLux_LMM_Installer_Only_1.1.8.zip` preserves `StarLux_LMM_installer_安装器.exe`. The complete bundle also preserves these names. Direct downloads carry bilingual labels and identical bytes. Chinese names in the checksum list refer to the extracted/original filenames.

Version 1.1.8 is the stable release of the tested native UI for X-Plane 12.4.4+, with an explicit legacy UI edition for older X-Plane 12 installations. Landing algorithms and existing reports are preserved.

- Separate Settings and Landing records menus, grouped controls, clear sliders and confirmed deletion.
- One global language in Standard: plugin UI, popup, TXT and plugin-launched analyzer. Chinese font size and weight no longer force English fallback.
- Portable installer with local/GitHub/Gitee release selection, bilingual Latest labels, explicit UI compatibility/default language, verified files, backups and rollback.
- A standalone `Starlux_Analyzer_落地分析器.html`, with preferences isolated from the plugin's `LMM_Report_Reader.html`.
- Five sanitized, author-approved presets; existing preset lists are never overwritten. No flight logs or unrelated browser data are included.
- Refreshed GitHub gallery with six screenshots and the original animated GIF.

**Recommended download:** `StarLux_LMM_Installer_1.1.8.zip`. Its root contains only the EXE and version folder. The EXE-only download requires internet to fetch LMM. FlyWithLua is not bundled; a missing dependency requires consent to download or import.

**Compatibility:** Standard targets XP 12.4.4+. Compatibility skips SDK 440 font calls and uses English legacy settings/records controls; Chinese reports and normal-size Chinese popups remain supported. CN/International set the initial language only; existing settings take precedence. Legacy UI does not offer native continuous Chinese font sizing.

## Verification / 验证

- 17 offline LuaJIT/SDK-double regression tests, including four edition/language combinations, existing-settings precedence and unchanged landing functions.
- 26 installer tests per package; final EXE also passed 27 tests with the official FlyWithLua dependency archive in isolated simulated installations.
- Four package ZIPs: 12 file hashes each, single main script, Lua compilation, variant-only source differences and no user configs/logs.
- Standalone/embedded analyzer syntax, four language-switch cases, five presets, saved-list preservation, independent storage and seven gallery asset links checked.
- Real browser check: all five presets visible; applying 巨峰葡萄 restores 75% zoom and vertical layout.

The preceding standard beta was confirmed working by the author. These release checks do not replace in-simulator testing on every old XP build, aircraft or GPU. No real X-Plane installation was modified during packaging. The Windows EXE is unsigned; do not disable security software. SHA-256 checksums are provided. Gitee fallback works only for matching assets actually published there.

上一标准 beta 已由作者实机确认正常；离线检查不等于覆盖所有旧 XP、机模与显卡。此次打包未修改真实模拟器。EXE 尚未签名，请勿关闭安全软件；随包提供 SHA-256。Gitee 只有实际发布同名同版本资产后才可作为该版本备用源。

See [README_1.1.8.md](https://github.com/Starlux531/StarLux-Landing-Meter/blob/v1.1.8/README_1.1.8.md) for installation, privacy and rollback details.

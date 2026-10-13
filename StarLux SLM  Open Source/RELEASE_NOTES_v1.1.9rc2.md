# StarLux LMM 1.1.9rc2 · 正式公开发行 / Public release

发布日期：2026-09-25。项目沿用指定编号 **1.1.9rc2**，本次为正式公开发行，并设为 Latest，不勾选 GitHub Pre-release。

## 更新内容

- 修复旧版 FlyWithLua 设置界面 SliderInt 缺少格式参数造成的 Lua stopped；保留模块缺失/损坏时的启动保护。
- 兼容界面的中文语言选项显示为 **Chinese**，避免旧字体显示问号。
- HTML 分析器在操纵输入旁新增实际 Pitch/Roll 姿态仪，随播放、拖动和悬停时间轴同步；缺少数据时显示不可用。
- Windows 插件后台检查 GitHub 更新，按 UI 版本筛选有效附件。发现更新时在游戏中提示 30 秒，并在设置中持续提示。成功后 6 小时检查一次，失败后 15 分钟重试，不上传飞行记录。
- 内置安装器 **1.0.2**，支持本项目 1.1.9rc2 高于 1.1.9 的维护编号规则。安装器自更新通过独立标签 **installer-v1.0.2** 发布。

## 下载与安装

- 国内包：`StarLux_LMM_Installer_1.1.9rc2_CN.zip`。
- 海外包：`StarLux_LMM_Installer_1.1.9rc2_EN.zip`，压缩包内全部使用英文/ASCII 路径。
- 完整包均含安装器 1.0.2，以及 Standard/Compatibility × CN/International 四种插件载荷。CN/EN 决定默认语言，已有配置优先。
- Standard：Windows x64、XP 12.4.4+、FlyWithLua NG+。Compatibility：旧 XP 12 的传统 UI/数字覆盖层；本次恢复提供修复后的 RC2 包。**XP 12.4.3 的原始错误已离线复现并修复，但该用户的实机复测反馈尚待确认。**旧 `v1.1.9` 兼容附件保持撤回，不修改旧发行。
- 退出 X-Plane 后完整解压，运行内置安装器并保留配置安装。现有旧安装器请先完成安装器自身更新，再检查插件更新；若使用过 1.1.10-beta2 测试包，需要手动选择 1.1.9rc2。
- 不要只复制主 Lua 文件。不要混用不同版本的主脚本与 UI 模块。设置与飞行记录会保留。

## English

**1.1.9rc2** is the project's public maintenance release, marked Latest (not a GitHub prerelease). Fixes the missing SliderInt format argument in legacy settings, adds the ASCII **Chinese** label, timeline-synchronized recorded attitude replay, and background Windows update notices. Installer **1.0.2** understands this project's maintenance version ordering and is also available through `installer-v1.0.2` self-update.

Choose the **EN** offline bundle for ASCII filenames or **CN** for the original filenames. Both include all four UI/language variants. Standard requires Windows x64, XP 12.4.4+ and FlyWithLua NG+. RC2 Compatibility repairs are available again; the reported XP 12.4.3 failure has been reproduced and fixed offline, while affected-user flight validation remains pending. The withdrawn original v1.1.9 Compatibility assets stay withdrawn.

Close X-Plane, extract the complete bundle, run its installer and retain settings. Update older installers first. Users of 1.1.10-beta2 must select RC2 manually. Windows update checks do not upload flight data or install files automatically.

Validation: 111 Lua/UI/update checks, 8 rollout regressions, 41 installer self-tests, browser attitude/wind/ILS checks, package hashes and installation/repair verification passed. Offline validation is not a claim that every aircraft/simulator combination has been flight-tested.

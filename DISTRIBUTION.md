# StarLux SLM Open Source 与 Flare 发行说明

本仓库保留现有地址，承载 StarLux SLM Open Source 与 1.2.0 起的软件发行。

## StarLux SLM Open Source

`StarLux SLM  Open Source/` 收录 1.1.9 及更早版本的公开源码、配套工具、文档和素材。开发者可以依据各文件随附的许可证进行拓展、修改或接入其他项目。项目源码的 MIT 许可证和第三方组件声明保留在目录内；原有版本标签和发行附件保持可用。

该目录的对外名称为 **StarLux SLM Open Source**。后续完整产品 README 由项目维护者单独更新。

## StarLux Flight Landing Analysis & Replay Engine（Flare）

从 1.2.0 起，软件作为 **StarLux Flight Landing Analysis & Replay Engine（Flare）** 模块进行概念归纳，以 **Black Box** 形式提供。公开仓库提供可使用的软件发行文件和必要说明，不上传 1.2.0 及之后版本的核心源码、构建工程或内部开发资料。

Flare 是概念与说明层面的命名。本次整理不修改插件标识、安装目录、运行逻辑、包名或现有接口，也不表示已提供新的集成 API。开源目录的许可与 Flare 发行文件分别管理；发行文件以随包提供的适用许可和第三方声明为准。

## 发行与更新入口

- 插件和安装器继续使用本仓库的 [Releases](https://github.com/Starlux531/StarLux-Landing-Meter/releases)。
- 本次仅整理目录和说明，现有发布标签、附件名称、下载地址及安装器自更新清单保持不变。
- 源码目录移动不改变基于 Releases 的版本查询与下载。
- 1.2.0 插件包沿用 `StarLux_LMM_v1.2.0-Unified-Windows.zip` 形式；Beta 包在版本号中使用对应的 `betaN`。
- 已核对的外部安装器 1.0.4 能从发布目录识别上述包名及 1.2.0/Beta 版本；完整迁移请使用支持原生迁移的新安装器。
- 1.1.9 插件自身的游戏内更新提示按 Standard / Compatibility 附件筛选，不会提示 Unified 包。外部安装器更新与游戏内提示是不同链路。
- 旧安装器自更新要求 `installer-v版本` 标签及 `StarLux_LMM_Installer_Update_v版本.zip` 附件；已核对的 1.0.4 规则不识别 Beta 安装器标签。正式迁移发行时应提供旧规则可识别的安装器更新。

## English

This repository remains the public home for **StarLux SLM Open Source** and software releases from 1.2.0 onward. The `StarLux SLM  Open Source/` directory contains the published source, tools and documentation for 1.1.9 and earlier. Developers may extend or integrate these materials under their accompanying licenses.

From 1.2.0, **StarLux Flight Landing Analysis & Replay Engine (Flare)** describes the software as a **Black Box** module. Its implementation and build project remain private; public distribution contains software packages and supporting documentation. This conceptual name does not change executable identifiers, installation paths, package names, behavior or interfaces.

Release tags and existing assets remain unchanged. The verified external installer 1.0.4 recognizes correctly named Unified 1.2.0/Beta packages, while the older in-game Standard/Compatibility notifier does not. Use a migration-capable installer for the complete transition.

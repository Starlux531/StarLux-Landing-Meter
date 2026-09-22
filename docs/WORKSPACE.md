# 1.1.9 工作区

当前版本为 **1.1.9 正式版（2026-09-23）**，以 beta10 为基线。`development.json` 记录 `version: 1.1.9`、`channel: stable`，发行目录为 `dist/1.1.9/`。后续未发布功能恢复使用明确的开发小版本号。下文日期段保留历史整理 / 验证记录。

后续进展：优先开发的安装器已独立编号为 v1.0，本地构建及验证见 [安装器说明](../installer/README.md)。`dist/installer/1.0.0/` 保存安装器发行产物；下文“本次验证结果”记录的是先前工作区整理时的检查，不代表安装器的新测试结果。

## 目录分类

| 位置 | 内容 |
| --- | --- |
| 根目录 | 1.1.9 主脚本、配套 UI、两个网页分析器、当前说明与项目公共文件 |
| `LMM_UI_119/core_*.lua` | 当前数据逻辑模块，与 UI 模块共同入包以兼容已发布安装器 |
| `.tools/dev-119/` | 当前离线预览、性能测量和测试结果 |
| `tools/` | 当前版本的打包、字体构建与离线预览工具 |
| `tests/` | 当前回归检查；`fixtures/v1.1.8/` 是算法比较用样本，不是启用的插件 |
| `installer/` | 安装器源码与构建入口 |
| `docs/reference/` | MSFS 移植资料与 N1 数据适配参考，文件中的旧版本号保留其历史含义 |
| `docs/images/` | 当前 README 使用的图集及相关素材 |
| `发行预设/` | 发行语言配置与网页配色预设 |
| `LMM_Settings.cfg`、`LMM_Log/` | 本地设置、运行记录及目录说明 |
| `.tools/python/`、`.tools/font-sources/` | 可复用的本地 Python 包与字体源文件 |
| `.pnpm-store/` | 含目录联接的现有依赖缓存，保留原位 |
| `旧版备份/` | 既有历史备份及本次分类归档 |

本次归档见 [归档说明](../旧版备份/2026-09-13_1.1.9开发前整理/README.md) 和 [SHA256 清单](../旧版备份/2026-09-13_1.1.9开发前整理/归档清单.json)。清单覆盖 902 个保存文件条目（包含源码快照与分类副本），不是 902 个不同文件。

旧版 `dist/`、安装器 `bin/obj`、beta 打包脚本、临时预览、检查结果和视频素材已归档。`dist/` 将在后续打包时重新生成。归档及生成物保持本地，不作为当前发行内容。Git 历史和原有未提交内容已保留，未执行提交或发布。

## 现有检查

Lua 回归依赖 Python 3.12 和 `.tools/python/` 内的 LuaJIT/fonttools 包；系统默认的 Python 3.13 无法加载这些 cp312 模块。本机可运行：

```powershell
$lmmPython = 'C:/Users/lan777/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/python.exe'
& $lmmPython tests/test_ui_119.py
node tests/test_reader_language.cjs
node tests/test_release_119.cjs
```

后续准备发行时，使用 `installer/build.ps1` 或 `tools/prepare_release_119.ps1` 构建，再用同一个 Python 3.12 运行 `tests/verify_release_packages.py` 验证包。包验证依赖已生成的 `dist/1.1.9-dev/`；本轮只构建本地开发包，不安装到真实模拟器或发布。

## 历史基线检查 · 2026-09-13

- 17 项 LuaJIT/UI 回归通过，包含语法、ABI、字体、双语、配置继承、兼容回退与算法比较。
- 网页脚本语法、4 种语言切换场景、5 个预设、用户数据保留、独立存储与 7 张首页素材检查通过。
- PowerShell 构建脚本语法检查通过。
- 1.1.9 主脚本相对 1.1.8 仅修改版本文本与 UI 目录引用；网页、字体、发行预设和本地配置保持原文件内容。

以上是离线检查，不是实际 X-Plane 渲染或飞行验证。安装器仅同步版本和构建引用，本次未重新编译。

## 2026-09-21 交互修订备份

`旧版备份/2026-09-21_1.1.9交互修订前/` 保存修改前 61 文件快照和 SHA256 清单、修改前完整开发包 `previous-dev-bundle.zip`，以及原开发安装目录的用户回滚备份 `installer-user-backup/20260921-131314-e3309cdc/`。回滚备份已移出发行目录并完整保留，可在安装器恢复功能中选择其实际目录。

当前开发包在 `dist/1.1.9-dev/`，内置本地安装器 1.0.1。1.1.8 及已发布安装器 1.0.0 保持原样；仅构建本地开发包，没有安装到模拟器或发布 GitHub。

## 2026-09-21 风场与全程通道修订

修改前源码、两种分析器和已有相关回归保存在 `旧版备份/2026-09-21_风场与完整通道增强前_151652/source.zip`，附 SHA256 清单。运行 `python -m unittest discover -s tests -p 'test_*119.py'` 检查 45 项 LuaJIT 回归；`node tests/test_wind_view_browser.cjs [旧日志绝对路径]` 检查新通道、风图、悬停稳定和显式缩放（需 Playwright／Edge）。真实飞行文件只读，安装目录未修改。

## 历史交付：1.1.9-beta7

开发小版本统一维护在根目录 `development.json`。每次新的未发布交付递增 betaN，同时更新主脚本版本文字与 README；构建脚本拒绝没有编号或源码不匹配的开发版本。当前包位于 `dist/1.1.9-beta7/`，旧 `dist/1.1.9-dev/` 、`dist/1.1.9-beta1/` 、`dist/1.1.9-beta2/` 、`dist/1.1.9-beta3/` 、`dist/1.1.9-beta4/` 、`dist/1.1.9-beta5/` 和 `dist/1.1.9-beta6/` 只作历史留存。源码入口 `StarLux_LMM_v1.1.9.lua` 不随迭代改名，安装包主脚本按实际小版本命名。

实时风与编号修改前备份：`旧版备份/2026-09-21_实时风与开发版本编号前_165432/`。安装器回归命令：`dotnet run --project tests/installer_development/InstallerDevelopment.csproj -- D:/Starlux_LMM`，使用临时模拟 XP 目录验证小版本排序、四种包发现、替换、诊断和保留设置修复。不会安装到真实模拟器。

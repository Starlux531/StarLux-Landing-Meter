# StarLux Landing Meter

[![Version](https://img.shields.io/badge/version-0.7.0-blue.svg)](https://github.com/Starlux531/StarLux-Landing-Meter/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![X-Plane](https://img.shields.io/badge/X--Plane-12-orange.svg)](https://www.x-plane.com/)

一款适用于 X-Plane 12 与 FlyWithLua 的轻量落地数据记录插件。它会捕获触地阶段的关键数据、显示落地结果，并为每次有效落地生成独立的中文 TXT 记录。

## 功能

- 捕获触地垂直速度（FPM）和经过稳健处理的过载（G）
- 记录 IAS、TAS、GS、迎角、横滚角、磁航向与风况
- 根据 FPM 与 G 值给出 `STABLE`、`ATTENTION` 或 `UNSTABLE` 评价
- 独立设置窗口，设置会自动保存
- 支持触地时显示或地速低于 30 kt 后显示
- 支持 30、60、120 秒三档显示时长
- 支持九宫格屏幕位置选择和 5 秒位置预览
- 支持横向与竖向两种数据窗口布局
- 支持 25%、50%、100% 三档背景透明度
- 每次落地自动在 `LMM_Log` 中生成 UTF-8 中文 TXT
- 使用短窗口稳健 G 采样与 FPM/G 一致性保护，降低起落架压缩和滚行振动造成的异常峰值
- 将日志写入移出触地关键帧，降低落地瞬间卡顿和画面拖影

## 运行要求

- X-Plane 12
- 支持浮动窗口与 ImGui 的 FlyWithLua NG+

## 安装

1. 从 [Releases](https://github.com/Starlux531/StarLux-Landing-Meter/releases) 下载最新压缩包。
2. 解压后，将以下内容放入 FlyWithLua 的 `Scripts` 文件夹：

   - `StarLux_LMM_v0.7.lua`
   - `LMM_Settings.cfg`
   - `LMM_Log` 文件夹（包含实飞测试样本，可按需保留或删除）

   目标位置：

   ```text
   X-Plane 12/Resources/plugins/FlyWithLua/Scripts/
   ```

3. 如果安装过旧版本，请移走旧版 Lua 文件，避免多个版本同时运行。
4. 启动 X-Plane，或通过 FlyWithLua 重新加载所有 Lua 脚本。

## 打开设置窗口

在 X-Plane 菜单中依次打开：

```text
Plugins > FlyWithLua > FlyWithLua Macros > StarLux Landing Meter | Open Settings
```

也可以在 X-Plane 的键盘或摇杆设置中绑定：

```text
starlux/lmm/open_settings
```

所有修改会立即保存到脚本目录下的 `LMM_Settings.cfg`，重新启动后仍然有效。

## 落地记录

插件加载时会在脚本目录创建 `LMM_Log`。每次有效落地完成约 0.22 秒的 G 值采样和最终评级后显示结果，并在约 1.5 秒后生成一份独立记录，例如：

```text
LMM_Log/LMM_2026-07-20_21-30-45.txt
```

记录内容包括：

- 落地时间与总体评价
- 触地垂直速度和最终过载
- IAS、TAS、GS
- 迎角、横滚角、磁航向
- 风向、风速和相对风
- 原始 G 值、稳健采样值与一致性上限
- 评分阈值及本次使用的显示设置
- 本次使用的横向/竖向布局与透明度档位

插件不会联网，也不会主动上传任何飞行数据。仓库内的 `LMM_Log` 仅为作者明确打包的实飞测试样本。

## 默认评分阈值

| 评价 | 下降率 | 过载 |
|---|---:|---:|
| STABLE | ≤ 220 fpm | ≤ 1.30 G |
| ATTENTION | ≤ 350 fpm | ≤ 1.45 G |
| UNSTABLE | 超过上述注意上限之一 | 超过上述注意上限之一 |

最终评价取 FPM 与 G 两项中较严重的等级。这些阈值目前在脚本内定义，并非航空公司运行标准。

## 故障排查

如果设置或日志无法保存，请检查 X-Plane 目录的写入权限，并查看 `X-Plane 12/Log.txt` 中以 `[StarLux LMM]` 开头的信息。

## 参与贡献

欢迎提交 Issue 和 Pull Request。开始修改前请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

本项目采用 [MIT License](LICENSE) 开源。

X-Plane、FlyWithLua 及相关名称归各自权利人所有。本项目与其官方开发者无隶属关系。

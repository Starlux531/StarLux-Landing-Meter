# StarLux Landing Meter

[![Version](https://img.shields.io/badge/version-1.0-blue.svg)](https://github.com/Starlux531/StarLux-Landing-Meter/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![X-Plane](https://img.shields.io/badge/X--Plane-12-orange.svg)](https://www.x-plane.com/)

StarLux Landing Meter 是一款适用于 X-Plane 12 与 FlyWithLua NG+ 的落地分析插件。它会采集触地阶段的垂直速度、载荷、姿态、速度、风况和拉平轨迹，在游戏内给出结果，并生成可复盘、可对比的本地中文报告。

## 1.0 正式版功能

- 结合物理垂直速度、仪表 VVI、垂直投影 G、G 冲量和速度变化分析第一次起落架压缩
- 使用固定环形缓冲区和分阶段计算，避免把机场查询、日志写入和复杂分析集中在触地关键帧
- 记录机型、落地机场、推算跑道号、IAS、TAS、GS、迎角、横滚、磁航向和风况
- 从 100 ft 开始采集并聚合拉平轨迹，计算拉平曲率和轨迹震荡结论
- 检测 Bounce Landing，并按既定规则降级非红色评价
- 低高度阶段监测降水与 X-Plane 跑道摩擦状态，保留明确的提示来源
- 提供 Nice、Stable、Attention、UNSTABLE 四级评价；UNSTABLE 对外表述为“不良落地”
- 独立设置窗口：弹窗时机、30/60/120 秒时长、九宫格位置、横/竖布局、三档透明度和详细数学日志
- 自动生成 UTF-8 中文 TXT，文件名包含机场、机型与跑道
- 游戏内记录管理窗口可浏览、打开或删除最近日志
- 统一的本地网页阅读器：插件内打开和独立打开使用同一套界面
- 支持选择第二份日志进行对比，显示关键差值并叠加 100 ft 拉平轨迹
- 全程本地运行，不联网、不上传飞行数据

## 运行要求

- X-Plane 12
- 支持浮动窗口与 ImGui 的 FlyWithLua NG+
- 用于打开报告的现代浏览器

## 安装

从 [GitHub Releases](https://github.com/Starlux531/StarLux-Landing-Meter/releases) 下载 1.0 正式版压缩包，解压后将以下内容放入：

```text
X-Plane 12/Resources/plugins/FlyWithLua/Scripts/
```

必需文件：

```text
StarLux_LMM_v1.0.lua
LMM_Report_Reader.html
LMM_Settings.cfg
LMM_Log/
```

如果安装过旧版本，请把旧版 `StarLux_LMM_*.lua` 移出 `Scripts`，避免多个版本同时运行。随后启动 X-Plane，或通过 FlyWithLua 重新加载所有 Lua 脚本。

## 游戏内入口

设置窗口：

```text
Plugins > FlyWithLua > FlyWithLua Macros > StarLux Landing Meter | Open Settings
```

落地记录：

```text
Plugins > FlyWithLua > FlyWithLua Macros > StarLux Landing Meter | Landing Records
```

也可以绑定设置命令：

```text
starlux/lmm/open_settings
```

## 评分标准

| 评价 | 颜色 | 下降率 | 过载 |
|---|---|---:|---:|
| Nice 轻柔接地 | 深蓝色 | ≤ 100 fpm | ≤ 1.20 G |
| Stable 稳定扎实落地 | 深绿色 | ≤ 250 fpm | ≤ 1.50 G |
| Attention 需注意 | 深橙色 | ≤ 300 fpm | ≤ 1.80 G |
| UNSTABLE 不良落地 | 深红色 | > 300 fpm，或过载超限 | > 1.80 G，或下降率超限 |

FPM 与 G 分别分档，最终评价取两项中较严重的等级，不做平均或抵消。UNSTABLE 表示数据超出当前插件 Attention 上限，并不等同于航司维修检查或适航结论。

## 报告与数据对比

每次有效落地会在 `LMM_Log` 中生成一份 TXT。游戏内记录窗口点击某条记录时，Lua 会调用同目录下的 `LMM_Report_Reader.html`，自动载入所选日志。

也可以不启动 X-Plane，直接双击 `LMM_Report_Reader.html`：

1. 点击“选择落地日志”，或拖入一份/多份 `LMM_*.txt`。
2. 点击左侧记录主体切换主要数据。
3. 点击记录右侧“对比”，或使用“选择对比日志”载入第二份数据。
4. 主轨迹使用评价色实线；对比轨迹使用低透明度灰色虚线。
5. “交换主／对比”可改变两份数据的角色；“取消对比”不会删除日志。

对比只用于复盘，不会改变日志原有评分。只有包含 `0.5秒聚合轨迹表` 的详细日志才能绘制 100 ft 轨迹。

## 文件与隐私

- TXT 报告、网页桥接数据和设置文件均只写入本机。
- `LMM_Viewer.html` 与 `LMM_Viewer_Data.js` 是插件打开报告时在 `LMM_Log` 中生成的本地临时阅读文件。
- 正式发布包不包含作者或测试人员的个人飞行日志。
- 刷新或关闭独立阅读器后，浏览器内已载入的数据会自动清空。

## 文档

- [中文使用说明](README_使用说明.txt)
- [更新记录](CHANGELOG.md)
- [1.0 正式版说明](RELEASE_NOTES_v1.0.md)
- [核心算法技术说明手册](docs/StarLux_LMM_v0.8.2_核心算法技术说明手册.pdf)（技术文档暂未随 1.0 更新）

## 故障排查

如果脚本被 FlyWithLua 隔离，或设置、日志、阅读器无法生成，请检查：

- `StarLux_LMM_v1.0.lua` 与 `LMM_Report_Reader.html` 是否位于同一个 `Scripts` 目录
- X-Plane 安装目录是否具有写入权限
- `X-Plane 12/Log.txt` 中以 `[StarLux LMM]` 开头的信息

## 许可证

本项目采用 [MIT License](LICENSE) 开源。

X-Plane、FlyWithLua 及相关名称归各自权利人所有。本项目与其官方开发者无隶属关系。

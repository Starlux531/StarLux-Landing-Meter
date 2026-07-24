# StarLux Landing Meter

[![Version](https://img.shields.io/badge/version-0.7.2-blue.svg)](https://github.com/Starlux531/StarLux-Landing-Meter/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![X-Plane](https://img.shields.io/badge/X--Plane-12-orange.svg)](https://www.x-plane.com/)

一款适用于 X-Plane 12 与 FlyWithLua 的轻量落地数据记录插件。它会捕获触地阶段的关键数据、显示落地结果，并为每次有效落地生成独立的中文 TXT 记录。

## 功能

- 同时采集物理垂直速度与仪表 VVI；使用触地前 250 毫秒物理速度第 25 百分位计算触地下降率
- 记录 IAS、TAS、GS、迎角、横滚角、磁航向与风况
- 在游戏内窗口和 TXT 报告中显示机型、落地机场及推算跑道号
- 根据 FPM 与 G 值给出 `Nice`、`Stable`、`Attention` 或 `UNSTABLE` 四级评价
- 低于 1500 英尺后每 5 秒监测实际机身降水与跑道摩擦状态，轻柔接地时追加来源明确的道面提示
- 独立设置窗口，设置会自动保存
- 支持分析完成后立刻显示，或地速低于 30 kt 后显示
- 支持 30、60、120 秒三档显示时长
- 支持九宫格屏幕位置选择和 5 秒位置预览
- 支持横向与竖向两种数据窗口布局
- 支持 25%、50%、100% 三档背景透明度
- 每次落地自动在 `LMM_Log` 中生成 UTF-8 中文 TXT
- 使用垂直投影、G 冲量与物理速度变化交叉验证，区分持续冲击和单帧尖峰
- 使用固定环形缓冲区，并把采集、两阶段分析、评分、机场查询与日志写入分散到不同帧

## 运行要求

- X-Plane 12
- 支持浮动窗口与 ImGui 的 FlyWithLua NG+

## 安装

1. 从 [Releases](https://github.com/Starlux531/StarLux-Landing-Meter/releases) 下载最新压缩包。
2. 解压后，将以下内容放入 FlyWithLua 的 `Scripts` 文件夹：

   - `StarLux_LMM_v0.7.2.lua`
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

插件加载时会在脚本目录创建 `LMM_Log`。每次有效落地会采集最多约 0.35 秒的第一次起落架压缩数据；采集可在垂直速度停止下降或出现反弹时提前结束。速度分析、冲量分析与最终评分分布在后续帧执行。选择“立刻”时，窗口会在最终结果就绪后显示；约 3 秒后识别机场，约 8 秒后生成独立记录并显示完成提示，例如：

```text
LMM_Log/LMM_ZSPD_17_2026-07-20_21-30-45.txt
```

记录内容包括：

- 落地时间与总体评价
- 机型、落地机场、机场名称与推算跑道号
- 触地前三分钟内确认的实际降水、跑道摩擦状态、判断来源与道面提示
- 物理下降率、VVI 对照值和最终过载
- IAS、TAS、GS
- 迎角、横滚角、磁航向
- 风向、风速和相对风
- 原始 G、垂直投影 G、冲量等效 G、可信度及采样质量
- 评分阈值及本次使用的显示设置
- 本次使用的横向/竖向布局与透明度档位

跑道号根据触地磁航向推算，因此会显示为 `RWY ~17` 这类格式；当前版本不区分平行跑道的 `L/R/C`。

插件不会联网，也不会主动上传任何飞行数据。仓库内的 `LMM_Log` 仅为作者明确打包的实飞测试样本。

## 默认评分阈值

| 评价 | 颜色 | 下降率 | 过载 |
|---|---|---:|---:|
| Nice 轻柔接地 | `#14803D` | ≤ 100 fpm | ≤ 1.20 G |
| Stable 稳定扎实落地 | `#12529E` | ≤ 250 fpm | ≤ 1.50 G |
| Attention 需注意 | `#C7850F` | ≤ 300 fpm | ≤ 1.80 G |
| UNSTABLE 重着陆 | `#B81A1F` | > 300 fpm，或过载超限 | > 1.80 G，或下降率超限 |

最终评价取 FPM 与 G 两项中较严重的等级，不会将两项平均或相互抵消。FPM 显示和评分采用 250 毫秒分位值；G 冲量只对应第一次压缩，因此使用紧邻接地的 80 毫秒速度，避免混用不同时间尺度。G 值会先按俯仰和横滚投影到垂直方向，再将 G 曲线产生的冲量与物理垂直速度变化交叉验证：一致性高时主要相信曲线，单帧尖峰或采样不足时降低可信度并采用保守的等效值或备用上限。公开评分阈值不因可信度算法改变。这些阈值目前是插件标准，并非航空公司运行标准。

## 故障排查

如果设置或日志无法保存，请检查 X-Plane 目录的写入权限，并查看 `X-Plane 12/Log.txt` 中以 `[StarLux LMM]` 开头的信息。

## 参与贡献

欢迎提交 Issue 和 Pull Request。开始修改前请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

本项目采用 [MIT License](LICENSE) 开源。

X-Plane、FlyWithLua 及相关名称归各自权利人所有。本项目与其官方开发者无隶属关系。

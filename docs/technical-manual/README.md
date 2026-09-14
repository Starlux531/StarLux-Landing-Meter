# 技术手册 1.0 正式版 / Technical Manual 1.0 Final

适用插件：**1.1.8**。手册与插件独立编号。本版取代基于 0.8.2 的预发布说明，按公开源码解释运行算法，而不是产品宣传或航空公司批准标准。

Applies to **plugin 1.1.8**. The manual has its own version number. This edition supersedes the 0.8.2 prerelease description and documents the public implementation, not airline-approved standards.

| 语言 / Language | 阅读 / Read | 可维护源文件 / Editable source |
| --- | --- | --- |
| 中文 | [PDF · 16 页](StarLux_LMM_Technical_Manual_1.0_CN.pdf) | [Markdown](StarLux_LMM_Technical_Manual_1.0_CN.md) |
| English | [PDF · 17 pages](StarLux_LMM_Technical_Manual_1.0_EN.pdf) | [Markdown](StarLux_LMM_Technical_Manual_1.0_EN.md) |

涵盖数据契约、采样与状态机、FPM 选源、固定窗 G 和冲量复核、延长接地轨迹、弹跳与中心线评级、机场几何匹配与增量索引、操纵/发动机接口、报告写盘、分析器显示边界及复核/移植要求。

Covers acquisition, sampling/state transitions, FPM selection, fixed-window G and impulse review, extended touchdown capture, bounce/centerline ratings, airport geometry and incremental indexing, control/engine interfaces, report writing, analyzer limitations and verification/porting requirements.

**Source baseline:** [`6a1c62ab433a764afecb14e98fb7f1b4b91f548e`](https://github.com/Starlux531/StarLux-Landing-Meter/tree/6a1c62ab433a764afecb14e98fb7f1b4b91f548e). Published 2026-09-14. Both languages use the same section numbering and implementation boundaries. Unpublished 1.1.9 work is excluded.

## 重建 PDF / Rebuild PDFs

Install Python and `reportlab`, then run from the repository root:

```powershell
python tools/build_technical_manual.py
```

默认生成到 `output/pdf/`。Windows 默认使用本机 Microsoft YaHei；其他系统通过 `--font`、`--bold-font` 指定允许嵌入、包含中英文字形的 TrueType 字体（或 TTC 第一个字体）。不随仓库分发系统字体。

Output defaults to `output/pdf/`. Windows defaults to locally installed Microsoft YaHei. On other systems, pass `--font` and `--bold-font` with embeddable TrueType fonts (or the first face of a TTC) covering Chinese and English. System font files are not distributed in the repository.

PDF 提交前需渲染逐页检查、确认目录/书签、长接口名换行和双语数值一致，然后将已审核 PDF 放入本目录。字号及字体变更可能影响页数，请同步上表。示例为合成算例；文档核对不等于全机模实机准确度认证。

Before publishing, render and inspect every page, check contents/bookmarks, long DataRef wrapping and bilingual numerical consistency, then copy the reviewed PDFs into this directory. Font/layout changes may alter page counts; update the table accordingly. Examples are synthetic; document review is not universal in-simulator accuracy certification.

## 历史资料 / Historical material

[0.8.2 核心算法旧手册 / Historical manual](../StarLux_LMM_v0.8.2_核心算法技术说明手册.pdf) 保留供追溯，不适用于重算 1.1.8。Its PRE-1.0 algorithms do not describe the current implementation.

# StarLux Landing Meter 路线图

## 当前：1.1.9RC9 稳定阶段

2026-10-10：当前 GitHub 公开稳定版为 1.1.9RC9 / 安装器 1.0.4，已整合自公开 RC4 以来的改进。已交付项目按最终行为整理在 [CHANGELOG](CHANGELOG.md)，不再把中途替换的方案列为待开发功能。

1.1.x 进入冻结阶段，不再安排后续错误修复版本；下一版本直接进入 1.2.0。现有问题及试飞反馈留作重写时的回归依据。本次不改变 FPM/G 评分规则，新的 G 评分方案暂不实施。

## 1.2.0：原生 XPL 重写

- 使用原生 XPL 重写插件，脱离 FlyWithLua，整理数据采集、分析、界面与存储接口，为多平台移植打基础。
- 在重写版中接入 SkunkCrafts 等第三方更新器，明确文件清单、平台产物与更新渠道。
- 为 737 与 A319/A320/A321 系列加入基础 QAR 事件，补充训练状态复盘；各机模的数据接口与判定需单独验证。
- 将落地俯视图扩展为「进近平面图」：在现有 OSM 底图基础上逐步增加机场、跑道、VOR、ILS、航路点与限制等导航内容，展示机场周边与进近航迹。
- 在重写过程中处理已记录的缺陷、性能问题与小型体验改进，延续现有日志的复盘能力。

以上属于开发计划，未包含在 RC9 中，不承诺尚未验证的机模或平台支持。

## 更远期

探索多平台 **Starlux Black Box** 全航程记录插件，以及独立的专业训练工具；独立落地记录器继续免费并保持完整可用。

## English

RC9 is the public stable release as of October 10, 2026, with installer 1.0.4, consolidating improvements since public RC4. No further 1.1.x bug-fix releases are planned; feedback becomes input for the next version.

**1.2.0** will rewrite the plugin as a native XPL, moving beyond FlyWithLua and preparing for multiple platforms. Planned work includes third-party updating through SkunkCrafts, basic QAR events for 737 and A319/A320/A321 aircraft, and an approach plan view with airport/runway geometry, VOR, ILS, waypoints and restrictions. These require development and validation and are not RC9 features.

Further ahead, we plan a multi-platform **Starlux Black Box** full-flight recorder, potentially alongside separate professional training tools, while the standalone landing recorder remains free and fully usable.

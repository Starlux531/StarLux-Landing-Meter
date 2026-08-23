StarLux Landing Meter v1.1.4 稳定测试版双发行预设
==================================================

两个发行版本共用完全相同的 Lua、HTML、算法和文档，只替换初始化设置文件。FlyWithLua ImGui 设置窗口和落地记录管理器固定使用英文；宏菜单保留双语“打开设置/Open Setting”与“落地记录/Landing Record”：

1. 国内版：使用“国内版/LMM_Settings.cfg”，首次启动默认为中文。
2. 国际版：使用“国际版/LMM_Settings.cfg”，首次启动默认为英文。

“Data output language”决定新生成 TXT 报告的正文语言与文件名标记：Chinese 使用 _CN，English 使用 _EN。
两套报告均可由同一个 LMM_Report_Reader.html 读取和对比。

用户首次保存设置后，数据输出语言会以 document_language 写入自己的 LMM_Settings.cfg；旧 interface_language 会自动迁移。
插件内打开报告时，Lua 会把当前语言传给同一份 LMM_Report_Reader.html。
独立双击阅读器时，优先使用用户上次在网页选择的语言；首次打开则跟随浏览器语言。

建议以后发布两个压缩包：
- StarLux-Landing-Meter-v1.1.4-CN.zip
- StarLux-Landing-Meter-v1.1.4-International.zip

除 LMM_Settings.cfg 中的 document_language 外，不允许两个压缩包出现代码差异。

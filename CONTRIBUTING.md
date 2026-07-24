# 参与贡献

感谢你改进 StarLux Landing Meter。

## 提交问题

提交 Bug 时，请尽量包含：

- X-Plane、FlyWithLua 和插件版本
- 使用的机模
- 可重复问题的操作步骤
- `X-Plane 12/Log.txt` 中相关的 `[StarLux LMM]` 信息
- 如涉及数据异常，请附上对应的 `LMM_Log`，并先检查其中是否包含不希望公开的信息

## 提交代码

1. Fork 本仓库并创建描述明确的分支。
2. 保持 Lua 5.1/LuaJIT 与 FlyWithLua NG+ 兼容。
3. 不要提交个人 `LMM_Log`、自动生成的 `LMM_Viewer*` 或本机设置改动；如需调整正式版默认设置，请在 Pull Request 中明确说明。
4. 对设置界面、触地检测或日志格式的修改，请在 Pull Request 中说明验证方法。
5. 更新 `CHANGELOG.md` 中对应的未发布内容。

提交代码即表示你同意按照本项目的 MIT License 发布你的贡献。

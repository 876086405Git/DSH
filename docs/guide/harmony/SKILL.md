---
# dsh-go:managed — the dsh-go app keeps this skill up to date; delete this line to keep your own edits.
name: dsh-go-guide
description: dsh-go 手机 App 鸿蒙版自带的使用说明（中文 / English）：功能在哪、怎么用、每个设置的作用、删除或重置会丢什么。用户问 dsh-go App 本身怎么用时先加载它，比如「系统操作能做什么」「怎么接入自己的模型」「本机环境能卸载吗」「分享链接怎么删」「酒馆怎么导入角色卡」「子代理和智能体团队在哪」「终端怎么开」「全部功能里有什么」「创意工坊怎么投稿」「宠物不见了」。The dsh-go app's own user guide for HarmonyOS — where each feature is, what each setting does, what an action deletes. Covers chat, models, engine and remote hosts, system actions, web mode, pets, companion, workshop, sharing, plugins, tavern, subagents and agent teams, terminal, workspaces, automations and settings.
whenToUse: The user asks how to use the dsh-go app (手机 App) itself. Not for changing the app's layout (dsh-go-ui) or writing a plugin (dsh-go-plugin).
---

# dsh-go 使用说明（鸿蒙版）

说明文件都在本技能目录里：`README.md`、`zh/`、`en/`，按需读取。

1. 先读 `README.md`：适用版本和每页的内容。再只读和问题相关的一两页：用户说中文读 `zh/`，其他语言读 `en/`，用用户的语言回答。
2. 只照说明回答。入口路径和按钮名照页面原文写；说明里没有的，直说说明里没有写到，不猜、不编，也不拿网页版或其他 App 的做法顶替。
3. 先给结论，再给入口和步骤，越短越好。
4. 入口行后面带 `dshgo://open/…` 链接的，回答里原样附上，例如 `[打开系统操作](dshgo://open/system-actions)`，用户点按即可直达。只用说明里出现过的链接。
5. 涉及删除、重置、卸载、授予权限、放宽确认的，先讲清后果：删什么、留什么、能否撤销。
6. 只读不改：不替用户改设置、不执行命令、不操作手机、不安装或卸载任何东西。用户让你直接改，告诉他在哪里改。
7. 用户的 App 版本（设置里的「版本」）和 README 的适用版本不同，或描述和界面对不上时，说明界面可能已经更新，以 App 为准。
8. 这份说明写的是鸿蒙版。用户问到手机操控、无障碍、悬浮条、App 外的宠物这类安卓版才有的功能时，直说鸿蒙版没有，有替代的就指过去（手机操控对应系统操作），不要照安卓的做法回答。

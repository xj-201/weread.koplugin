# PickThought 官方核心代码来源

- 上游仓库：`https://github.com/Mr54233/pickthought.koplugin`
- 上游固定提交：`75ae7e094ce816539db21c2decabbc38189a1ff6`
- 导入目标：`weread/pickthought/`
- 本地 Lua 命名空间：`weread.pickthought.*`
- 导入原则：保持上游核心模块实现，仅将 `require("pickthought.*")` 改为 `require("weread.pickthought.*")`。

## 已导入核心模块

- 注入/映射：`annotations.lua`, `annotation_style.lua`, `chapter_map.lua`, `epub_inject.lua`, `epub_reader.lua`, `spine_cache.lua`, `sync_budget.lua`, `sync.lua`
- 想法存储/锚点：`thought_db.lua`, `thoughts.lua`, `binding.lua`
- 评论：`review_comments.lua`
- 弹窗：`thought_popup.lua`, `thought_popup/*.lua`
- 基础支持：`config.lua`, `diagnostic.lua`, `json.lua`, `performance_mode.lua`, `util.lua`

## 有意不导入的独立插件功能

独立插件入口、独立登录与 Cookie、账户管理、独立书籍管理、独立菜单、同步 UI/任务控制器、更新器、独立网络协议/HTTP 客户端未导入。后续应由 WeRead 已有登录态、`Client`、书籍绑定和任务生命周期提供适配。

## 当前状态

本次提交只完成官方核心模块的 vendoring 和命名空间隔离，不表示已完成 WeRead 接入。下一步需要编写 WeRead 适配层，将 PickThought 同步/注入契约接到 WeRead API、书籍绑定和阅读生命周期，并替换旧想法注入入口；评论 API 复用 WeRead `Client:get_review_comments`。完成前不要把当前分支当作可安装测试包。

# KOReader 微信读书插件调试记录 (WeRead KOPlugin Debug Logs)

本目录记录注入副本与标注同步过程中的问题排查日志与分析报告：

1. **[2026-11-02-inject-copy-invalid-link.md](./2026-11-02-inject-copy-invalid-link.md)（最新）**：
   - **版本**：WeRead `1.6.0`
   - **状态**：SQLite 写库错误已消除，标注匹配正常完成；但点击划线想法触发 KOReader 原生“无效或外部链接”弹窗（`#_doc_fragment_..._pickthought-...`）。
   - **相关文件**：[`2026-11-02-inject-copy-invalid-link.log`](./2026-11-02-inject-copy-invalid-link.log) | [`2026-11-02-inject-copy-invalid-link.png`](./2026-11-02-inject-copy-invalid-link.png)

2. **[2026-11-02-inject-copy-crash.md](./2026-11-02-inject-copy-crash.md)（历史记录 1）**：
   - **版本**：WeRead `1.6.0-merged`
   - **状态**：注入副本后因 SQLite 缺少 `review_id` 字段持续报错导致卡死与看门狗重启。
   - **相关文件**：[`2026-11-02-inject-copy-crash.log`](./2026-11-02-inject-copy-crash.log) | [`2026-11-02-inject-copy-crash.jpg`](./2026-11-02-inject-copy-crash.jpg)

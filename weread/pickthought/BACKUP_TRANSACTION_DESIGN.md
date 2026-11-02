# PickThought EPUB 备份事务重构

状态：设计阶段；本文件不改变现有同步行为。

## 目标与不变量

将 `sync.lua` 中分散的 `.orig`、`.old`、`.orig.old`、`.kept-*` 文件操作收敛到一个备份事务模块。最终不再依靠文件后缀推断版本，而由事务清单明确记录文件角色、版本关系和操作阶段。

必须保持以下不变量：

1. 阅读中的 EPUB 始终位于原来的 `doc_path`，不改变 KOReader 阅读进度侧车路径。
2. 标准干净基线只代表当前注入版对应的那一份 EPUB；不匹配的干净 EPUB 不能放回标准基线路径。
3. 新候选 EPUB 完整生成并验证前，不移动活动 EPUB。
4. 事务提交前，操作开始时的活动 EPUB 和原有干净基线都必须可恢复。
5. 只有活动 EPUB 与干净基线都验证成功、提交清单写入并重新读取确认后，事务才算提交。
6. 未识别、无法解析、版本关系不明或指纹冲突的文件一律保留，不自动覆盖或删除。
7. 恢复过程必须幂等；重复启动恢复不能重复移动、覆盖或删除文件。

## 目标目录

目录放在书籍旁边，避免把 EPUB 本身移出书架路径：

```text
<book>.epub
<book>.epub.pickthought/
    manifest.json
    original.epub
    transactions/
        <transaction-id>/
            transaction.json
            candidate.epub
            new-original.epub
            previous-current.epub
            previous-original.epub
```

文件语义：

- `<book>.epub`：唯一活动阅读文件。
- `original.epub`：当前注入版对应的标准干净基线。
- 根目录 `manifest.json`：事务根清单，记录当前活动事务、最近一次已提交事务和 schema 版本。
- `transaction.json`：本次事务的阶段、操作类型和文件角色。
- `candidate.epub`：本次生成、尚未安装的注入候选。
- `new-original.epub`：首次注入或显式使用外部 clean_source 时准备采用的新干净基线。
- `previous-current.epub`：本次操作前的活动 EPUB，通过同文件系统 rename 暂存。
- `previous-original.epub`：本次操作前的干净基线；只有需要更换基线时才暂存。

事务目录使用唯一 ID，禁止复用已有目录。最近一次已提交事务保留为回退点；只有下一笔事务提交并验证成功后，才允许清理更早的事务目录。清理失败只产生警告，不得回滚已提交的新书。

## 清单字段

根清单至少包含：

- `schema_version`
- `active_transaction_id`（无活动事务时为 null）
- `last_committed_transaction_id`
- `state`

事务清单至少包含：

- `schema_version`
- `transaction_id`
- `operation`：`initial`、`append` 或 `rebuild`
- `state`
- `doc_path`
- 每个事务文件的相对路径和角色
- `original_changed`
- 文件大小、文件指纹及 EPUB MARKER 校验结果

清单路径必须是事务目录内的相对路径；拒绝绝对路径、目录穿越和未知文件名。不能只凭文件名或 MARKER 判断版本关系。指纹实现需先审查 KOReader 运行环境可用的哈希能力，再确定轻量、流式的实现；不能为了设计文档而假定 Kindle 上有 `sha256sum` 或 OpenSSL 命令。

## 状态机

```text
idle
  -> preparing
  -> prepared
  -> current_staged
  -> candidate_installed
  -> committed
  -> idle
```

- `preparing`：创建唯一事务目录，生成 candidate/new-original；活动 EPUB 和标准 original 不动。
- `prepared`：候选文件已关闭，并通过 EPUB 解析、注入 MARKER、大小和指纹校验。
- `current_staged`：操作前的 doc_path 已 rename 到 previous-current；若更换基线，旧 original 也已安全暂存。
- `candidate_installed`：candidate 已 rename 到 doc_path；事务仍未提交，previous-current 和 previous-original 仍保留。
- `committed`：doc_path 与 original（如本次更新）均已重新读取验证，事务清单也重新读取确认。
- `idle`：无活动事务，根清单指向最近一次已提交事务。

每次文件移动前先写入描述下一步的状态，移动后再更新状态。状态写入报告失败时，必须重新读取清单并检查文件，不得仅凭写入函数的返回值推断磁盘状态。原子写入不等于断电持久化；需要单独验证 KOReader 文件系统上的 flush/rename 行为。

## 三种操作的事务语义

### 首次注入

- 当前 doc_path 是干净原书。
- 从 doc_path 生成 candidate，并在事务目录准备 new-original。
- 验证两份文件后，将 doc_path 暂存为 previous-current。
- 安装 candidate，再将 new-original 安装为标准 original。
- 两者验证通过后提交。

### 增量注入

- 标准 original 不变。
- 从当前注入版生成 candidate。
- 验证后暂存 previous-current，再安装 candidate。
- 失败只恢复 previous-current，不触碰 original。

### 全量重建

- 使用标准 original 时，标准 original 不变。
- 显式使用外部 clean_source 时，先准备 new-original；提交期间同时保留 previous-current 和 previous-original。
- 新活动书和新基线必须作为同一笔事务提交。
- 失败时恢复操作前的活动书和基线；如果两者无法确认属于同一版本，不得把任一份自动登记为标准 original。

## 崩溃恢复原则

恢复先验证根清单和事务清单，再核对文件角色、文件指纹及 EPUB MARKER，最后决定动作；禁止只看路径是否存在。

| 崩溃位置 | 恢复原则 |
|---|---|
| preparing / prepared | 活动书未移动；保留活动书。确认事务文件归属后才清理未完成候选 |
| current_staged | doc_path 缺失时，仅当 previous-current 身份匹配事务清单才恢复 |
| candidate_installed | 验证 doc_path 是否为 candidate；候选及新基线都完整时可继续提交，否则回滚两者 |
| committed | doc_path 和 original 已验证；保留最近一次事务作为回退点 |
| 清单损坏、路径越界、指纹冲突 | 不自动覆盖任何文件；列出候选路径并停止，等待人工处理 |

特别处理 rename 失败：源路径应保留；目标路径若已存在，不允许盲目覆盖。恢复动作失败时不得再尝试用另一份“看起来干净”的 EPUB 覆盖 doc_path，除非清单能证明它就是本事务的 previous-current。

## 旧格式兼容迁移

迁移与普通同步分离，分为识别、预览、执行三个步骤：

1. 识别 `.orig`、`.old`、`.orig.old`、`.old.kept-*`、`.orig.old.kept-*`、`.orig.kept-restore-*`。
2. 对每个候选读取 EPUB 元数据和 MARKER，记录大小、时间及可用指纹；无法解析的文件标记为 unknown。
3. 只有活动书与干净备份的版本关系无歧义时，才允许自动迁移。
4. 有多个干净 EPUB、不同版本或 unknown 文件时，只生成迁移报告，不移动、不覆盖、不删除。
5. 迁移成功后仍保留旧文件；至少经过一次成功同步和一次重启恢复验证后，才允许用户明确确认清理。
6. 新格式事务提交前，旧版 `.orig` 只能作为只读候选来源，不能静默覆盖或删除。

## 测试矩阵

独立事务模块必须用可注入的文件操作依赖做故障注入，至少覆盖：

- 首次注入：每个 manifest 写入点、每次 rename、候选安装和基线安装失败。
- 增量注入：candidate 生成失败、活动书暂存失败、安装失败、恢复失败。
- 使用 original 全量重建：原书与基线不变、失败回滚。
- clean_source 重建：旧当前书与旧基线属于同一版本、属于不同版本、当前书本身是干净书。
- rename 返回失败但源/目标路径状态变化的异常情况。
- manifest 写入返回失败但新清单实际已落盘的情况。
- 进程在每个状态转换后被强制终止，再启动恢复；恢复重复执行两次仍得到相同状态。
- 事务目录已有同名文件、磁盘空间不足、读/写/flush/close 失败。
- 未知旧备份、损坏 EPUB、多个干净版本并存时只报告、不删除。

## 实施顺序

1. 先完成现有文件状态组合审计，记录旧格式每种文件的语义和可恢复条件。
2. 新增独立文件事务模块及上述故障注入测试，不接管生产流程。
3. 在测试中验证首次注入、增量、全量重建和 clean_source 重建。
4. 再将 sync.lua 的文件替换逻辑切换到事务模块；章节映射、想法数据库合并和 WeRead 网络流程不随之重写。
5. 新增旧格式只读识别和迁移报告。
6. Kindle PaperWhite 4 上验证强制终止/重启恢复后，再考虑清理旧备份。

## 当前不做

- 不在设计阶段改变现有 `.orig` / `.old` 文件行为。
- 不自动删除历史备份或 unknown 文件。
- 不假设 POSIX rename、manifest 原子写入和文件系统持久化在所有设备上具有完全相同的故障语义。
- 不把 Lua 语法检查通过当作事务正确性证明；必须有故障注入测试和 Kindle 实机验证。

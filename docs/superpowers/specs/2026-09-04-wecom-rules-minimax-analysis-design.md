# 企业微信规则与 MiniMax 定时分析设计

## 目标

在当前 macOS 13 / Swift 5.2.4 机器上保留已稳定运行的企业微信群通知监听器，补上 wxFomo 原版的五条默认本地规则，并使用中国大陆站 MiniMax Code/Token Plan 定时生成 2 小时、6 小时和 24 小时群聊分析报告。

监听、规则计算、AI 调用和数据保存都在 Mac 上进行。现有 Mac/Windows 局域网工作台仍是密码保护的严格只读窗口；以后 SignalHub 也只需读取同一批规则和分析结果。

## 已确认的产品决定

- 使用与当前机器兼容的独立 Python 3.7 后台分析器，不要求升级到 macOS 14 / Swift 5.10。
- AI 供应商是中国大陆站 MiniMax，使用 Anthropic 兼容协议。
- 默认 Base URL 是 `https://api.minimaxi.com/anthropic`，请求端点是 `/v1/messages`，模型是 `MiniMax-M2.7`。
- 本地规则对新消息尽快生效，AI 不逐条调用，只生成 2/6/24 小时聚合报告。
- 没有新消息的窗口不调用 AI。
- Mac 关机、休眠或进程中断后，每种周期最多补最近遗漏的一份，不追补更早历史窗口。
- 用户已确认：允许把已配置监听群中的群名、发送者、时间、消息类型和正文发送给 MiniMax 进行分析。
- 已经在对话里出现过的 MiniMax 密钥视为已泄露，不保存、不测试、不写入代码或文档；实际部署必须使用新生成的密钥。

## 范围

### 本轮包含

- 五条 wxFomo 默认规则的兼容实现。
- 历史和新消息的规则匹配、标签、优先级和提醒记录。
- 2/6/24 小时固定窗口的 AI 任务调度、持久化、重试、恢复和去重。
- MiniMax Anthropic 兼容 API 请求、严格 JSON 结果解析和来源 ID 校验。
- 大窗口消息的无丢弃分块分析和最终合并。
- 新增的分析库、后台健康状态和工作台只读 API。
- 收件箱规则标签、监控规则、优先关注、提醒中心和分析记录页的真实数据。
- 无回显的 Mac 本地密钥配置工具。
- 现有启动器对监听器、分析器和只读网页服务的统一管理。

### 本轮不包含

- Windows 或 SignalHub 修改规则、密钥或调度。
- 自定义规则编辑器。
- 逐条消息 AI 调用。
- 语音播报、GMGN 交易、自动买卖或行情数据补全。
- 为了降低成本而随机抽样、仅保留高优先级消息或截断时间窗口。
- 公网暴露、云端同步或更改现有局域网访问密码。

## 架构

```text
企业微信通知
      ↓
wecom-group-listener.swift
      ↓ 单一写入者
messages.sqlite3
      ↓ 只读输入
wxfomo-analysis-worker.py
      ├─→ 本地默认规则
      ├─→ 2h / 6h / 24h 任务调度
      └─→ MiniMax-M2.7
                ↓ 单一写入者
          analysis.sqlite3
                ↓ 只读查询
       wxfomo-lan-server.py
                ↓
       Mac / Windows 工作台
```

### 进程边界

1. `wecom-group-listener.swift` 仍只负责验证企业微信通知和幂等写入 `messages.sqlite3`。本轮不把 AI 网络请求放进这个已经经过大量迁移验证的 Swift 5.2 脚本。
2. `wxfomo-analysis-worker.py` 是兼容 Python 3.7 且不依赖第三方包的持久后台进程。它以 SQLite 只读 URI 打开消息库，是 `analysis.sqlite3` 的唯一写入者。
3. `wxfomo-lan-server.py` 继续只读打开两个数据库。它不创建分析任务、不调用 MiniMax、不读取或返回密钥。
4. `start-wxfomo-lan.sh` 生成本次运行的实例 ID，并管理监听器、分析器、网页服务三个子进程。分析器失效不能伪装成正常；诊断页必须单独显示其状态。

## 本地规则

规则语义与 `RecommendedMessageRuleCatalog.rules` 保持一致，按优先级从高到低评估：

| 规则 ID | 优先级 | 条件 | 结果 |
| --- | ---: | --- | --- |
| `recommended.risk.contract-liquidity` | 50 | 包含“貔貅、honeypot、rug、撤池、跑路、黑名单、冻结权限、增发、mint权限、卖不掉”之一 | 捕获、标签“高风险”、`critical` 提醒 |
| `recommended.signal.exit` | 40 | 包含“砸盘、清仓、出货、割肉、止损、撤退”之一 | 捕获、标签“退出信号”、`warning` 提醒 |
| `recommended.signal.accumulation` | 30 | 包含“聪明钱、smart money、大额买入、加仓、建仓、扫货、重仓、看好、吸筹、抄底”之一 | 捕获、标签“资金信号”、`warning` 提醒 |
| `recommended.capture.bare-ca` | 20 | 正文是独立 EVM 格式 `0x` 地址或 32–44 位 Solana/Base58 形式地址 | 捕获、标签“CA” |
| `recommended.capture.market-report` | 10 | 正文在有界长度内同时呈现市值和流动性/池子/地址类字段 | 捕获、标签“行情播报” |

关键词匹配先对文本做 Unicode NFC 规范化，英文大小写不敏感，中文保持原样。一条消息可以同时命中多条规则；标签去重，总优先级取命中规则的最高值，严重度按 `critical > warning > neutral` 合并。

分析器首次启动时遍历现有真实消息并补算规则。后续使用消息表自增 `id` 作为独立插入水位，避免较早时间的通知迟到入库后漏算；旧库迁移时从 0 安全回填。规则批次和水位原子保存，同时依靠 `(event_id, rule_id)` 唯一约束防止重复。原 `(observed_at, event_id)` 游标仅保留作诊断，AI 时间窗仍按 `observed_at` 冻结。内部行 ID 不发送给 AI。此评估没有外部网络请求。

## AI 时间窗与调度

所有时间窗都以 `Asia/Shanghai` 对齐，用半开区间 `[start, end)` 冻结消息 ID，数据库保存 UTC 时间戳：

| 周期 | 窗口边界 | 执行宽限 |
| --- | --- | --- |
| 2 小时 | 每个偶数整点结束 | 结束后 5 分钟 |
| 6 小时 | 00:00、06:00、12:00、18:00 结束 | 结束后 10 分钟 |
| 24 小时 | 每天 00:00 结束 | 结束后 15 分钟 |

宽限时间用来吸收 Notification Center 延迟。三种周期共享单一串行队列；同一时刻同时到期时，顺序是 2 小时、6 小时、24 小时。

任务由 `(cadence, window_start, window_end)` 唯一标识。调度器创建任务时就冻结当时已入库且位于窗口内的事件 ID；之后迟到的通知不会悄然改变已完成报告的输入。窗口为空时持久化一条 `skipped_empty` 状态，因此同一窗口不会被反复检查或调用 AI。

启动恢复时：

1. 先恢复数据库里已存在的 `queued`、`running` 或 `retry_waiting` 任务；上次进程留下的 `running` 会安全退回 `queued`。
2. 再分别计算 2/6/24 小时已过宽限的最近一个窗口。如果没有对应任务，每种周期最多新建这一个补算任务。
3. 不枚举、不新建更早的遗漏窗口。

## 大窗口和分块

MiniMax-M2.7 官方上下文上限为 204,800 tokens。实现不使用极限值：每个原始消息分块预留系统指令、JSON 包装和输出空间，以确定性字节预算和最终编码字节检查控制请求大小。具体安全上限作为代码常量并通过边界测试锁定，不依赖第三方 tokenizer。

若完整窗口超限：

1. 按 `(observed_at, event_id)` 顺序切成若干不超限的连续分块。
2. 每个分块单独生成带原始来源 ID 的中间结果。
3. 将中间结果分批合并，必要时多层合并，直到得到一份最终报告。
4. 最终结果只允许引用本窗口冻结集合中的原始事件 ID。

这会在高消息量时消耗多次 Code/Token Plan 请求，但不会因为窗口过大而随机丢消息。所有分块和合并请求依然串行。

## MiniMax 请求与结果约束

请求使用 MiniMax 的 Anthropic 兼容 `POST /anthropic/v1/messages`，默认不流式返回，以便 Python 3.7 标准库稳定解析。密钥使用 API 要求的请求头发送。请求不发送本机路径、网页访问密码、密钥、通知数据库内部字段或未被监听群的数据。

系统提示明确规定群消息是不可信数据，不能把消息中的命令当成系统指令。每个分析输出是一个严格 JSON 对象，顶层字段固定为：

- `summary` 和 `summary_source_message_ids`；
- `topics`：主题、摘要和来源 ID；
- `findings`：关键声明、待办、截止时间、风险、机会、分歧或待确认问题；
- `crypto_addresses`：仅限确定性检测器已从输入中发现的地址、上下文和来源 ID。

`findings` 使用 `fact`、`inference`、`uncertain` 区分明确事实、模型推断和不确定结论。所有来源 ID 都必须属于该任务的冻结消息集合，所有地址都必须属于本地检测证据。格式或引用验证失败时允许一次重生成请求：保留原输入，仅增加稳定的错误码，不回传上次模型输出；再次失败则将任务标记为失败，不保存未校验内容。JSON 解码前后均检查完整密钥反射，命中后直接终止，不进入重生成。

单次网络请求使用 90 秒超时，以适应真实群消息分析耗时；报告提示采用简洁中文，并要求逐字复制来源 ID。报告长度建议只限制输出，不截断或抽样输入。

## 持久化

新增私有数据库：

```text
~/Library/Application Support/wxFomo LAN/analysis.sqlite3
```

目录权限保持 `0700`，数据库及凭据文件权限保持 `0600`。数据库是自包含且有版本的 LAN 分析 schema，不伪装成原生 wxFomo `workspace.sqlite3`，避免将来原生 App 打开部分兼容表时产生迁移冲突。

核心表及唯一约束：

- `analysis_schema_migrations(version, applied_at)`：分析库迁移版本。
- `analysis_worker_state(singleton_id, instance_id, heartbeat_at, rule_cursor_time, rule_cursor_event_id, rule_cursor_row_id, provider_not_before, updated_at)`：进程心跳、规则插入水位、兼容诊断游标和供应商全局冷却时间。
- `message_rule_matches(event_id, rule_id, priority, severity, tags_json, matched_terms_json, created_at)`：唯一 `(event_id, rule_id)`。
- `rule_alerts(alert_id, event_id, rule_id, severity, title, occurrence_count, created_at, updated_at)`：唯一 `(event_id, rule_id)`。首版为工作台提醒记录，不额外触发 macOS 系统弹窗。
- `analysis_jobs(job_id, cadence, window_start, window_end, state, source_event_ids_json, attempt, maximum_attempts, next_attempt_at, error_code, created_at, updated_at)`：唯一 `(cadence, window_start, window_end)`。
- `analysis_results(analysis_id, job_id, result_json, model, provider_request_id, input_tokens, output_tokens, created_at, updated_at)`：唯一 `job_id`。

不保存 API Key、完整请求头或 MiniMax 返回的隐式思考内容。错误字段仅保存稳定的脱敏代码，例如 `credential_unavailable`、`rate_limited`、`transport_error`、`invalid_response`。

## 密钥配置

新增一个 Mac 本地配置工具和可双击的 `.command` 入口。工具使用无回显密码输入，要求输入两次且一致，原子写入：

```text
~/Library/Application Support/wxFomo LAN/ai-credentials.json
```

凭据文件只保存 MiniMax API Key；Base URL、模型和调度采用可审计的非秘密默认配置。配置工具不接受命令行明文密钥，不把密钥写入 shell 历史。工作台只显示“已配置/未配置”、模型和最近一次检查状态，不显示密钥长度、前缀、后缀或哈希。

配置工具仅做格式检查和安全保存。真实网络校验由用户明确选择的“测试连接”操作触发，避免保存时悄然消耗 Code/Token Plan 额度。

## 任务状态、重试和额度

任务状态至少包含 `queued`、`running`、`retry_waiting`、`succeeded`、`failed`、`skipped_empty`、`credential_required`。分析器一次只处理一个网络请求。

- 连接超时、DNS 失败和 HTTP 5xx：同一任务按 1、5、15、60 分钟等待后重试，总尝试数不超过 5 次。
- HTTP 429：优先遵守合法的 `Retry-After`；没有时按 5 小时等待，以对齐 Code/Token Plan 文档化的滚动窗口。等待时间同时写入供应商全局冷却时间，在冷却到期前不让其它周期任务反复命中同一限额。
- HTTP 401/403：任务进入 `credential_required`，同一密钥下不自动重试。凭据文件安全更新后，分析器可重新排队该任务。
- HTTP 400 或本地请求验证失败：标记为永久失败，不重试。
- 任务已达最大尝试次数：保留失败记录和脱敏原因，不自动创建相同窗口的新任务。

“只补最近一次”限制的是启动时新建历史窗口，不会丢弃已持久化任务的正常重试。

## 只读 API 与工作台

网页服务新增 `analysis.sqlite3` 只读仓库，并用 LAN 分析数据填充已有页面：

- `/api/messages`：每条消息附带去重的 `tags`、`matchedRules`、`priority`、`severity` 和脱敏后的 `matchedTerms`。
- `/api/rules`：返回五条默认规则的条件、优先级和动作，明确标记为本地默认且只读。
- `/api/alerts`：返回高风险、退出和资金信号提醒，并用现有精确事件 ID 查询补齐来源消息。
- `/api/priority`：按最高优先级、时间倒序显示命中规则的消息。
- `/api/analyses`：返回 2/6/24 小时任务状态、结果、模型、时间窗和来源消息；运行中、等待重试和失败都有明确可读状态。
- `/api/settings/status`：只返回 AI 是否已配置、协议、模型和安全的连接状态，不返回凭据内容或凭据指纹。
- `/api/diagnostics`：单独报告分析器心跳、分析库状态、最近一次成功和最近一次脱敏错误。

API 使用完整冻结 ID 集合校验报告引用，不将结果条数限制套用到窗口输入。单份报告最多附带 1,000 条来源消息，并优先附带已验证引用；此展示上限不会缩减 AI 分析输入。持久化状态 `retry_waiting` 映射为浏览器已有的 `retry_wait`，诊断重试计数同时兼容两种表示。

工作台收件箱在正文上方显示规则标签和严重度；优先关注和提醒页可回到完整来源消息；分析记录页按周期和窗口展示摘要、主题、风险、机会、待办、不确定结论和 CA。页面仍不提供“立即运行”、修改规则、重试或填写密钥的写操作。

## 安全边界

- 单元和回归测试使用本地假服务器及无效占位凭据，提交不包含真实密钥。经用户授权的本机联网验收只通过已配置的私有凭据文件读取密钥，不将其复制到代码、日志或测试 fixture。
- 凭据只从明确的私有凭据文件读取，不自动扫描 shell 环境变量、其它 AI 工具配置、钥匙串或浏览器存储。
- 凭据目录和文件在每次读取前验证所有者、权限、文件类型和符号链接，不安全时拒绝启动 AI。
- HTTP 请求头、完整请求体、消息正文和 MiniMax 完整响应不进入日志。
- 只允许 HTTPS 的 MiniMax 端点；默认主机和路径是内置常量，首版不允许通过 Windows 页面修改。
- 现有局域网密码仅保护只读工作台，不与 MiniMax 凭据复用。
- 所有消息内容都被视为潜在提示注入数据。分析器只接受固定 schema 输出，不执行模型返回的命令、URL、代码或工具调用。

## 与现有数据的兼容

- `messages.sqlite3` 的现有表、别名迁移和事件 ID 约定不改变。
- 新工作者只读消息库，因此不会与 Swift 监听器争夺 schema 所有权。
- 规则和 AI 结果使用独立 `analysis.sqlite3`，不修改、不创建原生 `~/Library/Application Support/wxFomo/workspace.sqlite3`。
- 网页 API 保留现有字段，仅增加向后兼容字段；现有浏览器会话和访问密码无需重新配置。
- 对已存历史消息执行本地规则补算，但不批量补做所有历史 AI 时间窗。

## 可观测性与隐私化日志

分析器日志只记录：进程启停、心跳、任务 ID、周期、窗口、消息条数、分块数、状态、尝试次数、脱敏错误码和官方返回的非敏感请求 ID。日志不记录群名、发送者、正文、搜索词或凭据。

诊断页显示：

- 分析器是否活跃及最近心跳；
- 本地规则已评估的消息数和最近游标；
- 待处理、重试中、失败和成功任务数；
- AI 是否已配置、模型、协议和最近一次成功时间；
- 最近一次失败的脱敏错误码。

## 错误处理与降级

- 分析器未运行或分析库不可用时，收件箱仍可以显示原始消息，监听不中断。
- 未配置密钥时，本地规则继续运行；AI 任务保留为 `credential_required`，工作台显示明确配置提示。
- MiniMax 失败不回退到其它供应商，也不使用按量计费密钥，避免未经授权的费用。
- 一个周期任务失败不阻塞后续窗口创建，但串行队列对达到重试时间的任务按 `next_attempt_at`、窗口结束时间和周期优先级排序。
- 不能解码的 MiniMax 结果不会以纯文本偷渡到工作台，以免失去来源约束。

## 测试策略

### 单元与集成测试

- 五条默认规则的命中、不命中、多规则命中、大小写、Unicode 规范化和地址边界。
- 历史补算、增量游标、重启幂等和规则数据库唯一约束。
- `Asia/Shanghai` 下 2/6/24 小时边界、宽限、空窗口、重复 tick 和“每种周期只补最近一份”。
- 进程崩溃后 `running` 任务恢复、串行顺序和唯一窗口约束。
- 请求大小边界、按时间分块、多层合并和全量来源 ID 保留。
- 本地假 Anthropic 服务器覆盖成功、thinking+text 内容块、非 JSON、虚构来源 ID、超限响应、400、401、429、5xx 和连接中断。
- 密钥文件原子写入、权限、符号链接拒绝、日志脱敏和所有只读 API 响应的秘密字段扫描。
- 分析库缺失、锁定、损坏、schema 不兼容和工作者心跳过期时的真实降级。
- 前端消息标签、规则页、提醒来源、优先列表、三种分析周期、任务状态和空状态。
- 启动器的子进程就绪、失效传播、终止、日志权限和多实例拒绝。

### 实机验收

1. 不配置 MiniMax 密钥启动全套服务，新消息仍被监听和本地规则分析，工作台不会伪装 AI 可用。
2. 使用新生成的 MiniMax Code/Token Plan 密钥在 Mac 本地配置，显式测试连接成功，任何终端或网页输出都不显示密钥。
3. 用一组可识别且无敏感数据的真实企业微信消息验证标签、优先关注和提醒来源。
4. 通过测试时钟触发 2/6/24 小时任务，确认任务串行、窗口正确、结果持久且可从结论回到来源消息。
5. 模拟关机跨过多个窗口，重启后确认每种周期只新建最近一份补算任务。
6. Mac 和同局域网 Windows 使用现有访问密码查阅同一组规则、提醒和分析结果，且所有非 GET/HEAD 方法仍被拒绝。

## 交付顺序

1. 建立本地规则内核和分析库，先用历史消息验证标签、优先级和提醒。
2. 建立时间窗调度器、任务状态机和只补一次恢复。
3. 建立 MiniMax 请求、结果验证、分块合并和重试。
4. 建立 Mac 本地凭据工具，在不使用真密钥的自动测试通过后再进行实机连接。
5. 扩展只读 API 和工作台，用真实规则、任务和分析数据替换相应空状态。
6. 将分析器纳入启动器，运行自动回归、安全检查和 Mac 实机验收。

## 成功标准

- 收件箱不再是纯消息列表；命中默认规则的历史和新消息都显示正确标签、优先级和提醒。
- 工作台显示真实 2/6/24 小时 MiniMax 任务和分析结果，每个结论的来源都可回到冻结的原始消息。
- 重启不重复生成同一窗口，长时间中断后每种周期最多补最近一份。
- 群消息过多时按序分块并全部参与分析，不因截断或抽样无声丢数据。
- MiniMax 未配置、限额、断网或失败时有可恢复且脱敏的状态，不影响企业微信监听和原始消息查阅。
- 密钥不出现在代码、Git 历史、命令行参数、shell 历史、日志、数据库、网页或 API 响应中。

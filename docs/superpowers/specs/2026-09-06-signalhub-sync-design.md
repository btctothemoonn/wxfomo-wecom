# Mac → Signal：完整总结同步与时效性跨群 CA 提醒

日期：2026-09-06。状态：**设计稿；未实现、未联调、未启用真实发送。**

用户已确认独立同步、保留完整总结、群名和发言人昵称、不上传原始聊天，并已审阅确认本文的跨群 CA 默认规则：1 小时、2 个不同群、正常条件下约 1 分钟可见、30 分钟内不重复提醒、未知链不强行合并。Signal 尚未确认下述 v2 接口扩展，不能把本文当作线上能力。

## 1. 依据与范围

- Mac 仓库：[wecom-summary](https://github.com/btctothemoonn/wecom-summary)，工作分支 `codex/wecom-notification-probe`，本次核对的代码基线 `5233228b7b1b4276edeb45d3facfec70592b2cce`。这是源码版本，不是进程已加载该版本的证明。
- Signal 基线：[接入约定 v1，提交 55dfa50](https://github.com/btctothemoonn/SIgnal-hub/blob/55dfa500c37d550721a9c1aec0f71e9e6496cc90/docs/integrations/wecom-summary/README.md)。其接口、签名、持久确认和资源限制仍作为基础；本文列明必要差异。
- 不改企业微信监听、已配置群、relay 归属边界、2h/6h/24h 调度、MiniMax 配置或源数据库 schema；不增加交易、行情榜或付费历史重跑。
- Mac 仅向 Signal 发起 HTTPS，不开放新的入站端口，不要求公网 SSH。Signal 页面只能在登录后读取，与现有 X/TG 信息流隔离。
- 页面与读 API 均执行用户本人的既有访问授权，不仅隐藏菜单；带群名/昵称的数据不得进入可被匿名读取的页面、日志或共享 CDN 缓存。若 Signal 支持多用户，不能自动向其他登录账号开放。
- 本次授权保留总结中的群名、昵称、观点归属，以及与报告关联的来源元数据；不是上传通讯录、成员列表、完整消息或附件的授权。引用原文仍关闭。

## 2. 设计选择

采用两个独立节奏、一个可靠发送模块：

| 通道 | 输入与节奏 | 网站用途 |
| --- | --- | --- |
| 总结 | 每 60 秒发现已成功落库的新报告；AI 周期不变 | 完整结构化报告、范围、CA 索引、来源缺口 |
| CA 提醒 | 每 10 秒增量检查新采集消息，并维护滚动窗口 | 不等待 AI 的跨群提及卡片与站内新提醒 |

两条通道共用私密配置、签名和独立 SQLite 队列，但使用不同游标、消息类型及去重键。CA 不依赖 AI 是否在线；同步故障不阻塞监听或总结。

不选择“把所有内容压成旧版 summary”：会丢失项目层级、数据口径与风险分歧。也不选择网站远程查询 Mac：Mac 断网时网站仍应能查看服务器缓存。

## 3. 与现有代码、Signal v1 的差异

| 现状 | 同步设计 |
| --- | --- |
| `briefing.py:result_projection` 的 `summary` 只有三条速读，`topics/findings` 为空；完整内容在 `briefing` | 新报告使用传输协议 v2，显式携带完整 `briefing`；不得把三条速读冒充完整正文 |
| `analysis.py:analyses` 展示上海时区最近三个日历日，并非旧文档的最近 30 份 | 同步直接只读结果表，按 `analysis_id` 增量，不依赖展示接口或日期过滤 |
| `cross_ca.py:cross_ca_cards` 接受调用方提供的消息集合，本身没有实时调度或触发阈值 | 报告 CA 取完整冻结输入；实时 CA 另建滚动状态和触发器，两种窗口不得混称 |
| 当前 CA 聚合会把 EVM 地址转成小写作为统计键 | 对外展示地址必须从实际文本保留原样；规范化值仅用于内部匹配，不能覆盖展示值 |
| Signal v1 默认隐藏群名、成员身份并清空引用 | 用户已允许登录后保留名字；只导出实际引用的元数据，不导出消息内容 |
| v1 严格拒绝未知字段和未知版本 | Signal 必须先接受本文扩展；Mac 禁止在 v1 请求里偷偷增加字段或失败后降级成不完整正文 |

最小取数依据：`analysis_store.py` 的 `analysis_results` 字段为 `analysis_id, job_id, result_json, model, provider_request_id, input_tokens, output_tokens, created_at, updated_at`；job 状态更新与结果 INSERT 在同一个事务完成。导出 JOIN `analysis_jobs`，筛选 `state='succeeded' AND analysis_id > checkpoint`，按 analysis_id 升序；从 job 取 cadence/window_start/window_end/source_event_ids_json，从 result.created_at 取生成时间。provider_request_id 和 token 计数不上传。

实时取数参考 `analysis_source.py:MessageSource.after_row_id`，按 `messages.id` 插入序号推进，不能用 observed_at 排序游标漏掉迟到通知。同步保存自己的游标，不借用 worker 的 rule_cursor_row_id；需显式适配 groupName/senderDisplayName/数值时间到 CA 函数的 group/sender/ISO 时间。`inserted_at` 用于入库至网页的延迟测量，`observed_at` 用于滚动窗口；两者不能混淆。

## 4. 总结传输 v2 提议

沿用唯一入口 `POST /api/wecom/ingest`。报告封装为 `{schemaVersion: 2, type: "report", report: {...}}`。`schemaVersion` 是传输协议版本；内部 `briefing.version = 2` 是已有总结结构版本，两者独立。

### 4.1 报告字段

保留 v1 的全部报告字段及其既定限制：`id, revision, cadence, windowStart, windowEnd, generatedAt, summary, model, sourceCount, sourceComplete, sourcesTruncated, topics, findings, caDiscussions, sources`。所有字段必填，不接受未声明的字段。

- `summary` 仍为三条速读的预览，`topics/findings` 对新版固定为空；Signal 详情必须读取 `briefing`。
- `sources` 固定 `[]`；`sourcesTruncated = sourceCount > 0`，表示未分享原始来源文本，不表示总结正文被截断。
- 报告 ID 沿用 v1 的设备、持久化 storeId 与 job_id 摘要组合，revision 使用成功结果的 `analysis_id`。生成时间取结果落库时间，不能取任务创建时间或同步时间。
- `sourceCount` 是冻结输入数量；`sourceComplete` 只表明本地冻结记录是否可完整匹配，不表示采集到了完整群聊。
- 新增以下四个必填字段：

| 字段 | 精确定义 |
| --- | --- |
| `briefing` | 下节定义的完整新版结构；不重新调用模型、不压平、不改写观点 |
| `scope` | `groupNames, timeZone, timeBasis, dataCutoff, frozenCount, analyzedCount, readableCount, missingCount, unknownTimeCount, completeChatHistory, externalVerification` |
| `sourceReferences` | 只包含实际被该报告引用的来源元数据，最多 500 项，每项严格为 `{id, group, sender, observedAt, available}`；**无 content 字段** |
| `caCoverage` | 严格为 `{sourcesComplete, totalItems, exportedItems, truncated}`，明确报告 CA 是否来自完整冻结范围、是否受最多 50 项展示限制 |

`scope.groupNames` 为可读冻结记录中的群名，最多 50 项，每项最多 200 UTF-16 单位；不声称不可读记录属于哪个群。`timeZone = "Asia/Shanghai"`，`timeBasis = "notification_observed_at"`；`dataCutoff` 为实际读取记录中最新采集时间，无可用时间则 null。其余计数为非负安全整数，`frozenCount = analyzedCount = sourceCount`，`readableCount + missingCount = frozenCount`，`unknownTimeCount <= readableCount`。`completeChatHistory` 与 `externalVerification` 均固定 false。

引用编号按该报告冻结输入的原顺序映射为 `M0001` 等本地编号，在该报告内唯一；不是平台消息 ID。同步时将 `briefing` 内所有 `source_message_ids` 映射为这些编号，必须能在 `sourceReferences` 找到。`id` 匹配 `M[0-9]{4,}`，最多 32 字符；`group/sender` 是最多 200 UTF-16 单位的文本或 null；`observedAt` 是 UTC ISO 时间或 null；`available` 是布尔值。找不到原记录时保留编号，其他元数据置 null、available=false，同时增加缺口计数；不能伪造名字、时间或正文。可读记录中缺失的昵称/时间仍用 null。

所有输出时间遵循 v1 的 UTC ISO 8601；页面转换为上海时区并明确“通知采集时间”。没有来源正文时显示“原文仅保存在 Mac，未同步”，不显示虚假的“查看原文”按钮。

### 4.2 完整 briefing

精确字段沿用本次 Mac 基线的 `scripts/wxfomo_lan/briefing.py:validate_briefing`：

- 根：`version, kind, quick_read, projects, events, gaps, business`。
- NOTE：`text, source_message_ids`；quick_read 为 `focus/news/risk` 三个 NOTE。
- project：`name, chain, summary, catalysts, latest, risks, data, addresses, source_message_ids`，最多 8 项。
- data：`value, unit, source, recorded_at, kind, source_message_ids`，每项目最多 4 项；kind 只能是“历史快照”或“个人预测”。
- address：`address, chain, source_message_ids`，每项目最多 1 项；chain 必须等于项目 chain，CA 必须逐字保留本地已验证值。
- event：`event, asset, nature, impact, pending, source_message_ids`，最多 10 项；nature 只能是“自述／转述／推测／待核实”之一。
- gaps：最多 8 个 NOTE。business 为 `progress/notices/blockers` 三个 NOTE 数组及 `tasks`；task 为 `text, owner, deadline, source_message_ids`，各数组最多 10 项。
- market 与 business 的互斥规则、实质结论必须引用、每处最多 5 个引用、空信息的既有写法不变。不用空白引用绕过当前来源校验。

先按现有 Mac 规则验证原报告，再映射引用编号并按传输白名单验证。Mac 目前正文文本限制是 600 个 Python 字符；为无损容纳补充平面字符，v2 briefing 的文本传输上限设为 1200 UTF-16 单位，不能误套 v1 的其他字段限制后截断。地址仍遵守原有 32–44 个 ASCII 字母数字及来源一致性要求。

总请求仍不超过 262144 字节，不接受无效 Unicode、非文本控制字符或未知键；正文即使出现 HTML 字样也只能按文本显示，不能执行。可选的报告 CA 列表按既有排序最多取前 50 项；若与 briefing 引用的并集超过 500 项或超过字节预算，则从末尾减少可选 CA 卡，准确记录 exportedItems/truncated，不能裁改留下的卡片计数。核心 briefing、其必要引用元数据本身超限或含疑似凭证时整份隔离，记录固定错误码，不静默删结论、名字或引用来硬凑上限。有效 CA 本身不是凭证，不能仅因地址较长就拦截。

### 4.3 报告中的 CA

只针对新成功结果，从完整冻结输入计算一次现有规则聚合，再持久化导出快照；重试只重发该快照，不能每分钟重算历史。统计口径、未知 EVM 链按群隔离、同昵称不等于同身份等边界保持不变。

`caDiscussions` 保留 v1 单项格式，groups 可保留群名；其 `sourceMessageIDs` 同样指向上面的本地引用元数据（最多 5 项）。导出引用的并集不得包含未被 briefing 或 CA 实际引用的消息。展示地址取该桶直接来源里首次出现的原样地址；大小写不同的 EVM 原样版本不据此推断为不同合约。没有证据可恢复原样地址时隔离对应导出，不伪造大小写。

源库暂时不可读时重试，不标为空或完整。源库可读但部分冻结记录确实缺失时，正文仍可保留，sourceComplete/caCoverage.sourcesComplete=false，页面展示缺口，聚合数量只代表实际可读记录。

## 5. 新增：时效性跨群 CA 通道

本节默认参数已获用户确认；仍需 Signal 确认对应接口，不代表功能已经启用。

### 5.1 触发与时效

- 默认滚动 **60 分钟内至少 2 个不同的已配置群**，提及同链同 CA 时生成提醒。不以重复消息条数替代不同群数。
- 网络只采用现有文本规则能识别的线索，不访问链接或查询链上行情。未知 EVM 链仍按群隔离，不触发“已确认同链跨群”提醒；页面说明可能因此漏掉未注明链的讨论。
- 同一通知 event_id 只记一次；同昵称及归一化后相同文本的跨群搬运算重复陈述，保留总提及数与重复数。不把多个群搬运同一条消息写成“多人独立证实”。
- 提醒标题应是“跨群提及”，不宣称已核验合约、交易机会或投资价值。无名称证据时只显示 CA，不猜 Ticker。
- Mac 每 10 秒取增量消息；Signal 当前可见提醒区每 15 秒拉取变化，隐藏页面停止，重新打开立即加载。总结列表仍可每 60 秒刷新。
- **目标是正常联网、无积压、页面可见时，从 Mac 采集入库到网页可见不超过 60 秒**；这不是从真实发言时间起算，也不是 SLA。记录采集、检测、接收和浏览器显示时间做实测。企业微信通知未送达、Mac 休眠、积压和断网均需明确显示延迟，不能承诺补回未采集消息。
- 首版是网站卡片及站内新提醒，不申请系统通知权限、不新增邮件/Telegram/浏览器关闭后的 Web Push。

### 5.2 滚动状态、去重与过期

实时通道持有独立的消息读取水位、最小滚动提及记录和提醒 episode 状态，全部写入同步数据库。只在内存里处理新增消息正文；持久滚动记录仅保留事件键、采集时间、群、链、原样地址及去重摘要，不复制聊天正文。

每轮有界分页，未处理完不跳游标；状态变更、生成的固定发送 payload 与读取水位在同一事务提交。窗口按 `(evaluatedAt - 3600 秒, evaluatedAt]` 计算；未知或未来异常采集时间隔离，不强行算成当前。窗口过期也要被定时评估，不能依赖下一条新消息才关闭提醒。

插入游标不涵盖现有 listener 的原位 record_version 更新、别名归并与去重删行。每 60 秒分批核对仍在滚动窗口内的已跟踪 ID/版本及别名，重新投影变更并合并重复事件；发出新的跨群提醒前，再核对该候选桶的直接来源。合法归并不能误报为源库回滚。不能直接调用会截断至 50 卡的返回列表充当完整实时状态，聚合需先完整维护再裁剪网站展示；到达本地容量预算则明确暂停，不假装全量。

- 同一 `(network, normalizedAddress)` 活跃期使用同一提醒 ID，计数/群数变化只更新该卡片，并增加 revision。
- `normalizedAddress` 只作内部键，EVM 小写、Solana 原样；对外 address 为该活跃期首次直接观察到的原样字符串。
- 跨群条件不再成立时结束当前 episode。重新达到条件可新建 episode；同一键 30 分钟内不重复发出站内新提醒，但仍更新/展示最新卡片。
- 不因单纯重复搬运或定时刷新反复弹提醒；新增群等变化体现在卡片上。冷却期结束本身不自动重弹。
- 失去第二个有效群时即过期；不能只用“最后一条消息 + 1 小时”延长活跃状态。expiresAt 取各群最近采集时间中第二新的时间加窗口长度，后续有效消息可更新。
- 断网后保留原 payload。恢复后即使已经过期也作为历史补传，网站按 expiresAt 显示“已过期／延迟收到”，不当作刚触发的新提醒。
- 程序停机不同于单纯发送断网：重启时先记录追赶水位，尚未处理的过期消息仅记录漏检数量并推进游标，不虚构当时曾发出的历史提醒；仍在有效窗口的消息可形成 catchup 卡片，不弹“刚发生”提醒。每轮读到追赶水位之前的来源或发现处理延迟超过 60 秒时，派生提醒标记 catchup=true。

### 5.3 CA 接口扩展提议

新封装：`{schemaVersion: 2, type: "ca_alert", alert: {...}}`。alert 的必填且仅有字段如下：

| 字段 | 规则 |
| --- | --- |
| `id, revision` | 沿用 v1 ID 字符与安全整数限制；ID 为 `wecom-ca:{deviceId}:{storeId}:{本地持久 episode 序号}`，revision 为该 episode 的持久单调递增整数 |
| `address, network` | 原样完整地址及规则识别的网络；长度分别最多 128/40 UTF-16 单位；实时跨群提醒不允许 unknown |
| `groups, groupCount` | 不重复的群名数组及长度，最多 50 群、每项 200 UTF-16 单位；不可悄悄裁群来改统计 |
| `mentionCount, uniqueStatementCount, duplicateCount` | 非负安全整数，mentionCount = uniqueStatementCount + duplicateCount；同一本地事件只计一次 |
| `firstSeenAt, lastSeenAt, triggeredAt, evaluatedAt, expiresAt` | UTC ISO 时间；前两者描述本窗口所统计提及，triggeredAt 为首次达到条件的检测时间，evaluatedAt 为本版计算时间，expiresAt 是跨群条件预计失效时间 |
| `windowSeconds, thresholdGroups` | 首版固定 3600 与 2；改变参数需要调整规则版本及两端测试，不静默混用计数口径 |
| `status` | active 或 expired；关闭事件沿用最后有效快照的群、计数、firstSeenAt/lastSeenAt/expiresAt，更新 evaluatedAt 和状态；网站注明这些是最后有效快照，不把它们当作关闭时的当前窗口计数 |
| `notificationVersion` | 非负安全整数且不超过 revision；首次触发且通过冷却时设为 1，其余同 episode 更新保持不变；冷却抑制或 catchup 卡片为 0，避免快速更新覆盖首次提醒信号 |
| `catchup` | 布尔值，表示本 episode 首次形成于重启/积压追赶阶段；该 episode 中保持不变，网页不对其发出实时新提醒 |

CA payload 不含消息内容、成员列表、源库路径、AI 摘要或原始事件 ID。网站只将其作为规则检测结果；不能为了丰富卡片额外调用 AI 或行情服务。

接收成功与 v1 报告一样回显 id/revision/disposition；相同版本相同字节幂等，不同内容冲突隔离。不同 type 的对象不得共用无类型存储键。Signal 接收后自行判断 expiresAt 是否已过期，服务端 syncedAt 不覆盖原时间。

新增登录后读取入口：`GET /api/wecom/ca-alerts?limit=10&before=...`，响应 `{items, nextCursor, status}`，按 `(triggeredAt DESC, id DESC)` 稳定分页；另外 `GET /api/wecom/ca-alerts?active=1&limit=50` 返回当前有效卡片并附 `{total, truncated}`，在可见页面每 15 秒刷新。超过 50 条需显示还有更多，不伪称全量。所有查询值严格校验，匿名读取拒绝。

浏览器用 `(id, notificationVersion)` 去重站内提示；首次打开只展示已有卡片，不批量弹历史提醒。后续轮询只提示 notificationVersion>0、catchup=false、未过期、且从 triggeredAt 至首次接收未超过 60 秒的事件；晚到记录仍保留列表。服务器持久保存首次接收时间，不能用后续 revision 的接收时间重算为新事件。服务器与页面均不得靠 AI 在线与否推断 CA 通道在线。

## 6. 可靠性、安全和运行边界

沿用 Signal v1 的 HMAC 六行格式、原始 body 字节签名、禁止重定向、10 秒超时、300 秒时差、持久 nonce 去重、严格确认后出队、错误分类和固定错误码；不复制或修改其认证方案。v1 的公开签名样例只能做离线基础算法校验，v2 各类型需另配合成样例。

- 私密配置建议保留 v1 路径；同步数据库置于单独 `signalhub-sync/` 子目录。目录 0700、文件 0600，验证所有权并拒绝符号链接；不复用 LAN 密码或 MiniMax Key。
- 禁止日志记录请求正文、身份信息、签名头、密钥和原始异常。检测疑似凭证时持久隔离并报固定错误码，不允许普通名单授权绕过密钥保护。
- 共用一个发送器，一次一个请求。新鲜 CA 优先，但最多连续发 3 个 CA 后给一个已到期报告机会；心跳每 60 秒按期调度。旧的延迟 CA 不压过新鲜 CA，全局限流和认证暂停对所有通道生效。
- 报告每 60 秒最多发现 10 份，串行准备导出；导出计算不占用 CA 定时循环或发送器。实时每轮最多 500 行，处理预算 2 秒，先到任一限制就保存真实进度，下轮继续；滚动校验也每批最多 500 行。积压超过 60 秒显示延迟，不能丢弃未处理记录后伪称实时。
- 待确认及隔离 payload 合计最多 1000 条或 128 MiB；达到任一上限暂停继续读取并报警，不能删除未确认数据腾空间。派生滚动索引另外限额 32 MiB，过期索引可清理，但已形成的发送 payload 必须保留到持久确认。索引达到上限且清理不能释放时暂停 CA 通道、报告缺口。
- 源库只读打开；源库忙时重试，损坏记录留下持久失败标记及可重试定位信息，不把它静默算作完成。坏 payload 不无限堵住后续合法项。
- 数据库回退/替换检查同时覆盖结果水位与消息水位：记录文件身份、结果水位的 job_id/结果摘要与最大编号；消息库结合 sqlite_sequence、记录版本和别名解释合法删行，剩余无法解释的不一致暂停对应通道并人工审阅。现有源库没有持久数据库 UUID，这些检测不能保证发现所有保留相同锚点的备份恢复；已知恢复/替换必须停用同步并人工建立新 storeId。worker 重启会变化的 instance_id/lease_generation 不是数据库代际标识。
- 独立 LaunchAgent 默认不安装、不启用；停止它只停止同步。监听/worker 状态取既有真实心跳：参考 MessageRepository.bootstrap 的 5 秒 listener 活跃判定和 AnalysisRepository.diagnostics 的 15 秒 worker 判定，只读对应状态，不导出整个诊断对象。未知则 unknown，不能用 HTTP 成功充当在线证据。
- v2 heartbeat 保留 v1 status，并新增 `caDetector, pendingAlerts, lastMessageObservedAt, lastCaEvaluatedAt`：检测器状态为 online/offline/unknown，数量为安全整数，时间为 UTC 或 null。pendingReports 仍仅统计报告；网页明确区分监听、AI、CA 检测器、网络状态。

## 7. 首次启用与分工

默认只接续启用后新数据：在私密本机配置完毕、用户确认启用时，记录当前成功结果最大 analysis_id 和当前消息水位。总结仅导出之后成功落库的结果；CA 窗口从该消息水位之后开始积累，不扫描启用前一小时，也不自动同步首屏旧报告。

暂停后恢复使用原有游标和队列，不重设首次水位。发送断网期间已经检测并入队的事件照常补传，按过期/延迟规则展示；程序停机期间没有检测到的过期窗口不回溯制造提醒，按上面的 catchup/漏检规则处理。不能假装恢复瞬间就是历史事件触发时间。源库丢失导致无法恢复时明确报告缺口，不补跑 AI。

Mac 计划新增小型独立模块：只读导出与白名单映射、CA 增量状态、独立队列、签名发送与调度入口。优先复用纯函数，不把网络逻辑塞回现有 listener、analysis_worker 或 GET/HEAD-only LAN 服务。Signal 负责接收持久化、登录保护、v2 渲染、CA 快速读取、部署与缓存。

推进门槛：

1. 用户已审阅确认本文，尤其新增 CA 的 1 小时／2 群／约 1 分钟目标与未知链限制；无需重复询问这些产品参数。
2. Signal 回传更新后的接口文档提交，确认 v2 briefing、来源元数据、ca_alert、heartbeat 和快刷新接口；原 55dfa50 不足以实现全部新要求。
3. 两端分别实现并使用合成数据测试，Mac 默认只 dry-run，不访问生产写入端点。
4. Signal 提供已部署 commit、签名接口就绪及匿名读写被拒绝的证据。
5. 用户在私密配置中设置专用凭证，确认首次截止点、启用同步；核对一次真实报告和 CA 到达后才称为上线。

本稿不要求 Mac 直接修改 Signal 仓库，也不授权推送真实消息或向公开 Git 提交运行配置。

## 8. 验收清单

- 总结：六栏/业务四类无损、昵称与观点归属保留、历史快照口径及完整 CA 不变；来源只含元数据、无聊天正文；缺失记录不伪装完整。
- 协议：v1 不误收 v2；未知字段、版本、无效 Unicode、超限请求和疑似凭证被拒绝；公开签名向量与新增 v2 合成样例在 Python/Node 一致。
- CA 规则：窗口边界、两个不同群、同群刷屏、搬运重复、同名不同链、未知 EVM 链隔离、地址大小写展示、乱序消息、窗口关闭和冷却均用假时钟验证。
- CA 时效：Mac 10 秒读取 + 单请求发送 + 页面 15 秒刷新，在正常负载下测量采集至显示目标；记录峰值、积压和失败场景，不能只测 HTTP 返回 200。
- 可靠性：超过 30 份报告、CA 高频更新、确认丢失、重启、源库暂不可读、源库回退、坏行、队列/索引达限、429/401/503 均不丢未确认数据，不绕过退避。
- 页面：登录保护、完整报告、站内提醒去重、首次进入不刷历史弹窗、过期/迟到显示、后台暂停刷新和断网保留上次结果；不申请 Web Push 权限。
- 运行：不触碰原 schema、relay 边界、监听权限、AI 周期和凭证；无付费补跑；独立启动/关闭可回滚，关闭同步后原 Mac 工作台仍可用。
- 发布状态分别报告“代码完成”“合成联调通过”“真实同步启用”，不合并为一句“已接入”。

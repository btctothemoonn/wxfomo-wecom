# LAN 只读工作台最终复审 round 5 修复报告

日期：2026-09-03

分支：`codex/wecom-notification-probe`

round 5 基线：`582ce72133d2a0a14f75a084b5253ad8c25fb775`

原始交付基线：`8674202325a7f65ffd5801d14ec8301a1842ad31`

复审输入：round 5 的 2 项 OPEN Important，以及随后 scaling / migration atomicity 独立审计。

## 结论

round 5 的两项 OPEN Important 与独立审计追加的两个 P1、一个跨启动全局 alias-owner P1 均已按 RED → 根因 → 最小生产修复 → GREEN 关闭。最终独立只读复审结论为 APPROVED，无剩余 P0/P1/P2。

前四轮已批准的边界没有放宽：Notification source identity/inode 校验、写成功后 checkpoint、source-bound UUID-less ID、canonical event/alias exact lookup、字段 projector、公开 host allowlist、私有 token、Bearer auth、非 GET/HEAD `405`、opaque cursor、全请求有限 timeout、heartbeat TTL/visibility invalidation、static exact allowlist/hardlink 隔离、launcher authenticated readiness 与原生 no-store update guard 全部保留。

## 逐项 resolution 与 TDD 证据

| 项目 | RED / 根因 | 最小修复 | GREEN 证据 |
|---|---|---|---|
| Important 1：Diagnostics primary TypeError/timeout 首载不得显示业务空态 | app-level harness 令 primary `/api/diagnostics` 分别抛原生 `TypeError` 或永不 resolve。在首载没有 previous payload 时，旧 fallback 只有 `available:true`，没有 `messagesDependency`，因此 UI 把未知误画成“最近消息：尚无记录”。timeout 分支还需证明无 `AbortController` 时仍有限结束。 | 新增 `diagnosticsPrimaryFailurePayload(previous, reason)`：首载仍使用可渲染 diagnostics DTO，但显式写入 `{messagesDependency:{available:false,reason}}`；网络与 timeout 分别保留 exact reason。已有 primary state 时保留其 sources/listener/activity/历史消息，只覆盖当前 dependency failure。primary TypeError 与 timeout 统一进入既有 2/4/8/16/30 秒有界 retry；401 代际所有权不变。renderer 对 network/timeout 显示 dependency 文案，不再走“尚无记录/后台尚未生成”。 | 新 Node app tests 覆盖 TypeError 与 never-resolving timeout 的首载、成功 retry、已有 primary 后再次失败、无 `AbortController`、bounded backoff。fresh frontend PASS。隔离浏览器真实关闭 primary diagnostics HTTP 连接：3 处“网络连接失败”、1 处“数据源暂不可读”，`尚无记录=0`、`后台尚未生成=0`、console warning/error=0。 |
| Important 2：已经执行 marker301 的 store 必须有独立 prefix alias 升级链 | 真实 pre-canonical TEXT/BLOB store 先由旧 listener 生成，再由 intermediate `baa877b` 执行 marker301；未修复 HEAD 因旧 migration version 已存在而跳过，首个 RED 为 `blob intermediate store did not run independent prefix upgrade`。旧 scanner 只识别仍为 6-part legacy `event_id` 的 row，canonical survivor 不再是 candidate。 | 新增独立 marker `2026090302`。只有 marker301 完成后，scanner 才从 canonical message 与其保留的、可解析的 standalone alias 重建 `(messageID, recordID, raw UUID storage bytes, canonical ID, group/sender/content)` provenance；再从真实 source 以 recordID、TEXT/BLOB storage bytes、stable UUID 与 canonical ID 复核，才增加 alias。marker301 pending、UUID-less、歧义 fingerprint、错误 storage class 或 exact collision 全部 fail closed。 | 真实 `c0c20ed^` listener → `baa877b` intermediate → HEAD，TEXT/BLOB 均从 marker301 升至 marker302；messages=1、conversation count 一致，历史 A 与当前 B 的 standalone/native aliases 均由 production repository exact lookup 到同一 canonical survivor；重跑幂等。历史-only collision 保持 marker302 pending 且不抢 exact precedence。 |
| 旧 native prefix 的真实合法集合 | round 4 按 review 文本枚举 8 个冒号/空格 body，但 HEAD fixture 直接调用当前 helper，未证明 pre-c0 `event(from:)`/policy 实际接受。真实旧 policy RED 证明 ASCII colon 后无空格的两种 layout 无 event；把它们当 alias 会制造错误绑定。 | 测试 materialize 并编译真实 `c0c20ed^` `NotificationMapper`、`WeComNotificationPolicy`、`StableHash` 作为 oracle。生产 helper 对每个有限 raw layout 再走旧 decoder clean 与旧 policy projector，只保留语义仍精确等于已保存 group/sender/content 的 ID；unknown raw 与历史 attachment 不猜测。 | 8 个 body 全部由旧 oracle 实测：6 个合法、2 个 ASCII colon 无 post-space 非法；合法 prefix 为 `6×5=30` 个 ID，另有 2 个 direct ID，总计 32。long sender 与 embedded-colon sender 只保留 2 direct；whitespace-heavy sender 先按旧 decoder clean 后得到 30 prefix。无效 raw hashes 不阻塞 marker302，也不写 alias。 |
| scaling P1：marker302 不得 O(C²) | 原启动路径对每个 recordID 全量 `filter` candidates；pending migration 每次启动会重复。新增 4/8 个真实候选 fixture 后，旧实现没有可审计的线性工作量契约。 | 先以 `(recordID, uuidStorageBytesHex)` 建立 candidate dictionary；每个 source row 一次 lookup、每个匹配 candidate 一次 planning，不再逐 row 扫全表。仅测试环境输出 work counter。 | 真实旧 listener/intermediate 生成 4 与 8 个候选，HEAD 分别报告 8 与 16 个 work units，marker302 完成、message/count 不漂移。fresh full listener 中再次通过。 |
| 配置漂移 P1：历史群移出当前配置后不得永久 pending | intermediate store 保有历史 group A，但当前配置已无 A；旧实现把全局 config 的 `decodeMessage` 成功作为历史 alias 迁移前提，持续警告并永不写 marker。 | 已由 standalone alias + source UUID/storage/canonical 验证的历史 aliases 无条件规划；只用 `candidate.group` 尝试 decode 当前 revision，成功才追加当前 source aliases。全局显示配置不再抹除历史 provenance。 | 真实 A 历史 store、source 更新 B、配置仅保留另一群：完整 32 个 A + 32 个 B aliases 均存在，marker302 完成、无业务消息输出、conversation count 一致。 |
| 全局 owner preflight / 跨启动 P1 | 第一版只对本轮 source 可取到的 `aliasPlans` 子集预检并逐 candidate 提交：B source 暂缺时 A 可先占 alias x；B 后续恢复并证明同样拥有 x 时虽然 A/B 都被标歧义，已落库的 x 无法撤销。原 pure helper test 在 options 前退出，不能覆盖 production glue。 | source planning 必须先完成；只有 `plannedOwnerIDs == expectedMessageIDs` 且 `unresolved` 为空，才允许任何 marker302 alias 写入。之后对完整 owner set 做跨 candidate alias-owner preflight；共享 alias 的所有 owner 均跳过，marker pending。 | 新 integration 由真实旧 listener 生成两个独立 store owner、真实 intermediate 完成 marker301，再用真实旧 native oracle 构造未转义 field delimiter 导致的共享 compatibility alias。第一次启动移除 B source：无 alias 写入、marker pending；第二次恢复 B：两 owner 均不绑定共享 alias、marker仍 pending。显式临时移除 complete-owner gate 时 RED 为 `incomplete owner set wrote an alias before global preflight`；恢复最小 gate 后 GREEN。 |

## migration 原子性判断

marker302 现在有两层原子边界：

1. 完整 owner set 未完成 source planning 或仍有 unresolved 时，本轮零写入；因此不会再发生“未来恢复的 owner 才揭示冲突”而旧 alias 已被部分绑定。
2. 完整 owner set 已知后，跨 owner 共享 alias 在第一次写入前统一 fail closed。其余互不相交 candidate 仍沿既有契约逐项 `BEGIN IMMEDIATE`，在事务内重新验证 source/canonical/standalone/exact ownership，再幂等插入。

若完整 owner 集中某一 candidate 与既有 unrelated exact row 冲突，其他互不相交 candidate 可以取得可恢复的部分进度；marker 保持 pending，后续启动会幂等重验。这不是所有 owner 的单事务提交，但不会造成未知 owner 抢占：全 owner 集及其待写 aliases 已在首写前完整预检。该选择保留既有长迁移的 bounded retry 与 crash recovery 契约，同时关闭了审计指出的跨启动错误归属。

## 系统化调试与审计补充

- 第一个 collision fixture 把共享 ID 同时做成 source 当前 raw native ID，导致 normal `persist()` 也会写它，不能单独证明 marker302 gate。最终 fixture 改为 source 实际使用 A-normal/B-reversed，而共享 ID 只来自 compatibility 集的 A-reversed/B-normal；测试先断言共享 ID 既非 canonical/standalone，也非两个 current raw ID，再执行两次真实启动。
- 审计一度提出“current attachment alias 未加入 marker302 plan”。沿完整 runtime 路径复核后撤回：只要 source update timestamp 前进，marker 后正常 polling 的 `persist()` 会按 canonical 找 survivor，并以含真实 attachment URL 的 `notification.legacyNativeEventID` 后补 raw alias；如果 cursor 已越过该 revision，则此前 persist 已完成同一动作。只有 payload 改变但所有 source timestamps 不前进的人造状态会缺失，不属于 source 契约。历史任意 attachment 仍是不可反演的信息边界。
- 最终独立复审逐行确认：线性 source dictionary、完整 owner gate、全计划 owner preflight、事务内 source/canonical/standalone/exact revalidation、marker 条件与真实两启动 integration 均成立；结论 APPROVED，无 P0/P1/P2。

## fresh 验证

工具链：macOS 13.7.8；Apple Swift 5.2.4；Python 3.7.3；Node 14.18.0；zsh 5.9。

| 范围 | 命令 / 结果 |
|---|---|
| diff / syntax | `git diff --check 582ce72133d2a0a14f75a084b5253ad8c25fb775..HEAD` → exit 0；两个 listener/mapper test shell `zsh -n` → exit 0。 |
| standalone listener full | `zsh scripts/test-wecom-group-listener.sh` → 44 个场景全部 PASS，exit 0；在最终 complete-owner gate 后从头重跑。 |
| listener/native oracle focused | 新跨启动 owner set、real intermediate TEXT/BLOB、历史 exact collision、旧 decoder/policy sender edge cases、config drift、4/8 linear work、invalid prefix hashes 全部独立 GREEN；`zsh scripts/test-wecom-notification-mapper.sh` → PASS。 |
| Python full | `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest scripts.test_wxfomo_lan_server` → `Ran 82 tests in 44.040s`，OK。 |
| static security focused | notification DB at allowlisted path、allowlisted sensitive hardlink、CLI static-root overlap、sensitive hardlink 共 4 tests → `Ran 4 tests in 5.108s`，OK。 |
| native full relevant | `test-message-event-consumer.sh`、notification policy/mapper/payload-decoder/probe 共 5 个脚本全部 PASS；probe 15 个场景 PASS。 |
| Swift 5.2 | listener 与 notification probe production scripts `swiftc -swift-version 5 -typecheck ...` → exit 0。 |
| frontend | `node scripts/test-wxfomo-lan-frontend.mjs` → `PASS: wxFomo LAN frontend state`；production/test 6 个 `.mjs` 均 `node --check` exit 0。 |
| launcher | readiness `all` 的 foreign-PID/missing-index 两项 PASS；`PYTHONDONTWRITEBYTECODE=1 zsh scripts/test-wxfomo-lan-launcher.sh` → `PASS: wxFomo LAN launcher supervision`。 |
| 浏览器 | 独立 upstream `127.0.0.1:55026` + fault proxy `127.0.0.1:55164`，合成 DB/token/config；primary diagnostics 真实断连接时显示 network dependency/retry，不显示两类业务空态，console problems=0。tab、两个 server、端口与 fixture 已精确清理。 |
| artifacts/process | repo 内无临时 DB/token/log/pycache；所有遗留 `wxfomo-wecom-listener-test.*` 目录先逐一确认无 open file，再按精确路径删除。只读 `ps` 确认真实 launcher PID 71119、listener PID 71128、server PID 48470 仍在；未向其发送信号或修改其文件。 |

## 本 round 5 提交

- `2c4607b` `fix: represent primary diagnostics failures`
- `1f6952f` `fix: render diagnostics transport failures`
- `8a48739` `fix: complete legacy prefix alias upgrades`
- `3dabe19` `fix: preflight complete legacy alias owner sets`
- 本报告由后续 documentation commit 纳入。

round 5 增量范围为 `582ce72133d2a0a14f75a084b5253ad8c25fb775..` 本报告提交；完整交付范围为 `8674202325a7f65ffd5801d14ec8301a1842ad31..` 本报告提交。

## 测试过程偏差与清理

早期给 pure alias-owner helper 制造 RED 时，测试命令在 helper 尚不存在的版本上遗漏了显式 `--database/--config`，因此一个隔离 listener 进程错误打开了默认 Notification Center source 约 30 秒。该命令使用临时 message store、没有 `--include-existing`；未观察到消息输出，没有重放或发送企业微信通知。发现后只终止该测试自己的 PID 9336/9344，并立即把测试改为显式临时 source/config/store。真实 session 9829、PID 71119/71128/48470 及其子进程未被停止、写入或发信号。残留临时 store 与其余已中断测试目录在最终审计中逐一确认无进程/open file 后删除。

## 剩余疑虑与环境限制

- 无已知 unresolved 生产缺陷。
- 已批准的信息论边界保持不变：pre-c0 store 没有保存任意未归一化 raw title/subtitle/body 或历史 attachment，不能安全反演未知 native hash；本轮只恢复真实旧 policy 对已保存规范字段可有限验证的 layouts，不猜测 unknown raw/attachment。
- 完整 `swift run WxFomoSelfTest` 仍受宿主限制：package tools version 5.10，而本机为 Swift 5.2.4 且 Command Line Tools 没有 `xctest`。这不是 assertion failure；本机可执行范围已用 Swift 5.2 production typecheck、native source harness 与相关脚本全量覆盖。

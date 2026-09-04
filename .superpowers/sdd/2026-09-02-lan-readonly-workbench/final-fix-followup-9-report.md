# LAN 只读工作台最终复审 round 9 修复报告

日期：2026-09-04

分支：`codex/wecom-notification-probe`

round 9 基线：`8ad5bca2e8ed6b5a9e2fbe53ccfadb4e84802cfa`

原始交付基线：`8674202325a7f65ffd5801d14ec8301a1842ad31`

代码提交：`a031944de6e370bd74c42a38928c0203e2e5cc94` (`fix: harden legacy migration recovery`)

## 结论

round 9 的 3 个 Important 均成立并已按 TDD 关闭。

当前 301 恢复不再把今天的 watch-list 当作历史 owner 的唯一语义来源；正常持久化遇到已隔离、后来又成为当前 raw ID 的 derived alias 时，会保留隔离并提交 canonical row/checkpoint；301 的完整 message×alias 扫描现在受同一个 `--once` deadline 约束，超时只会留下事务前状态，移除测试慢钩子后二启可收敛。

前八轮的 canonical/exact-first、source identity、UUID storage class、完整 owner/global preflight、quarantine deny-set、prefix policy、checkpoint-after-write、field projector、heartbeat、认证、HTTP method/cursor/timeout、static allowlist/no-follow 与 launcher readiness 边界没有放宽。

## TDD：RED、根因与最小修复

| 项目 | RED / 根因 | 最小修复与 GREEN 契约 |
|---|---|---|
| Important 1：65f 半状态恢复遇到历史群配置漂移 | 真实 fixture 先用仓库 `c0c20ed^` listener 写 A/B，再用真实 `65f495d` 留下 A 已 canonical+303、B 未转换、301 缺失、共享兼容 alias 错指 A 的半状态；升级时配置只保留 B。旧实现只用当前 groups 解码各 source row，A owner 无法进入计划，RED 为 `FAIL: historical A/B groups removed from config prevented complete partial recovery`，并警告 2 条历史通知保持 pending。 | 仍先按当前配置解码，只有当前 watch policy 无法解码时，才把同一 source bucket 中所有历史 candidate 自带的 exact group 集合一次性交给既有 decoder。历史 groups 只用于 migration verification，不加入 runtime subscriptions；decoder 的多匹配保护仍 fail-closed。最终必须由 plans 完整覆盖 `expectedMessageIDs`，才进入既有单一 `BEGIN IMMEDIATE` consolidation。GREEN：配置仅保留 B 时，A/B 全部经 source record+UUID storage+canonical 验证，301=1、305=2、306=1、shared alias quarantine 完整，messages/conversation counts 不变，也没有输出 B 当前消息。 |
| Important 2：quarantine alias 后来成为合法 current raw ID | 在上述真实 65f fixture 成功恢复后，把 source record 72 更新为 B 的正常 title/subtitle 布局；该布局的真实 old native ID 正好等于 quarantined shared alias。旧 `persist` 调统一 `insertAlias` 时抛永久 storage error，RED 为 `FAIL: future raw alias prevented normal persistence: ... 拒绝重新绑定已隔离的历史兼容 ID`，cursor 未前进并会在重启后重复处理。 | canonical `notification.eventID` 仍先 exact-first resolve/insert；只在正常 ingestion 的 derived alias materialization 循环中查询 quarantine 并跳过该 alias，其他 aliases 与 checkpoint 仍在同一事务提交。全局 `insertAlias` 的 quarantine 拒绝保持不变，所以 301、prefix upgrade 及其它迁移写入口不能重新绑定隔离 ID。GREEN：cursor 精确到 `(900,72)`，B 的 message id/canonical event 不变，alias 总数只增加未隔离的 legacy LAN alias，shared alias 仍无 active mapping，quarantine/301/302/304/305/306 不变，二启不重试也不重复 alias。 |
| Important 3：完整恢复扫描未受 `--once` deadline 约束 | 新 fixture 用真实 pre-canonical listener 建 owner，再加入 32 条 retained aliases；编译 production listener 后用确定性 per-row slow hook 和 `--once --timeout 0.2`。旧实现越过 deadline 并提交 marker，RED 为 `FAIL: expired legacy alias scan committed partial migration state`。 | `bindSource` 把 once deadline/timeout 传入 301 scanner；scanner 在入口、每次 SQLite row step、message/alias/candidate/provisional-row 循环、marker 前检查 deadline，并为不可在 Swift 行间协作的 SQLite VM 安装 progress handler。handler 在 statement finalize 后注销并释放 context；`bindSource` 还在 source-key update 与 COMMIT 前复查。任何 timeout 经外层事务 rollback。为保持线性，seed 改为 reference storage 避免 Dictionary value-copy/Array COW，SQL 只按 message id 排序，provisional replay 对同 record 多 storage identity 保持 pending，删除 U×I 展开。GREEN：0.2 秒 fixture 在 1.5 秒上限内返回 timeout，301/305/306/quarantine/source-key/message/aliases 全部保持事务前值；无慢钩子二启完成 canonical+301+305。 |

## 跨层与事务证据

- 配置漂移 fallback 的候选来自已经由 `(recordID, uuidStorageBytesHex)` 绑定的同一通知历史 revisions；它不扩大监听群集合。当前配置能解码时仍优先使用当前语义，避免历史 group 恰好等于当前 sender 时产生永久 false-pending。
- 301 的 expected owner universe 仍同时包含旧 standalone row、old303 canonical survivor 和可能的 safety-replay canonical duplicate。无法证明 source identity、canonical hash、UUID storage class、完整 owner 覆盖或 alias ownership 时不写 301/305/306，也不 quarantine。
- quarantine 只改变 alias fallback；`messages.event_id` exact lookup 永远先查，且正常持久化不会删除/重写 quarantine。迁移和 prefix 的统一 alias 写入口继续对 quarantine 抛错或整批 pending。
- deadline context 的生命周期为 retained context → registered progress handler → statement finalize → unregister → release；异常由 `bindSource` 的 catch 回滚。deadline 后不会留下 source binding、marker、provenance 或 quarantine 的部分状态。
- 线性边界为扫描结果行数加 candidate/alias 数量。retained alias append 原位完成；不再按每个 alias 复制 seed 数组，也不再把一个 replay row 与同 record 的多个 UUID identities 做笛卡尔展开。

## 独立只读审查

两名独立 reviewer 在冻结 diff 上分别审查 migration/deadline 与 quarantine/persist。

- migration reviewer 复跑真实 `c0c20ed^ → 65f495d partial → HEAD` 综合 fixture和 scan-deadline fixture，并完成 Swift 5 typecheck、shell syntax 与 diff 检查；确认 source-bound historical fallback、完整 expected-owner gate、progress-handler 生命周期、rollback 和线性化均无 P1/P2。
- 审查中专门评估了“总是把 current+historical groups 合并解码”的替代方案。该方案会把同一通知的合法历史 group revision 当成当前 sender 的第二匹配并永久 false-pending，因此没有采纳；当前配置优先、失败后一次性历史 fallback 才符合现有 watch-policy 契约。
- quarantine reviewer确认 skip 只位于正常 `persist` derived-alias 循环，exact canonical、checkpoint、其它 alias 仍在同一事务；全局 `insertAlias`、prefix/consolidation protected-ID checks 与 Python/Swift quarantine anti-join 均未放宽。其独立 focused fixture通过，未发现 P1/P2。

## fresh 验证

工具链：macOS 13.7.8；Apple Swift 5.2.4；Python 3.7.3；Node 14.18.0；zsh 5.9。

| 范围 | 命令 / 结果 |
|---|---|
| Round9 focused | `WXFOMO_TEST_FILTER=test_recovers_real_65f_partial_version1_collision_atomically scripts/test-wecom-group-listener.sh` → PASS；`WXFOMO_TEST_FILTER=test_interrupts_the_full_legacy_alias_scan_at_the_once_deadline ...` → PASS。两条均在最终线性化 diff 上重跑。 |
| standalone listener full | 冻结 production/test 后从头 `env -u WXFOMO_TEST_FILTER scripts/test-wecom-group-listener.sh`：55 个场景全部 PASS，最后 `PASS: rejects unsafe config and store paths without mutation`，exit 0。 |
| diff / syntax / Swift 5 | `git diff --check`、8 个相关 shell scripts 的 `zsh -n`、所有 `scripts/*.mjs` 的 `node --check` 均 exit 0；listener 直接 compile 及 listener/probe 的 `swiftc -swift-version 5 -typecheck ... -lsqlite3` 均 exit 0。 |
| native relevant | `test-message-event-consumer.sh`、notification policy、mapper、payload decoder、probe 共 5 组脚本全部 PASS；probe 的 source replacement、低 record ID、lock、Team ID 和 privacy 场景均通过。 |
| Python full | `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest scripts.test_wxfomo_lan_server` → `Ran 84 tests in 44.863s`，OK。 |
| static security focused | notification DB/static overlap、allowlisted sensitive hardlink、CLI static-root overlap、sensitive hardlink四项 → `Ran 4 tests in 5.103s`，OK。 |
| frontend | `node scripts/test-wxfomo-lan-frontend.mjs` → `PASS: wxFomo LAN frontend state`；全部 `.mjs` syntax exit 0。 |
| launcher | readiness foreign-PID 与 missing-index 两场景 PASS；在 Swift-heavy tests 全部结束后单独 `PYTHONDONTWRITEBYTECODE=1 zsh scripts/test-wxfomo-lan-launcher.sh` → `PASS: wxFomo LAN launcher supervision`，exit 0。 |
| browser | Round9 未改 web/server/HTTP surface，因此没有重复上一轮已通过的真实浏览器 fixture；fresh frontend、Python 84 项、static HTTP security 与 launcher authenticated readiness 已覆盖所有可能受启动链影响的接口。 |

## 清理、隔离与剩余边界

- 所有 Notification source/store/config/token/port 都来自测试脚本的隔离临时目录；未读取、发送、重放或伪造真实企业微信通知。
- 未向真实 session 9829 或 PID 71119/71128/48470 发送信号或写入其文件。最终只读 `ps` 确认三者仍存活；没有 Round9 listener/launcher fixture 进程残留。
- 独立审查产生的 3 个 Python 3.7 bytecode 文件经逐文件 `file` 与 open-file 检查后精确删除，再移除空 `scripts/wxfomo_lan/__pycache__`；repo 内没有新增 DB、token、log 或 pycache artifact。
- 无已知 unresolved production defect。测试慢钩子确定性覆盖 cooperative row deadline 与整个 bind transaction rollback；没有单独强制 SQLite progress callback 返回 `SQLITE_INTERRUPT`，但其注册/注销、deadline 映射与 rollback 已由 Swift 5 编译和独立静态审查确认。
- 完整 SwiftPM self-test 仍受宿主工具链限制：package tools version 5.10，而本机 Swift 为 5.2.4 且 Command Line Tools 缺 `xctest`。受影响 production Swift 路径已由直接 Swift 5 compile/typecheck、listener full 与 native scripts 实际覆盖。

本报告由后续 documentation commit 纳入；round 9 增量范围为 `8ad5bca2e8ed6b5a9e2fbe53ccfadb4e84802cfa..`本报告提交。

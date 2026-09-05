# LAN 只读工作台最终复审 round 6 修复报告

日期：2026-09-03

分支：`codex/wecom-notification-probe`

round 6 基线：`1c5dbff21f4f211dab5db612483f0290b1fbff57`

原始交付基线：`8674202325a7f65ffd5801d14ec8301a1842ad31`

## 结论

round 6 的 1 项 Important 成立：marker 301 的早期 producer 会把多个 standalone revision 折叠为一个 canonical survivor，但 marker 302 scanner 把 survivor 当前的 `group/sender/content` 误用于所有历史 fingerprint。这会漏掉 A/B 的合法 native prefix aliases 及其跨 owner collision preflight，却仍写 marker 302。

本轮已按真实旧版 fixture 完成 RED → 根因 → 最小安全修复 → GREEN。新 listener 不从 opaque hash 猜测已丢失的 revision 语义：只有与当前 consolidation 同事务写入的 per-survivor provenance 才能放行多 revision；旧库无法证明时保持 pending。独立只读复审结论为无新 findings，可通过本轮 provenance 审计。

## TDD 与根因证据

| 阶段 | 真实 fixture / RED | 根因与最小修复 | GREEN 契约 |
|---|---|---|---|
| 多 revision 折叠 | 真实 `c0c20ed^` listener 先持久化同 recordID/UUID 的 A、B 两行；source 先更新为 C，再运行真实 `baa877b` 完成 301。fixture 证明 survivor=C、A/B/C 三个 6-part fingerprints 仍在、A/B 各至少一个合法 full-layout alias 缺失，并为缺失 A alias 建立 unrelated exact owner。未修复 HEAD RED：`FAIL: folded A/B provenance was discarded behind marker 302`。 | 302 只从 alias 恢复 `(recordID, UUID storage bytes)`，却把 survivor C 的语义复制给 A/B。新增 `message_legacy_alias_provenance`；当前 301 consolidation 在所有 revision 完整 alias exact preflight/验证成功后，与 survivor 更新及 alias 写入同事务记录 per-message version 303。旧 producer 不会被 global marker 误认证。 | `baa877b` 折叠 A/B→C 无 303，302/304 均 pending，警告可见；A exact owner 不变，B 和当时缺失的 C alias 都不部分写入，message/conversation count 一致。 |
| 新 HEAD 正向多 revision | 初版仅以 fingerprint count 一刀切 fail-closed，使新 HEAD 自己完整处理 A/B→C 后也无法完成 302。新增正向契约 RED：`FAIL: blob complete multi-revision provenance was not recorded`。 | 不使用全局 provenance marker：旧 build 可部分折叠 owner A 后在 owner B 失败，之后全局 marker 会误放 A。改为与每个 survivor consolidation 同事务的 303 row。 | 当前 HEAD 直接迁移 TEXT/BLOB A/B→C：303/301/302/304 均完成；A/B/C 各 32 个真实旧 policy 合法 aliases 全部 exact resolve 到同一 survivor，count 为 1。 |
| 旧 301 单 fingerprint | 单 fingerprint 本身不足以证明 survivor tuple 由哪个 producer 保存。真实 `c0c20ed^ → 8089608/301 → HEAD` RED：`FAIL: prefix upgrade trusted marker 301 without a complete semantic witness`。 | `baa877b` 及后续 301 producer 会在一次 consolidation 为每个 tuple 固定写入 12 个旧 helper IDs（direct 2 + 两种 prefix body × 5 种 title/subtitle layout）。旧库只在 distinct standalone count=1 且这 12 个 ID 全部已绑定同 owner 时才可计划；`8089608` 无 witness 则 pending。 | 真实 `baa877b` 单 revision TEXT/BLOB 仍可升级历史 A+当前 B 的全 32 aliases；真实 `8089608` store 保持 pending。 |
| 旧 round-5 302 证据污染 | 真实 `c0c20ed^ → 8089608/301` 保持一个 fingerprint 且无 12-ID witness；再运行真实 `1c5dbff` 会事后补齐 full 32 aliases 并写旧 302。如果仍把“现在存在的 12 IDs”当作 301 witness，RED 为 `FAIL: missing output: 旧原生前缀 ID 升级，迁移保持待完成`。 | 新增 superseding audit marker 304。旧 302 不再是最终可信完成证据；启动时已有 302 但 survivor 无 transaction-bound 303 时一律 pending，防止把 302 自己制造的 aliases 倒签为 301 provenance。302 和 304 只在完整审计后同事务写入。 | single fingerprint 在真实 round-5 后仍为 1，旧 302 存在；HEAD 保持 304 pending 并输出警告，不改变 alias owner/cardinality。多 revision 的旧 round-5 302 也由同一 304 gate 重审，不再永久跳过。 |

## 跨 owner、原子性与复杂度

- scanner 仍以 `(recordID, uuidStorageBytesHex)` 预分组 source candidates；本轮每个 retained alias 只扫描一次，303 查询通过 message primary key，12-ID witness 为常数工作，整体仍为线性量级。现有 4/8 candidate 工作量 fixture 在 full listener 再次通过。
- 只要任一 owner 的 provenance 未解析，`unresolvedMessageIDs` 非空，生产 glue 不执行任何 prefix alias 写入。完整 owner 集合规划后仍先做跨 owner ambiguous-alias preflight，再在每个写事务内重验 source/canonical/standalone/exact owner。
- 303 与 survivor/aliases 在同事务；302 与 304 在同事务。crash 只能留下可重试的部分进度，不会留下虚假完成证据。

## 复审中经证据撤回的两项疑虑

1. 最早 `fba23e7` 301 producer 不会造成 scanner 空集：其 `migratePrecanonicalAliasesIfNeeded()` 在 attach 前无条件把 `legacyEventID` 写入 alias 表，而且其保留的 6-part `messages.event_id` 无法通过 current canonical guard，所以会正确 pending。真实 producer 代码与 fixture 均证实了这一点，没有为不成立的问题放宽 scanner。
2. 普通 post-301 `persist()` 无法在保持 single fingerprint 的同时累积 12 个 raw-layout aliases：每个不同 raw payload 都会同时追加对应 `legacyLANEventID`，distinct standalone count 随之大于 1，先命中 multi-revision pending gate。只有旧 302 scanner 能在不增加 fingerprint 时批量制造 witness，已由 304 专门阻断。

## fresh 验证

工具链：macOS 13.7.8；Apple Swift 5.2.4；Python 3.7.3；Node 14.18.0；zsh 5.9。

| 范围 | 命令 / 结果 |
|---|---|
| diff / syntax / Swift 5 | `git diff --check HEAD^..HEAD`、listener/mapper `zsh -n`、所有 `.mjs` `node --check`、`swiftc -swift-version 5 -typecheck scripts/wecom-group-listener.swift` 均 exit 0。 |
| standalone listener full | `zsh scripts/test-wecom-group-listener.sh` → 全部场景 PASS，exit 0。含真实 A/B→C→baa301、current HEAD per-survivor 303、808 witness-less、旧 round-5 302→304 重审、TEXT/BLOB、collision、线性工作量、source/checkpoint/path 安全。 |
| native relevant | mapper、message consumer、notification policy、payload decoder、probe 五组脚本全部 PASS；probe 15 个场景 PASS。 |
| Python full | `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest scripts.test_wxfomo_lan_server` → `Ran 82 tests in 44.369s`，OK。 |
| static security focused | notification DB/static overlap、allowlisted sensitive hardlink、CLI static-root overlap、sensitive hardlink 四项 → `Ran 4 tests in 5.103s`，OK。 |
| frontend | `node scripts/test-wxfomo-lan-frontend.mjs` → `PASS: wxFomo LAN frontend state`；全部 `.mjs` syntax exit 0。 |
| launcher readiness | foreign-PID 与 missing-index 两项 PASS。 |
| launcher full | 在其他 Swift fixture 全部结束后单独运行 `PYTHONDONTWRITEBYTECODE=1 zsh scripts/test-wxfomo-lan-launcher.sh` → `PASS: wxFomo LAN launcher supervision`，exit 0。 |

## 调试过程、安全与清理

- 第一次 full listener 运行期间继续修改同一 test shell，zsh 在读取变动文件时最终报 `unmatched "`。最终文件 `zsh -n` 为 0，代码冻结后已从头 fresh 运行 full listener 并 exit 0；这不是 production assertion failure。
- 一次 full launcher 与多个 Swift interpreter/compiler fixture 并发时，报 `web server did not restart within 3s`。没有放宽断言或超时；检查确认测试 trap 已清理自己的 launcher/children/fixture，本轮 diff 也不涉及 launcher。单一假设是并发 Swift 编译使 3 秒时间窗内的 child 启动未获得调度；在其他测试全部结束后不改任何代码单独复现，同一套件 exit 0，支持资源争用而非 production 回归的根因判定。
- 所有 listener/E2E 均显式传入隔离的临时 source/config/store/port/token。没有读取、重放或伪造真实企业微信通知。
- 本轮未向真实 session 9829 或 PID 71119/71128/48470 发送任何信号，未修改其配置/store/token。最终只读 `ps` 确认三个 PID 仍存活。
- 最终 artifact 审计确认 repo 内无 DB/token/log/pycache，临时根目录无本组 listener/launcher fixture。一个已验证无 open file 的 repo `__pycache__` 与三个 2026-09-02 遗留 launcher fixture 已移入可恢复的 Trash bundle `wxfomo-round6-cleanup.rRJnEA`；没有删除或移动真实 launcher 文件。

## 提交

- `65f495d` `fix: preserve legacy alias revision provenance`
- 本报告由后续 documentation commit 纳入。

round 6 增量范围为 `1c5dbff21f4f211dab5db612483f0290b1fbff57..`本报告提交；完整交付范围为 `8674202325a7f65ffd5801d14ec8301a1842ad31..`本报告提交。

## 剩余信息边界

- 无已知 unresolved 生产缺陷。
- pre-c0 store 没有保存任意 raw title/subtitle/body、历史 attachment 或每个 folded revision 的语义 tuple；这些信息不可从 opaque hash 反演。本轮对此保持 fail-closed，未放宽 unknown raw/attachment 边界。
- 完整 SwiftPM self-test 仍受宿主限制：package tools version 5.10，本机为 Swift 5.2.4 且 Command Line Tools 无 `xctest`。这不是 assertion failure；本机可执行范围已用 production Swift 5 typecheck 和 native/listener 脚本覆盖。

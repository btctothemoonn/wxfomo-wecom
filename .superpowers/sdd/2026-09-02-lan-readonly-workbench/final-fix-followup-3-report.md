# LAN 只读工作台最终复审 round 3 修复报告

日期：2026-09-03

分支：`codex/wecom-notification-probe`

复核基线：`b512177faac150c4ac0fbe7aedbcfe4712730118`

原始交付基线：`8674202325a7f65ffd5801d14ec8301a1842ad31`

复审输入：`final-review-followup-3.md`（5 项 Important）

## 结论

round 3 的 5 项 Important 均已通过真实失败 fixture、根因定位和最小生产修复关闭。两次独立复核在本轮实现中分别发现了“旧 native 前缀布局 alias 未覆盖”和“旧业务状态为空时 dependency 健康状态仍被旧值覆盖”两个缺口；两项都重新进入 RED，修复后再次由原复核路径确认 GREEN。

前两轮安全边界保持不变：Notification source identity/inode 校验、source-bound UUID-less ID、exact event/alias 查询、写入成功后 checkpoint、字段 projector、公开 host allowlist、私有 token、Bearer 认证、非 GET/HEAD `405`、opaque cursor、只读 SQLite、有限请求 timeout，以及 exact public-asset allowlist/hardlink 隔离均未放宽。

本轮只使用隔离临时 Notification/message/workspace SQLite、配置、token、端口和合成消息。没有读取、重放或伪造真实企业微信通知；没有停止、发信号或写入真实 launcher session 9829、PID 71119、listener PID 71128 或其子进程。

## 逐项 resolution 与 TDD 证据

| 项目 | RED / 根因 | 最小修复 | GREEN 证据 |
|---|---|---|---|
| Important 1：stable UUID 的 A/B/C 历史合并与全 alias | 真实 `git show c0c20ed^:scripts/wecom-group-listener.swift` 分别用 SQLite TEXT/BLOB stable UUID 写入历史 A、B，再由当前 source 提供 C。原升级路径只能处理一个旧 revision，BLOB fixture 首先留下多行。初版合并修复又被独立复核以真实主通知布局 `title=group, subtitle="", body="sender：content"` 复现：旧 native A alias `00e1a6a4c01d510d` 查不到。根因是旧 store 只留归一化字段，兼容 alias 重建仅覆盖 direct field layout。 | `consolidateLegacyRevisions` 按经 source 验证的 stable UUID/raw storage class 聚合候选，确定性选最旧 row 为 survivor；先对全部 canonical/standalone/native aliases 做 exact collision preflight，再在一个事务中更新 survivor 为当前 C、迁移 aliases、删除 A/B duplicates、修正受影响 conversation count/time。任一 collision 回滚且 migration 保持 pending。兼容 alias 生成覆盖旧生产 direct 与前缀 body 两种规范布局及 title/subtitle 顺序；UUID-less 和错误 storage-class 继续 fail closed。 | TEXT 与 BLOB 两种真实旧脚本 fixture 均得到 1 个 survivor、最旧 storage ID、C 的当前字段、conversation count=1、migration 完成；A/B/C 的 canonical、standalone 和 native aliases 都能 exact repository lookup 到同一 survivor。prefix-layout RED 修复后独立复核重跑通过；single-row、storage collision、UUID-less 跨 source、同 row 多 fingerprint 和 exact-ID conflict 回归均 PASS。 |
| Important 2：`.updated` 贯穿真实 AppModel 且无新消息副作用 | 原 `MessageStore.insertOne` 把同 ID 的内容变化和完全相同事件都返回 `.existing`；`AppModel.receive` 因而无法区分刷新与重复。无 store fallback 又只按 ID 去重，会丢掉同 ID 新内容。 | `MessageInsertResult` 增加 `.updated`。受限 UPDATE 只有 SQLite `changes == 1` 才返回 `.updated`，相同、较旧或跨 group 仍为 `.existing`；bulk 计数保持更新不增加新增数。新增 `MessageEventConsumer` 作为 AppModel 的真实结果分派：`.updated` 只 reload/replace display state 并立即返回，不执行地址切换、automation、rule、sound 或新消息计数；无 store 时同 ID 原位替换并重排。 | `WxFomoSelfTest` 通过真实 monitor → `MessageStore` 得到 `[.inserted, .updated]`，数据库仍 1 行且 conversation count 不增；consumer side-effect hook 只触发一次。无 store fallback 同 ID 替换也有 production-flow 断言。独立代码流复核确认 `AppModel.receive` 的 `.updated` 分支在所有新消息副作用之前返回。Swift 5.2 以实际 production source 加最小兼容 shim 编译运行 focused contract，输出 `PASS: MessageEventConsumer Swift 5.2 contract`。 |
| Important 3：默认发现 partial retry 与 ancestor permission fail | 不传 `--database` 的默认发现 fixture 中，已存在但 empty/partial schema 被当永久错误或 missing；重试路径还能按短 poll 周期重复 `getconf`。不可搜索祖先目录又会被误判为 missing 并循环到 timeout。 | 默认 candidates 与 `getconf` 在 retry loop 外只求值一次；empty、仅 app、仅 record 的 source 明确为 transient not-ready，并按 `max(pollInterval, 1s)` 重试。候选检查以 `lstat` 状态区分 missing 与 permission denied；不可搜索祖先立即返回 redacted `Notification Center 数据库路径权限不足`，不泄露路径。现存 corrupt/incompatible 继续 fail fast。 | 两个测试都省略 `--database`：partial schema 跨过至少一个 1 秒 interval 后补齐 schema/message 并成功，fake getconf count=1；`chmod 000` ancestor 立即以 redacted permission reason 失败且 getconf count=1。现存永久 corrupt/incompatible、startup schema wait、atomic replace 与 source rebind 回归均 PASS。 |
| Important 4：Automations 的 trades dependency | Controlled app RED 中 `/api/automations` 可用而 `/api/trades` 返回 locked/schema/corrupt 时，组合结果仍会显示“暂无最近意图”。首版保留旧 payload 的实现还在“旧成功状态为空”时把新的 unavailable dependency 覆盖回 `{available:true}`。 | Automations payload 始终包含 `tradesDependency:{available,reason}`；`retainReadOnlyPayload` 只保留上次业务字段，同时用本次 settings/trades/messages dependency 覆盖旧健康状态。locked/schema/corrupt 进入 2/4/8/16/30 秒有界退避，旧 automation/trade 数据保留；页面按 exact reason 显示 dependency 错误，不把不可读解释为业务空。 | Node app-level tests 覆盖 source_locked、schema_incompatible、source_corrupt 和旧成功为空的情况，均保留旧业务内容、更新 dependency reason、不出现“暂无最近意图”，并验证有界退避。独立复核构造的 stale-dependency RED 在修复后 GREEN。 |
| Important 5：Diagnostics supplemental messages dependency | `/api/diagnostics` 主请求成功时，补充 `/api/messages` 的 never-resolving 或 HTTP 503 被吞成 `lastMessageAt:null`；页面错误显示“尚无记录”，且 supplemental failure 不参与 retry。 | Diagnostics payload 增加 `messagesDependency:{available,reason}`；supplemental status 0/timeout/503 都规范化为 dependency failure。当前 dependency 状态覆盖旧健康值，旧 diagnostics/message time 数据保留，transient reason 参与同一有界退避；页面显示 exact reason 而非业务空。所有 `requestJson` 路径继续使用默认有限 timeout，并兼容有/无 `AbortController`。 | app-level `#diagnostics` tests 让 supplemental fetch 永不 resolve，以及返回真实 503/source_locked；两者都退出 loading、保留旧状态、显示 exact reason、不出现“尚无记录”并进入退避。有 AbortController 与无 AbortController 的默认 timeout 全请求矩阵继续 PASS。隔离浏览器用真实 SQLite exclusive lock 取得 `/api/messages` 503，页面显示两处“数据源临时锁定”，console errors=0。 |

## 系统化调试与独立复核

1. listener 的第一版 A/B/C fixture 使用 direct `title/subtitle/body`，未覆盖真实主通知的 sender 前缀 body。独立复核没有放宽 alias 断言，而是生成真实 mapper native ID 后得到确定 RED；补齐兼容布局后，A/B/C 三个 native alias 均唯一指向 survivor。
2. frontend 的第一版 retention 在 temporary error 时整体返回 previous payload，导致新 dependency 状态被覆盖。独立复核以“旧成功但业务数组为空”的状态直接断言 dependency，得到 `{available:true}` 与期望 unavailable 的 RED；修复只合并业务旧值并覆盖本次 dependency，不修改 retry 或错误分类断言。
3. listener full 曾在与其他重型 suite 并行时出现一次测试 lock-holder 未及时建立导致的 `database is locked`；单独复现定位为 fixture 并发调度竞争。最终从 HEAD 独占重跑完整未修改 suite 全部通过，没有调整生产重试逻辑或放宽断言。

## 最终 fresh 验证

工具链：macOS 13.7.8；Apple Swift 5.2.4；Python 3.7.3；Node 14.18.0。

| 范围 | 命令 / 结果 |
|---|---|
| diff | `git diff --check 8674202325a7f65ffd5801d14ec8301a1842ad31..HEAD` → exit 0。 |
| standalone listener | `zsh scripts/test-wecom-group-listener.sh` → 35 个场景全部 PASS，exit 0；包含真实 pre-c0 TEXT/BLOB A/B/C、prefix native aliases、default partial/permission、collision/UUID-less/source rotation 回归。 |
| Python full | `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest scripts.test_wxfomo_lan_server` → `Ran 82 tests in 44.015s`，OK。 |
| static security focused | notification DB at allowlisted path、allowlisted sensitive hardlink、server/CLI static-root overlap 共 4 tests → `Ran 4 tests in 5.183s`，OK。 |
| native focused | `test-wecom-notification-policy.sh`、`test-wecom-notification-mapper.sh`、`test-wecom-notification-payload-decoder.sh`、`test-wecom-notification-probe.sh` 全部 PASS。 |
| Swift 5.2 | listener 与 notification probe production scripts 的 `swiftc -swift-version 5 -typecheck … -lsqlite3` 均 exit 0；实际 `MessageEventConsumer`/models 的 focused compile-run PASS；8 个相关 shell scripts `zsh -n` exit 0。 |
| frontend | `node scripts/test-wxfomo-lan-frontend.mjs` → `PASS: wxFomo LAN frontend state`；production/test `.mjs` 均 `node --check` exit 0。 |
| launcher focused | `PYTHONDONTWRITEBYTECODE=1 zsh scripts/test-wxfomo-lan-launcher-readiness.sh all` → foreign-PID 与 missing-index 均 PASS。 |
| launcher full | `PYTHONDONTWRITEBYTECODE=1 zsh scripts/test-wxfomo-lan-launcher.sh` → `PASS: wxFomo LAN launcher supervision`。 |
| 浏览器 fixture | 独立 `127.0.0.1:55530`、合成 DB/token/config：认证后 sentinel/count/heartbeat 正确；Automations partial schema 显示 dependency reason；Diagnostics 在真实 message DB exclusive lock/503 下保留旧态并显示“数据源临时锁定”；unauth `401`、POST `405`、sensitive static `404`、traversal `400`；console errors=0。tab、server、lock-holder、fixture 全部精确清理。 |
| artifacts/process | repo 内无临时 DB/token/log/pycache；测试 fixture、测试 tab 与测试 PID 已清理。只读进程核对只看到真实 PID 71119/71128 及其既有 server child，没有向其发送信号或修改文件。 |

## 本 round 3 提交

- `8089608` `fix: consolidate notification history during discovery`
- `d496fea` `fix: propagate native message update outcomes`
- `87d7fe6` `fix: retain supplemental dependency failures`
- `baa877b` `fix: restore prefixed notification aliases`
- 本报告由后续 documentation commit 纳入。

round 3 增量范围为 `b512177faac150c4ac0fbe7aedbcfe4712730118..` 本报告提交；完整交付范围为 `8674202325a7f65ffd5801d14ec8301a1842ad31..` 本报告提交。

## 剩余疑虑与环境限制

- 没有已知 unresolved 生产缺陷。
- pre-c0 standalone store 没有保存任意原始 notification attachments 和未归一化 raw title/subtitle/body，因此无法从旧 store 信息论式反演任意未知历史布局的 native hash。本轮已覆盖真实旧生产可由保存字段确定重建的 direct 与 sender-prefix 两种规范布局；canonical/standalone alias 负责其余稳定防重，无法证明的 alias 不猜测，避免跨消息误绑定。
- 本机完整 `swift run wxfomo-selftest` 在产品代码编译前失败：`xcrun --sdk macosx --find xctest` 找不到 `xctest`；同时 package tools version 5.10，而唯一系统 Swift 为 5.2.4。此为宿主测试工具限制，不是本轮 assertion failure。可构建范围内已完成 Swift 5.2 production typecheck、native suites，以及实际 consumer source 的 focused compile-run；完整 SwiftPM self-test 仍需 Xcode 15+/Swift 5.10+ 环境。

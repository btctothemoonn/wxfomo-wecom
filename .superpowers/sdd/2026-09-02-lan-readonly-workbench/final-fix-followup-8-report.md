# LAN 只读工作台最终复审 round 8 修复报告

日期：2026-09-04

分支：`codex/wecom-notification-probe`

round 8 基线：`61e40612b6d68b3fb59b8411e6490d5861fcfbff`

原始交付基线：`8674202325a7f65ffd5801d14ec8301a1842ad31`

代码提交：`c5e41b85ea54a5eae94c3a049538005872167ddf` (`fix: recover partial legacy alias migrations`)

## 结论

round 8 唯一剩余 Important 成立并已关闭。

真实升级链 `c0c20ed^ → 65f495d → HEAD` 中，`65f495d` 按 owner 独立提交 marker 301 migration：owner A 可以先变为 canonical、写旧 provenance 303 并错误占有一个 compatibility alias；owner B 随后因同一 alias 冲突回滚，marker 301 不存在。旧 HEAD 的恢复扫描只把仍为 pre-canonical 的 B 纳入 owner universe，漏掉已经 canonical 的 A，因此只能永久 pending，且只读查询继续把歧义 alias 解析到 A。

当前实现以新 provenance 305 和 partial-recovery marker 306 区分旧半状态与当前原子 producer；在 marker 301 缺失且发现旧 303 时，同时扫描 canonical 303 survivor、其 retained standalone aliases、仍为 pre-canonical 的 owner，以及可能由旧 safety replay 产生的 canonical duplicate。所有 owner 先经 source identity/当前 canonical/语义验证，再做全局 alias preflight。只有经真实历史 owner 计划证明、且不是 canonical、standalone、current raw 或 exact message ID 的纯 compatibility 冲突才会被隔离。隔离记录、错误 alias 删除、全部 owner consolidation、conversation repair、305、306 和 301 在同一 `BEGIN IMMEDIATE` 内提交。

## TDD、根因与最小修复

| 项目 | RED / 失败原因 | 最小修复与 GREEN 契约 |
|---|---|---|
| 真实 65f 半迁移链 | 新 fixture 用仓库中的真实 `c0c20ed^` listener 建 A/B，再用真实 `65f495d` listener 和 SQLite trigger 停在 A 已提交、B 冲突、301 未写、shared alias 错指 A 的状态。未修复 HEAD RED：`FAIL: recovered 65f partial fixture unexpectedly emitted`；数据库保持 pending 且错误 alias 可解析。 | 新扫描以 old provenance 303 找回已经 canonical 的 A，并和 B 一起建立完整 expected owner set。新 305 与 306 只由当前原子 producer 写入；成功后 301=1、305=2、306=1、message cardinality=2、conversation counts 精确，歧义 alias 从活动映射删除并写 quarantine。 |
| 隔离后的只读解析 | 旧 Swift/Python lookup 只查 `message_event_aliases`，即使另存隔离证据仍会解析 stale row。 | 新 quarantine 表是持久 deny-set；Swift alias fallback 和 Python `MessageRepository.by_event_ids` 都 anti-join quarantine，而 exact `messages.event_id` 查询保持优先。API 测试证明 stale active alias 返回零 source message，同时同名 exact event 仍可读取。 |
| 事务中断与恢复 | 若 quarantine/delete、A/B rewrite、provenance 或 marker 分事务，任何中断都可能再制造下一代半状态。 | trigger 在最终 marker 301 insert 前 abort。GREEN 断言完整回滚到旧 65f 状态：301/305/306/quarantine 均为 0，303=1，messages=2，B 仍 pre-canonical，shared alias 仍指 A；删除 trigger 后二启一次收敛到完整新状态。 |
| 旧 safety replay duplicate | 让真实 `65f495d` 在半迁移后继续 safety replay，产生 A canonical、B pre-canonical、B canonical duplicate 共 3 行。旧恢复会遇到 canonical UNIQUE 槽冲突或漏行。 | 在 recovery mode 中按 record/storage identity 暂挂无旧 provenance 的 canonical row，并要求 source-derived canonical hash/UUID bytes 再验证；事务内先迁移 duplicate aliases、删除 duplicate、再刷新最老 survivor。GREEN 后回到 2 行且 305/quarantine 完整。 |
| 伪造/漂移 old303 canonical | 仅凭 old303 和 retained standalone alias 可能把被篡改的 canonical row当成已验证 A。初始只读审计指出此 P1。 | partial old303 candidate 必须满足 `storedEventID == source-derived notification.eventID`。tampered fixture 保持 pending，301/305/306/quarantine/错误 alias 全部不变。 |
| 多 standalone 的复杂度 | 每条 standalone alias 都生成 candidate，并反复携带同一 retained alias 数组会回到 O(K²)。600 witness、1 秒 deadline fixture 初始暴露该 P2。 | 先按 message、再按 `(recordID, uuidStorageBytesHex)` 折叠 standalone identity；同 identity 只生成一个 candidate并保留 aliases，多个不同 identity 则 fail-closed pending。600 条真实形状 witness 在原 deadline 内完成 301/305。 |
| protected/exact 冲突 | quarantine 若能覆盖 exact/canonical/standalone/current raw，会把真实标识静默隐藏。 | 全计划建立 protected set；每个 ambiguity 还要通过 exact-row absence、现有 alias owner 属于 recovered candidate、当前 claimant 包含该 owner等检查。exact message fixture 保持全批 pending，数据库零 quarantine/零新 provenance/零 marker mutation。 |
| 已完成 65f store 兼容 | 新版本不能把已具有 301+303 的合法旧 store 当 partial 重写。 | 真实 `c0c20ed^ → 65f495d` 完成链 fixture 在 HEAD 上保持 event ID、alias count 和 303 不变，不写 305/306，也不重放通知。 |

## 原子性、恢复性与安全边界

- partial recovery 的 owner universe 不再只由当前 `messages.event_id` 的六段 legacy 形状决定：旧 303 canonical survivor 必须具有可解析 retained standalone identity，且当前 source 必须独立重建同一 canonical ID 与 UUID storage bytes。无法证明时保守 pending，不猜测 hash。
- quarantine 仅处理本次完整计划内、两个以上 source-verified owner 共同声明、且当前错误 owner 本身属于 recovered candidate 的纯 compatibility alias。exact row、canonical、standalone 和 current raw 任何一个发生冲突都整批回滚。
- `insertAlias` 是正常 persist、301 consolidation 和后续 prefix upgrade 的统一写入口；命中 quarantine 会抛 storage error，不能静默重新绑定。prefix scan/plan 也过滤 quarantined derived aliases，并先拒绝 quarantined protected identity。
- quarantine insert、错误 alias delete、candidate 二次验证、duplicate fold、survivor update、alias writes、conversation count repair、每 owner 305、306 与 301 均在同一事务。当前 producer 自身中断后没有可观察的新半状态。
- 完整 301+303 store 保持既有兼容；旧 302/304 prefix 审计及前七轮 canonical/source cursor/heartbeat/auth/static allowlist/timeout/readonly 边界均未放宽。

## 独立只读审查

两个独立 reviewer 分别检查 production 路径与测试真实性。

- production reviewer 初审发现 old303 canonical 未强制等于 source canonical（P1）及多 standalone candidate 复制 retained aliases 导致 K²（P2）。两项均先补 RED，再以上述 source guard 与 identity pre-grouping 修复；终审确认 transaction/quarantine/read/prefix/post-replay 路径无新 P1/P2。
- test reviewer 独立重跑真实综合链和两个 API quarantine 测试，确认 trigger 确实在 301 末端中断、tampered/exact/600 witness/post-replay 路径均命中目标。其建议补充 abort 后 `303=1` 与 `messages=2` 的直接断言已加入并 focused GREEN。

## fresh 验证

工具链：macOS 13.7.8；Apple Swift 5.2.4；Python 3.7.3；Node 14.18.0；zsh 5.9。

| 范围 | 命令 / 结果 |
|---|---|
| diff / syntax / Swift 5 | `git diff --check`、`zsh -n scripts/test-wecom-group-listener.sh` 均 exit 0；`swiftc -swift-version 5 scripts/wecom-group-listener.swift -lsqlite3 -o /tmp/wxfomo-round8-listener-check` exit 0。 |
| focused TDD | 真实 65f 半状态、成功 quarantine、301 末端 abort→restart、post-safety-replay duplicate、tampered old303 canonical、600 standalone linear deadline、protected exact collision、completed 65f compatibility 共 8 条路径逐项 GREEN；最后两条 abort-state 补强断言也由同一综合 focused test 重新执行通过。 |
| standalone listener full | production/test 冻结后从头 `zsh scripts/test-wecom-group-listener.sh`：54 个场景全部 PASS，最后 `PASS: rejects unsafe config and store paths without mutation`，exit 0。full 后仅加入上述两条无 production 变更的 abort-state 断言，并以 focused test 验证；未无理由重复其余 53 条未变场景。 |
| native relevant | mapper、message consumer、notification policy、payload decoder、probe 五组脚本均 exit 0；probe 的 15 个场景全部 PASS。 |
| Python full | `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest scripts.test_wxfomo_lan_server` → `Ran 84 tests in 45.016s`，OK。 |
| static security focused | notification DB/static overlap、allowlisted sensitive hardlink、CLI static-root overlap、sensitive hardlink四项 → `Ran 4 tests in 5.112s`，OK。 |
| frontend | `node scripts/test-wxfomo-lan-frontend.mjs` → `PASS: wxFomo LAN frontend state`；全部 `scripts/*.mjs` 的 `node --check` exit 0。 |
| launcher | readiness foreign-PID 与 missing-index 均 PASS；`PYTHONDONTWRITEBYTECODE=1 zsh scripts/test-wxfomo-lan-launcher.sh` → `PASS: wxFomo LAN launcher supervision`，exit 0。 |
| 隔离浏览器 | 随机 `127.0.0.1:50617`、独立 message DB/group/config/token：未认证 `/api/bootstrap` 为 401、认证后为 200；token UI 登录后 sentinel `ROUND8_BROWSER_SENTINEL` 可见，收件箱/群 count=1，旧 heartbeat 显示“监听器未活动”，复制控件存在，`[data-write-action]` 数量为 0。tab、server session、port 和精确 fixture 目录均已清理。 |

## 清理与真实进程隔离

- 没有读取、重放、生成或发送真实企业微信通知；所有 source/store/config/token/port 均为隔离临时 fixture。
- 浏览器 fixture server 只绑定 `127.0.0.1:50617`，用其已知 session 正常 Ctrl-C 退出；`lsof` 确认该 port 无 listener 后才删除精确 `/tmp/wxfomo-round8-browser.*` 目录。
- Python 测试产生的两个精确 ignored `__pycache__` 目录已经逐文件核对并删除；最终 artifact audit 不含 SQLite DB、token、log、pycache。
- 没有向真实 session 9829 或 PID 71119/71128/48470 发送信号或写入其文件。最终只读 `ps` 确认三者仍存活；没有 Round8 listener/launcher/browser 测试进程遗留。

## 提交与剩余边界

- `c5e41b8` `fix: recover partial legacy alias migrations`
- 本报告由后续 documentation commit 纳入。

round 8 增量范围为 `61e40612b6d68b3fb59b8411e6490d5861fcfbff..`本报告提交；完整交付范围为 `8674202325a7f65ffd5801d14ec8301a1842ad31..`本报告提交。

无已知 unresolved production defect。

pre-c0 store 没有保存任意 raw title/subtitle/body、历史 attachment 或每个 folded revision 的完整语义 provenance；无法由 retained opaque hash 重建的状态继续 fail-closed pending。完整 SwiftPM self-test 仍受宿主工具链限制（package tools version 5.10，本机 Swift 5.2.4 且 Command Line Tools 无 `xctest`）；本机可执行范围已由 production Swift 5 compile 与 native/listener scripts 覆盖。

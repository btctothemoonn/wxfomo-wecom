# LAN 只读工作台最终复审 round 7 修复报告

日期：2026-09-04

分支：`codex/wecom-notification-probe`

round 7 基线：`4796a3004f60d41769a3968f6184e81421039cfd`

原始交付基线：`8674202325a7f65ffd5801d14ec8301a1842ad31`

代码提交：`e9d728c` (`fix: make legacy alias migration crash atomic`)

## 结论

round 7 的 2 项 Important 均成立并已关闭：

1. marker 301 的旧实现按 owner 分事务 consolidation。两个 owner 的历史 compatibility alias 冲突时，owner A 可先 canonicalize 并写 303，owner B 才发现冲突；A 重启后不再作为 pre-canonical candidate，因而留下不可重试的部分完成状态。
2. 旧 round-5 按 owner 提交完整 prefix aliases、再单独写 marker 302。若进程在两者之间中断，数据库可留下 `301 present / 302 absent / 303 absent / single fingerprint / full witness`；仅凭 witness 当前存在会把 round-5 后写 aliases 倒签为 marker 301 的原始证据。`created_at <= 301.applied_at` 也不能单独证明先后关系，因为系统时钟可回拨。

修复后，当前 HEAD 的 marker 301 先完成所有 owner 的计划、完整覆盖检查和全局 alias 歧义预检，再在一个 `BEGIN IMMEDIATE` 中二次验证并原子提交所有 survivor、aliases、303 和 301。旧 store 的 301 witness 同时要求有限时间边界与有限 producer-shape 证明；时间或来源无法可靠区分时保持 pending，不猜测 hash。

## TDD、根因与最小修复

| 项目 | RED 证据 | 根因 | 最小修复与 GREEN 契约 |
|---|---|---|---|
| 301 complete-owner/global preflight | 新 fixture 用真实 `c0c20ed^` listener 持久化两个 owner；两者当前 raw ID 不冲突，但旧 compatibility layout 产生纯历史冲突。未修复实现 RED：`FAIL: one version-1 owner wrote provenance before the global preflight`。 | startup 对每个 record 立即调用独立 consolidation 事务；跨 owner 冲突只有处理后一个 owner 时才可见。 | `planLegacyAliasConsolidation` 先为全部 `(recordID, uuidStorageBytesHex)` owner 生成计划；要求 candidate ID 完整且互不重叠，执行全局 ambiguity preflight。`consolidateLegacyRevisionPlans` 在单一 `BEGIN IMMEDIATE` 内重新计算计划、复核每条 message 语义/source identity、复核 exact/alias owner，再统一写 survivor/aliases/303/301。冲突 fixture 中 301/303/shared alias 均为 0，两条 pre-canonical row 与 conversation count 不变。 |
| 301 全局事务 deadline | 慢 alias transaction fixture 在内层无 deadline 检查时实测约 11.89 秒才退出，超过 `--once --timeout 3` 契约。 | deadline 只在外层 retry/record chunk 检查；candidate/alias/duplicate/verification/count 循环没有检查。计划构造还会重复建立 candidate set。 | 每个非恒定长度循环与 commit 前都检查 deadline；任何超时由 catch 统一 `ROLLBACK`。计划缓存 `candidateIDs`/`survivorID`，source candidates 预按 `(recordID, uuidStorageBytesHex)` 分组。串行 focused GREEN：测试自身断言迁移事务 `<5s` 退出，301/303/row 更新全部回滚。 |
| round-5 crash window | 真实 `c0c20ed^ → 8089608/301 → 1c5dbff/round5`，用 SQLite `BEFORE INSERT` trigger 只中断 302 marker transaction；round-5 自己提交的 aliases 保留。未修复 HEAD 把 post-301 witnesses 认证为旧证据并写完成 marker。 | 旧 store 没有 transaction-bound 303；scanner 只看当前 alias 集合，不知道每条 alias 是 301 前还是后产生。 | scanner 在同一只读事务读取 301 `applied_at` 与每条 alias `created_at`。marker、每个 required witness 的类型必须是 INTEGER/REAL、值必须有限，且 witness `created_at <= applied_at`；缺失、TEXT、NaN/Inf 或晚于 marker 都 pending。真实 crash fixture GREEN：302/304 均不写，cardinality 不变。 |
| 时钟回拨与 producer folding | 把真实 round-5 crash fixture 的 aliases 全部回拨到 marker 301 前，时间条件不再能拒绝。初始 RED：`FAIL: HEAD trusted a clock-rollback copy of round-5 witness aliases`。独立审查又给出更窄反例：`group == sender` 时，旧 policy 集 P 少一个 direct witness，但 808 在 301 前恰好无过滤写入该 direct-normal ID；真实 `808 → round5 abort302 → backdate` RED：`FAIL: HEAD trusted a combined 808 and backdated round-5 witness set`。 | 条件 `W ⊆ P` 错误地假设 `W − P` 不可能由更早 producer 补齐。808 可提前写 direct-normal；随后 round-5 写完整 P，二者合并覆盖 W。 | 显式建立旧 producer 集：required marker-301 witness `W`、round-5 policy IDs `P`、808 可提前写的唯一 direct-normal `E`。当 `W ⊆ P ∪ E` 时，要求 `|P − W| > 1` 且 marker 前 retained expanded IDs 最多 1 条；合法 baa 只会有 W 加至多一个 raw `P − W`，808+round5 则留下全部 `P − W`，即使时间回拨也 pending。`|P − W| <= 1` 等无法区分状态保守 pending；当 `W ⊄ P ∪ E` 时，808+round5 无法补齐 W，有限时间证据才可使用。负向旧链与正向真实 baa `group == sender` fixture 均 GREEN。 |
| 非有限时间测试隔离 | 原测试把 Inf mutation 放在已经具有 full round-5 expanded shape 的 store 上，结构 gate 会先拒绝，不能证明 finite/type guard。 | 测试的两个拒绝条件重叠。 | 改用真实 `c0c20ed^ → baa877b/301` 单 revision store，分别令一个 required witness 或 marker 301 为 Inf；两次均 pending。最后恢复有限时间，同一 store 成功写 302/304，证明前两次只由时间校验拒绝。 |

## 原子性、复杂度和安全边界

- 301 的当前 producer 只有一个写事务：所有 owner 的 survivor refresh、duplicate alias move、duplicate delete、完整 alias insert/verify、per-survivor 303、conversation count repair 和 marker 301 要么全部 COMMIT，要么全部 ROLLBACK。不存在 A 已认证、B 冲突后才失败的状态。
- 第一次 recovered compatibility alias 写入前已有 complete-owner 计划与全局 preflight；事务内再次检查 candidate rows、source sequence、group/sender/content、exact owner 与 alias owner，防止计划和写入间的 store 变化。
- source candidates 用 dictionary 预分组；candidate IDs 在计划中缓存；每条 candidate/alias 的主要工作为常数次 hash/SQLite lookup。现有 4/8 candidate 线性量级测试和新 deadline rollback 测试均通过，没有恢复 O(C²) filter/set rebuild。
- 旧 producer 的 wall-clock 字段只作为必要条件，不作为充分条件。时钟回拨由 producer shape 拒绝；任何无法区分的 clock/provenance 状态均保持 302/304 pending。因此没有依赖宽容时间窗，也没有猜测 opaque hash。
- 前六轮边界未放宽：canonical/source-bound event identity、exact alias ownership、TEXT/BLOB UUID storage class、unknown raw/attachment fail-closed、source replacement/checkpoint、field projectors、heartbeat、authenticated readiness、Bearer/method 405/cursor、全请求 timeout、static exact allowlist/hardlink/sensitive overlap 均由 fresh full 回归覆盖。

## 独立只读审查

独立 reviewer 对最终生产 diff 重新检查了 `W/P/E` 集合证明、合法 baa `group == sender`、全 owner coverage、exact preflight、301/303 transaction、cached-set 复杂度和 deadline propagation，结论为无 production blocker。其唯一可选建议是增加合法 baa `group == sender` 正向 fixture；本轮已补充并在最终 full listener 中通过。

## fresh 验证

工具链：macOS 13.7.8；Apple Swift 5.2.4；Python 3.7.3；Node 14.18.0；zsh 5.9。

| 范围 | 命令 / 结果 |
|---|---|
| diff / syntax / Swift 5 | `git diff --check`、`zsh -n scripts/test-wecom-group-listener.sh`、`swiftc -swift-version 5 -typecheck scripts/wecom-group-listener.swift -lsqlite3` 均 exit 0。 |
| focused RED → GREEN | complete-owner collision、deadline rollback、post-301 crash、808+round5 clock rollback、legitimate baa Inf、legitimate baa group=sender、真实 intermediate prefix、embedded-colon old-policy 共 8 条 focused 路径逐项 GREEN。 |
| standalone listener full | 最终代码/测试冻结后从头 `zsh scripts/test-wecom-group-listener.sh`：52 个场景全部 PASS，最后 `PASS: rejects unsafe config and store paths without mutation`，exit 0。 |
| native relevant | mapper、message consumer、notification policy、payload decoder、probe 五组脚本均 exit 0；probe 的 15 个场景全部 PASS。 |
| Python full | `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest scripts.test_wxfomo_lan_server` → `Ran 82 tests in 43.701s`，OK。 |
| static security focused | notification DB/static overlap、allowlisted sensitive hardlink、CLI static-root overlap、sensitive hardlink 四项 → `Ran 4 tests in 5.097s`，OK。 |
| frontend | `node scripts/test-wxfomo-lan-frontend.mjs` → `PASS: wxFomo LAN frontend state`；全部 `scripts/*.mjs` 的 `node --check` exit 0。 |
| launcher | readiness foreign-PID/missing-index 两项 PASS；其他 Swift fixture 全部结束后单独运行 `PYTHONDONTWRITEBYTECODE=1 zsh scripts/test-wxfomo-lan-launcher.sh` → `PASS: wxFomo LAN launcher supervision`，exit 0。 |
| 浏览器 fixture | 随机 `127.0.0.1:58430`、独立 message/notification DB、config、token：静态首页 200，未认证 bootstrap 401，POST 405；token 登录后 sentinel 可见、收件箱/群 count=1、旧 heartbeat 显示“监听器未活动”、复制按钮为“已复制”且隔离剪贴板为 sentinel、`data-write-action=0`、console warning/error=0。tab、server session、port 和精确 fixture 目录均已清理。 |

## 调试、清理与真实进程隔离

- 一次把 7 个 Swift-heavy focused fixture 并发运行时，deadline test 的 100 MB SQLite trigger 操作受 CPU 争用影响，总进程墙钟为 5.52 秒并触发测试的 `<5s` assertion。没有放宽 assertion；所有并发 fixture 自行清理后，以相同代码串行运行该测试并 exit 0，随后两次冻结版 listener full 也包含同一断言并 exit 0。这是测试调度方式造成的不可中断 SQLite 单步争用，不是 migration 在 deadline 后继续写；数据库的 301/303/survivor 均验证为回滚。
- 浏览器 fixture 的初始 sentinel 时间戳位于默认 2 小时筛选外；只修改隔离 fixture 时间后按本地页面验证规则 reload，sentinel/计数/复制/只读状态均符合预期。未更改 production 数据。
- 一次未带 `PYTHONDONTWRITEBYTECODE` 的 `--help` 检查生成了精确可归因的 ignored `scripts/wxfomo_lan/__pycache__`。确认无 open file 后只删除该目录；最终 repo artifact audit 不含 DB/token/log/pycache。
- 没有读取、重放或伪造真实企业微信通知。所有 source/store/config/token/port 均为隔离临时 fixture。
- 没有向真实 session 9829 或 PID 71119/71128/48470 发送任何信号或写入其文件。最终只读 `ps` 确认三个 PID 均仍存活，且没有 listener/launcher/browser 测试进程遗留。

## 提交与剩余边界

- `e9d728c` `fix: make legacy alias migration crash atomic`
- 本报告由后续 documentation commit 纳入。

round 7 增量范围为 `4796a3004f60d41769a3968f6184e81421039cfd..`本报告提交；完整交付范围为 `8674202325a7f65ffd5801d14ec8301a1842ad31..`本报告提交。

无已知 unresolved production defect。

pre-c0 store 没有保存任意 raw title/subtitle/body、历史 attachment 或每个 folded revision 的完整语义 provenance；这些信息无法从 opaque hash 反演。本轮保持 fail-closed。完整 SwiftPM self-test 仍受宿主工具链限制（package tools version 5.10，本机 Swift 5.2.4 且 Command Line Tools 无 `xctest`）；本机可执行范围已由 production Swift 5 typecheck 与 native/listener scripts 覆盖。

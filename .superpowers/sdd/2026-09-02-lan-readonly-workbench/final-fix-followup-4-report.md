# LAN 只读工作台最终复审 round 4 修复报告

日期：2026-09-03

分支：`codex/wecom-notification-probe`

复核基线：`b8c5ec6817792a738cb2865d28722a737c89cb6b`

原始交付基线：`8674202325a7f65ffd5801d14ec8301a1842ad31`

复审输入：`final-review-followup-4.md`（3 项 Important）

## 结论

round 4 的 3 项 Important 均已按 RED → 根因 → 最小生产修复 → GREEN 关闭。两路独立只读审计分别复核 native/frontend 与 listener；审计额外发现 no-store `.unchanged` 仍会改写 AppModel activity，以及旧 exact-ID collision fixture 没有真正进入 alias preflight。前者重新进入一轮 RED/GREEN 并修复生产接线，后者修复为可命中群的 spaced-prefix 冲突回归。

前 3 轮已批准的安全与生命周期契约没有放宽：source identity/inode、写成功后 checkpoint、exact event/alias、UUID-less source fencing、字段 projector、公开 host allowlist、私有 token、Bearer auth、method `405`、opaque cursors、全请求有限 timeout、heartbeat TTL/visibility invalidation、静态 exact allowlist/hardlink 隔离及 launcher authenticated readiness 均保留。

本轮只运行隔离临时 fixture、localhost 端口、合成 token 和合成消息。没有读取、重放或伪造真实企业微信通知；没有停止、发信号或写入真实 launcher session 9829、PID 71119、listener PID 71128 或其子进程。

## 逐项 resolution 与 TDD 证据

| 项目 | RED / 根因 | 最小修复 | GREEN 证据 |
|---|---|---|---|
| Important 1：Diagnostics 原生 fetch reject、首载 unavailable、fresh primary merge | 测试先让 `/api/diagnostics` 成功而 `/api/messages` 原生抛 `TypeError("Failed to fetch")`。`requestJson` 原样抛出 TypeError，supplemental catch 只认识 `ApiError status 0/503`，于是进入外层 fallback；首载 payload 没有 `messagesDependency`，页面错误显示“尚无记录”。另一 pure RED 在 primary 从 inactive/permission 变为 active/corrupt 时得到实际 `listenerState="inactive"`：通用 retention 从 previous 出发，只覆盖 dependency，吞掉最新 primary sources/health。 | supplemental TypeError 规范为 `{available:false, reason:"message_source_unavailable"}`，401 仍原样交给登录代际处理，其他非网络程序错误仍抛出。Diagnostics transient retention 改为从 current `next` 出发，仅回填 previous 的历史消息字段 `lastMessageAt`；当前 sources、listenerState、health/retriableErrors、available/reason/items 与 dependency reason 全采用本次成功 primary。其他 Automations/Trading retention 不变。 | Node pure/app tests 覆盖 TypeError 首载、空首载、timeout、503、旧 `lastMessageAt`、primary health 同时变化和 2/4/8/16/30 秒退避；full frontend PASS。隔离浏览器令 `/api/messages` 原生断连接：页面显示最新 primary 的“数据源已损坏”和“消息库暂不可读”，不含“尚无记录”，显示重试状态，console errors=0。独立复核确认没有旧 primary 字段残留。 |
| Important 2：no-store 同 ID 的 group/time/identical guard | 新 focused production-source harness 在未修复实现上明确输出 `FAIL: identical event guard`、`FAIL: older event guard`、`FAIL: cross-group guard`。根因是 `withoutStore` 只用 event ID 判断是否为更新，却总是 filter + append。第一版 guard 后独立审计又发现真实 AppModel 对所有 `shouldRunNewMessageSideEffects=false` 都写入“刚刚更新” activity；新增 wiring contract 先 RED 为 `MessageEventConsumption has no member representsMessageUpdate`。 | 找到同 ID 后，仅当 group 相同、incoming `observedAt >= existing.observedAt` 且完整 event 实际变化时替换；identical、older、cross-group 统一返回 `.unchanged,false`。新增 `representsMessageUpdate` 把 `.replaceInMemory/.reloadFromStore + no-new-side-effects` 与 `.unchanged` 区分，AppModel 只有真实 update 才刷新 activity；拒绝项在 sound/address/rules/automation 前返回。新 ID 路径不变。 | Swift 5.2 focused harness 直接编译 production `MessageEventConsumer.swift`/`MessageEventOrder.swift`，覆盖 newer、equal-time changed、identical、older、cross-group、新 ID、persisted updated/existing，输出 `PASS: MessageEventConsumer no-store guards`。`WxFomoSelfTest` 同步包含完整 model fixture。独立复核逐行比对 `MessageStore` SQL 的同组、时间不旧、字段变化 guard 及真实 AppModel 调用，确认一致且 rejected update 不再改变 activity。 |
| Important 3：stable UUID 旧 native 的八种 prefix alias | 真实旧脚本 TEXT/BLOB store 与真实 native mapper fixture 先运行；旧生产仅生成 `sender：content` 和 `sender: content` 两类 compatibility alias。未修复代码实测八类 alias count 为 `[1,0,0,0,0,1,0,0]`，focused RED 首个缺失 ID 为 `b5314febdce4ac41`，尽管 messages/count/marker 已错误完成。 | `legacyNativeCompatibilityEventIDs` 显式枚举 review 指定的 8 个 body：全角/ASCII 冒号，前后各 0 或 1 个规范空格；继续复用既有 title/subtitle layouts、stable dedupe 和 survivor mutation 前的统一 unrelated-message exact collision preflight。没有增加任意 raw/attachment 猜测。 | 真实 mapper 生成 8 个互异 legacy native ID；real pre-c0 TEXT/BLOB 一次迁移后每个 alias 恰好一行并由 production repository exact lookup 到同一 canonical survivor，messages=1、conversation count=1、无 count mismatch、marker=1。A→B→C consolidation、storage-class collision、UUID-less 隔离继续 PASS。修复后的 spaced-prefix exact-ID conflict fixture真正 decode 当前群并进入 preflight，断言 marker 保持 pending、历史/冲突/current 三行不丢失、候选与冲突行不被改写、count 一致。独立复核批准。 |

## 系统化调试与独立审计补充

1. Diagnostics 修复没有把所有异常吞成 unavailable：只有已约定的 `ApiError 0/503` 和浏览器原生 `TypeError` 被规范化；401 继续触发认证所有权流程，其他异常继续上抛。
2. no-store 初次 guard 已阻止 sound/rule 等主要副作用，但审计沿真实 AppModel 发现 activity 文案仍变化。第二轮契约把“是否代表真实 update”变成 production consumption 的显式属性，避免仅靠某个调用点猜测 display update。
3. listener 原 collision test 把 config 改成另一群，`decodeMessage == nil`，无法证明扩展 alias 的 preflight。新 fixture 保持目标群可解码并使用新增 spaced-prefix ID；冲突时整批 migration rollback，而 safety replay 仍保存当前 canonical 消息，验证 fail closed 不等于丢数据。

## 最终 fresh 验证

工具链：macOS 13.7.8；Apple Swift 5.2.4；Python 3.7.3；Node 14.18.0。

| 范围 | 命令 / 结果 |
|---|---|
| diff | `git diff --check 8674202325a7f65ffd5801d14ec8301a1842ad31..HEAD` → exit 0。 |
| standalone listener full | `zsh scripts/test-wecom-group-listener.sh` → 35 个场景全部 PASS；八 alias、A/B/C、collision、source rotation、checkpoint、default discovery 与 unsafe paths 均执行。 |
| listener focused | real pre-c0 TEXT/BLOB 八 alias、A/B/C consolidation、有效 spaced-prefix exact-ID conflict、mapper 各自独立重跑，全部 PASS。 |
| Python full | `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest scripts.test_wxfomo_lan_server` → `Ran 82 tests in 43.816s`，OK。 |
| static security focused | notification DB/static overlap 与 allowlisted sensitive hardlink 共 4 tests → `Ran 4 tests in 5.110s`，OK。 |
| native focused | 新 `test-message-event-consumer.sh` 及 notification policy/mapper/payload-decoder/probe 全部 PASS。 |
| Swift 5.2 / syntax | listener、notification probe production scripts typecheck exit 0；consumer production source compile-run PASS；9 个相关 shell scripts `zsh -n` exit 0。 |
| frontend | `node scripts/test-wxfomo-lan-frontend.mjs` → `PASS: wxFomo LAN frontend state`；6 个 production/test `.mjs` 全部 `node --check` exit 0。 |
| launcher | readiness `all` 两项 PASS；完整 supervision suite → `PASS: wxFomo LAN launcher supervision`。 |
| 浏览器 | 独立 `127.0.0.1:61715` 合成 bootstrap/diagnostics 与原生断连接 messages：最新 primary、明确 dependency、非业务空态、retry 全部可见，console errors=0；tab、server、port、token/DB/script fixture 全部精确清理。 |
| artifacts/process | repo 内无临时 DB/token/log/pycache；隔离测试 PID/端口已清理。只读进程核对只见真实 launcher 71119、listener 71128 及既有 server child，没有对其发送信号或修改文件。 |

## 本 round 4 提交

- `12dc22e` `fix: preserve fresh diagnostics health on message failure`
- `1bd309b` `fix: guard in-memory message replacements`
- `5ce84a9` `fix: suppress activity for rejected message updates`
- `e653240` `test: cover equal-time in-memory updates`
- `d0d2bba` `fix: enumerate legacy sender-prefix aliases`
- 本报告由后续 documentation commit 纳入。

round 4 增量范围为 `b8c5ec6817792a738cb2865d28722a737c89cb6b..` 本报告提交；完整交付范围为 `8674202325a7f65ffd5801d14ec8301a1842ad31..` 本报告提交。

## 剩余疑虑与环境限制

- 没有已知 unresolved 生产缺陷。
- review 明确认可的历史信息边界保持不变：pre-c0 store 未保存任意 attachment 与未归一化 raw title/subtitle/body，无法反演未知布局的 native hash。本轮只补全由已保存 sender/content 可以有限枚举的 8 种规定 prefix，不猜测 unknown raw/attachment alias，避免跨消息误绑定。
- 本机完整 `swift run wxfomo-selftest` 仍在产品编译前因 `xcrun --sdk macosx --find xctest` 不存在而失败；package tools version 5.10，而系统仅 Swift 5.2.4。这是宿主工具限制，不是 assertion failure。可执行范围内已完成 Swift 5.2 production typecheck、native suites 和实际 consumer source focused compile-run；完整 SwiftPM self-test 需要 Xcode 15+/Swift 5.10+ 环境。

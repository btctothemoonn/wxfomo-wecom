# LAN 只读工作台最终复审 round 2 修复报告

日期：2026-09-03

分支：`codex/wecom-notification-probe`

复核基线：`8674202325a7f65ffd5801d14ec8301a1842ad31`

复审输入：`final-review-followup-2.md`（6 项 Important、1 项 Minor）

## 结论

round 2 的 6 项 Important 与 1 项 Minor 均已按真实失败 fixture、根因定位和最小生产修复关闭。已批准的边界没有放宽：Notification source inode 前后校验、source-bound UUID-less ID、exact event/alias 查询、写入后 checkpoint、字段 projector、公开 host 授权、私有 token、Bearer 认证、非 GET/HEAD `405`、opaque cursor、只读 SQLite 与 exact public-asset allowlist 均保留。

本轮只使用隔离临时 Notification/message/workspace SQLite、配置、token、端口和合成消息。没有读取或伪造真实企业微信通知，没有停止、发信号或写入真实 launcher session 9829、PID 71119、listener PID 71128 或其子进程。

## 逐项 resolution 与 TDD 证据

| 项目 | RED / 根因 | 最小修复 | GREEN 证据 |
|---|---|---|---|
| Important 1：真实 TEXT/BLOB pre-c0 升级与旧 alias | 真实 `git show c0c20ed^:scripts/wecom-group-listener.swift` fixture 先生成旧 store。BLOB fixture 起初不能同时保留 canonical/旧 native alias；加入“source row 在首次升级前已改内容”后，旧内容 native ID 丢失并会重放。TEXT fixture又证明旧 fingerprint 保存的是 SQLite 原始 TEXT 字节的 hex，而当前 canonical reader 使用 TEXT 值本身。第一次修复还被独立复审构造出真实 collision RED：旧 TEXT `000…02c` 的错误 BLOB 猜测会占用合法 `X'3030…3263'` BLOB UUID 的 canonical ID，导致合法新消息超时被吞。 | `LegacyAliasCandidate` 保存旧 `recordID`、raw UUID storage bytes、group/sender/content。Migration 不再预猜 TEXT/BLOB canonical；先用 `.recordIDs` 从实际 source 读取，并在 open 前后验证 source identity，再以实际 SQLite storage class 解出的唯一 stable UUID、raw bytes 与 recordID 验证候选。验证后才在同一事务绑定 canonical、当前 aliases 和由旧 store 行字段重建的旧 native content alias；任一 exact-ID 冲突会 rollback。全部旧 messageID 验证完才写 migration marker，然后才 safety replay。UUID-less 历史行仍因无 source provenance fail closed、保持 pending。 | 真实 pre-c0 BLOB/TEXT 两类 fixture、首次升级前内容已更新、TEXT/BLOB canonical collision、UUID-less 跨 inode、byte-identical 跨 inode、同 row 多 fingerprint、exact alias conflict、分页 replay 与四类 source atomic-replace focused 测试全部 PASS；listener full `32/32` PASS。独立第二轮终审确认 speculative collision 已关闭且无 blocker。 |
| Important 2：native 同 UUID 原地更新贯穿 monitor/store | RED 中 recent sweep 已看到新 record fingerprint，但 `emitIfNew` 又按 canonical event ID 抑制事件；即使强制发出，`MessageStore.insertOne` 对同 ID 直接返回 `.existing`，库中仍是旧 sender/content/type/time。 | Recent sweep 在 record fingerprint 首次出现后走 recovered-update 投递，仍记住 canonical ID；相同 fingerprint 不重复恢复。`MessageStore` 对已有 ID 执行受限 UPDATE：只允许同 group 且 incoming `observed_at` 不旧于存量，更新 sender 两字段、content、type、observed time、source sequence、attachments/count、confidence、self flag，并递增 `record_version`；保留 storage ID、insertedAt、group，conversation 只推进时间、不增加 message count。 | `WxFomoSelfTest` 新增真实 `FakeNotificationReader → WeChatNotificationMonitor → MessageStore` 契约：先等 A 落库，再同 UUID 原位替换为 B；断言 2 次 event 共享一个 canonical ID、库内仅 1 行、不可变字段保留、更新字段为 B、recovery=1、无持久化错误；再 B→A，断言旧 fingerprint 不重投且旧时间 guard 不回退。SQL 另以真实 SQLite transaction 验证 `changes=1`、`record_version+1`、message count 不增，相同/旧事件 `changes=0`。 |
| Important 3：默认发现延迟重试与永久错误限流 | 不传 `--database` 的 delayed fixture 起初找不到 source；旧 catch-all 要么直接退出，要么每个 0.05 秒 poll 重新计算候选并 spawn `getconf`。已有 permission/corrupt/incompatible DB 会被同一路径吞成 timeout。 | 启动时只计算并缓存一次 HOME/DARWIN candidates（`getconf` 最多一次）；新增 `databaseMissing` 与带 reason 的永久 `database` 分类。只有所有候选缺失时按 `max(pollInterval, 1s)` 重试；现存 locked 候选交给既有 transient 路径，现存 permission/corrupt/schema incompatible 立即带确定原因失败。 | 默认路径 delayed-create 后成功读取，fake getconf count 精确为 1；permission/corrupt/incompatible 三类均不超时、不吞错且 getconf 各为 1。focused 与 listener full 均 PASS。 |
| Important 4：Trading/Automations 完整 settings dependency | Controlled frontend RED 中 `/api/trades` 或 `/api/automations` 可用而 `/api/settings/status` 不可用时，组合 payload 把它折叠成 `tradingConfigured:false` / “未配置”；刷新错误还丢失旧 dependency 与页面内容并固定频率重试。 | `composeReadOnlyPagePayload` 始终保留 `settingsDependency:{available,reason}`，只有 dependency 真可读时才投影 configured 状态。nested `source_locked` 等 transient reason 进入现有 bounded 2/4/8/16/30 秒退避；暂时失败保留最后一次 primary 与 dependency 状态。Trading/Automations UI 在 settings 不可读时显示 redacted reason，而不是业务“未配置”。 | Node controlled tests 覆盖两页的 available/reason、暂时失败旧状态保留与退避。fresh localhost 浏览器又用“primary schema 可读 + configuration 缺失”真实响应验证两页均显示“数据源尚未生成”，同时主列表仍可读；console error 为 0。 |
| Important 5：所有 requestJson 默认 timeout | Never-resolving fetch RED 证明 bootstrap、messages 与 workspace endpoints 可让 login button、loading 或 polling 永久悬挂；没有 `AbortController` 的 Node 14/旧浏览器路径更无退出通道。 | `requestJson` 对所有调用统一使用有限默认 5000ms；有 `AbortController` 时 abort 并规范成 `request_timeout`，无该 API 时用清理后的 `Promise.race` timeout。调用方 `finally` 恢复 login/loading 状态，失败走既有 retry/backoff。 | Node 测试覆盖 bootstrap、messages、每个 workspace endpoint，分别在有/无 `AbortController` 下让 fetch 永不 resolve；全部按时进入 catch、释放状态并允许下一次请求。frontend full PASS，production/test 7 个 `.mjs` 全部 `node --check`。 |
| Important 6：notification DB 与 hardlink 静态隔离 | 真实 HTTP RED 把 notification/message/workspace/config/group/token/TLS key 逐个 hardlink 到 allowlisted `/app.mjs`，均返回 200；单链接 notification SQLite 直接放在 allowlisted path 也返回 200。CLI 不认识/不传 `--notification-database`，也只做路径层判断，外部敏感文件 hardlink 到静态资产可绕过。 | Server 的 static open 使用 `lstat → O_NOFOLLOW open → fstat`，要求同 inode、普通文件且 `st_nlink == 1`；响应时再把 opened asset inode 与 notification/message/workspace/config/group/token/TLS key 全部比较。CLI 新增 notification path，并对每个敏感 target 同 exact `PUBLIC_ASSETS` 做 inode 比较，同时保留 lexical/realpath/normcase/ancestor 检查。Launcher 将其实际 Notification source 明确传给 server。 | Python full 中真实 HTTP/CLI 覆盖七类 hardlink、单链接 notification DB、allowlisted symlink、direct/case/symlink/inode overlap。额外 fresh focused 4 tests `Ran 4 … OK`；launcher command snapshot 断言 `--notification-database`。 |
| Minor：README UUID-less 描述 | 文档仍声称 UUID-less ID 只由 record number 决定，和生产 source-bound seed 不一致。 | README 改为“Notification source identity + record ID”；同时说明不同 DB 的相同 rowID 不合并。 | README 两处文本审计与 listener 的 byte-identical cross-source fixture一致。 |

## 系统化调试与复审补充

1. 初版 TEXT/BLOB migration 为兼容两种 SQLite storage class 预绑定两个 canonical 猜测。独立审计用真实 TEXT 与合法 BLOB bytes 碰撞证明会吞事件；修复没有放宽断言，而是删除 speculative binding，将 source-verified migration 移到 safety replay 前。修复后原 collision fixture 与 13 项迁移/race focused 检查均通过。
2. Launcher fresh full 首次出现一次 `web server did not restart within 3s`。没有直接重跑掩盖：用逐行 timing trace 重跑完整未修改套件，确认 30 秒连续 authenticated health window 后 backoff 已重置，server 在 1.257 秒出现（契约为 0.7–3 秒），整套 PASS；未修改生产逻辑或放宽时间断言。
3. pre-c0 standalone schema只保留解析后的 `group_name/sender_display_name/content`，不保留原 notification title/subtitle/body 或附件 URL，因此任意旧 raw-layout hash 在信息论上无法完全反演。本实现只从旧 store 确实保留的字段重建兼容 native alias，不使用已更新 source 内容，也不猜测无 provenance UUID-less alias；verified canonical alias负责防重与数据保持。

## 最终 fresh 验证

工具链：macOS 13.7.8；Python 3.7.3；Apple Swift 5.2.4；Node 14.18.0。

| 范围 | 命令 / 结果 |
|---|---|
| diff | `git diff --check 8674202325a7f65ffd5801d14ec8301a1842ad31..HEAD` → exit 0。 |
| standalone listener | `zsh scripts/test-wecom-group-listener.sh` → `32/32` 场景 PASS，exit 0。 |
| migration focused | 真实 pre-c0 TEXT/BLOB、storage collision、default delayed 与三类 permanent discovery 独立重跑均 PASS。 |
| Python full | `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest scripts.test_wxfomo_lan_server` → `Ran 82 tests in 43.955s`，OK。 |
| static security focused | notification DB、七类 sensitive hardlink、allowlisted symlink、CLI sensitive inode 共 4 tests，OK。 |
| native focused | policy 1、production mapper 1、payload/reader 3、probe 15，全部 PASS。 |
| Swift 5.2 | listener 与 notification probe production scripts 的 `/usr/bin/swiftc -swift-version 5 -typecheck … -lsqlite3` 均 exit 0；8 个相关 shell scripts `zsh -n` exit 0。 |
| frontend | `node scripts/test-wxfomo-lan-frontend.mjs` → `PASS: wxFomo LAN frontend state`；7 个 production/test `.mjs` 全部 `node --check` exit 0。 |
| launcher focused | `PYTHONDONTWRITEBYTECODE=1 zsh scripts/test-wxfomo-lan-launcher-readiness.sh all` → foreign-PID 与 missing-index 均 PASS。 |
| launcher full | 未修改套件的完整 timing trace 重跑 → `PASS: wxFomo LAN launcher supervision`；1/2/4/8 秒退避、30 秒健康 reset、paused child cleanup 和 listener failure cleanup 均执行。 |
| 浏览器 fixture | 独立 `127.0.0.1` 合成 Notification/message/workspace DB、token、port：token 登录、1 条 sentinel 消息与 count、旧 heartbeat 显示“监听器未活动”、复制反馈“已复制”、Trading/Automations settings dependency reason、console errors=0。tab、server session 与 fixture 均精确清理。 |
| artifacts | repo 内无临时 DB/token/log/pycache；测试 fixture、测试 tab 与测试 PID 已清理。 |

## 本 round 2 提交

- `122f571` `fix: preserve composite LAN dependency health`
- `178cb4d` `fix: block sensitive hardlinks from LAN assets`
- `570141b` `fix: validate launcher notification source path`
- `af0df62` `fix: complete notification upgrade and update contracts`
- 本报告由后续 documentation commit 纳入。

完整交付范围从 `8674202325a7f65ffd5801d14ec8301a1842ad31` 到本报告提交；round 2 增量范围从 `c465001bdfda64d3c69a0c5a7a880418f7d18daf` 之后开始。

## 剩余疑虑与环境限制

- 没有已知 unresolved 生产缺陷。
- 本机 `swift build` 在 SwiftPM 预检阶段失败：`xcrun --sdk macosx --find xctest` 找不到 `xctest`。当前 package tools version 为 5.10，而唯一系统 Swift 为 5.2.4；它无法解析/执行 actor/async 的 `WxFomoSelfTest`。失败发生在测试工具发现阶段，不是本轮 assertion failure。可执行范围内已完成 Swift 5.2 standalone production typecheck/full suite、native mapper/reader/probe tests，以及 MessageStore UPDATE 的真实 SQLite contract 验证；完整 `swift run WxFomoSelfTest` 仍需已有 Xcode 15+/Swift 5.10+ 的 CI 或 Mac。

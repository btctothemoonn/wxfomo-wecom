# LAN 只读工作台范围复审跟进修复报告

日期：2026-09-03

分支：`codex/wecom-notification-probe`

复核基线：`8674202325a7f65ffd5801d14ec8301a1842ad31`

复审输入：`final-review-followup.md`（6 项 Important、1 项 Minor）

## 结论

范围复审提出的 6 项 Important 和 1 项 Minor 均已用失败测试、根因证据和最小修复关闭。原有安全边界没有放宽：字段 projector、公开 host 授权、私有 token path、Bearer 认证、非 GET/HEAD `405`、opaque cursor、只读 SQLite 和 exact public-asset allowlist 仍然成立。

本修复波只使用隔离临时 Notification/message/workspace 数据库、token、端口、配置和合成消息。没有向企业微信发送或重放通知，没有读取真实通知内容，也没有停止、发信号或改写真实 launcher session 9829、PID 71119 及其子进程。

## 逐项 resolution 与 TDD 证据

| 项目 | RED / 根因 | 最小修复 | GREEN 证据 |
|---|---|---|---|
| Important 1：真实 pre-canonical store 升级与 alias | 测试直接用 `git show c0c20ed^:scripts/wecom-group-listener.swift` 生成旧 store；升级后旧行会被 canonical ID 再插入，production legacy native alert ID 也不能定位旧 LAN 行。另一组 RED 证明若把无 source provenance 的 UUID-less fingerprint 当 alias，两个 inode 中 byte-identical 的同 rowID 会被错误吞并。 | 新增 `message_event_aliases` 和有完成标记的安全 replay migration。含 UUID 的旧行从 Notification UUID 恢复 canonical ID，并把 canonical/legacy-native ID 映射到原 LAN row；写入先按 exact event ID/alias 解析，再更新同一行。UUID-less 旧 fingerprint 因没有来源身份而严格 fail closed：不猜测 alias，migration 保持 pending 并发出 warning；新消息只使用 source-bound canonical ID。alias 冲突按 production exact-first 查询，冲突不写且不误标完成；超过 500 个 rowID 分块处理。 | 真实旧脚本 fixture 升级后仍为 1 行，canonical 与 legacy-native 两个 alias 都定位旧行，内容更新不重复；byte-identical A/B 两个 inode 保留 2 个 source-bound 行、alias 数为 0、migration pending；exact-ID conflict、多 fingerprint 同 rowID、>500 replay 均通过。 |
| Important 2：运行中 source replacement 与跨源 seed | RED 在 listener 已运行时原子替换 source：旧实现继续报告 active，沿用旧 cursor，或把另一个 DB 的同 rowID 合并。reader 在 validation→fetch / fetch→return 之间换 inode 时还能返回旧 batch。补充 RED 精确复现 initial validation confirmation 时换源直接退出：`通知数据库在验证期间已更改`。 | standalone 每轮验证 source identity，在 fetch 前后比对；缺失/未就绪时把 heartbeat 置 0，恢复或 inode 改变时 rebind、原子重置 cursor 并 safety replay。source-change 使用专门错误类别，retry helper 只重试该类别，不吞永久 schema 错误。UUID-less canonical seed 包含 standalone/native 都能取得的 source identity。native reader 同样在 batch 前后验证 identity，monitor 在 identity 改变时清空 cursor，旧 source batch 被丢弃。 | 无重启 live replace、missing→inactive→rebind、相同 rowID 跨 source、validation→fetch、fetch→return、startup bind 以及 initial validation confirmation 原子竞态均通过；native reader identity/replacement focused tests 通过。 |
| Important 3：默认 auto-discovery 延迟重试 | RED fixture 不传 `--database`，默认候选目录最初不存在或只有不完整 schema；旧实现启动即退出。稳定 inode 上的永久坏 schema 还存在被宽泛 retry 吞掉的风险。 | 默认发现与显式 source 共用“暂未可用 / source-changed / 永久错误”的明确分类；候选缺失或 schema 尚未出现时按 poll interval 重试，发现有效 source 后才 ready；永久坏库仍立即给出确定错误。 | delayed-source 场景省略 `--database`，启动后再创建默认路径/schema，listener 成功发现并处理；focused permanent-error 场景仍 fail fast。 |
| Important 4：完整 reason、旧数据保留与真实 schema | RED 分别锁住 message/workspace DB、删实际查询列、制造 malformed DB、不可读文件/祖先目录与坏 configuration。旧代码将原因折叠，`/api/settings/status` 会在 workspace 不可用时返回默认 available，前端会清空已显示 groups/counts/messages/只读页并固定频率重试。 | message/workspace/configuration 统一输出 redacted `source_locked`、`schema_incompatible`、`source_permission_denied`、`source_corrupt`、`source_unavailable`/`source_error`；同时检查直接路径、symlink/alias 和所有祖先权限。settings availability 同 workspace/provider/trading 实际来源一致。workspace health 验证当前 native endpoints 实际读取的全部 table/column，market/priority 仍是明确 optional unavailable。前端在 message/network/transient lock 时保留旧 groups/counts/messages/page payload，listener freshness 降为 unknown，并按 2/4/8/16/30 秒退避；永久错误显示新 reason。 | Python lock/settings/missing-column/schema/corrupt/mode-000/inaccessible-ancestor 测试通过；Node controlled state tests 证明旧内容保留、reason 文案完整、退避封顶且永久错误不伪装成旧成功。所有 response reason 都不含本地路径。 |
| Important 5：本地 heartbeat TTL、visibility 与 fetch timeout | RED controlled clock 证明后端给过一次 active 后页面可永久显示 active；missing/malformed/stale/future `heartbeatAt` 仍可能被信任。tab 恢复可先画旧 active；never-resolving `fetch` 会永久悬挂 bootstrap。 | 单一 `verifiedListenerState` 在所有页面/diagnostics 强制 5 秒 TTL 和 1 秒 future tolerance；没有可解析 heartbeat 时不能 active。根据剩余 TTL 安排本地一次性失效 timer。visibility 恢复先同步把 freshness 置 unknown 并 render，再立即刷新。API 使用有界 timeout；有 `AbortController` 时 abort，无该 API 的 Node 14/旧环境用 `Promise.race` 得到同一 `request_timeout`。 | controlled clock 验证 TTL 到点无需网络即变 inactive，missing/malformed/future 均不 active；visibility 恢复在 fetch 完成前已 invalidated；never-resolving request 在有/无 AbortController 两条路径均按时 reject，后续 retry 可继续。 |
| Important 6：exact 静态 allowlist 与敏感路径重叠 | RED 在 static root 放任意 regular file、把 allowlisted asset 换为 symlink，并分别把 message/workspace/config/group/token/TLS key 指到静态目录；旧 server 能暴露文件或 CLI 未拒绝。后续 RED 证明 macOS case alias、symlink/inode ancestor 可绕过纯 lexical 检查。 | 静态路由只映射固定 `PUBLIC_ASSETS`，对目标执行 `lstat`/no-follow open/`fstat` identity 验证；不对目录做通用文件拼接。CLI 在读取 token/key/DB/config 前，使用 lexical、realpath、`normcase` 与已有 ancestor `(st_dev, st_ino)` 检查，任何敏感路径落在/别名到 static root 都拒绝。 | 真实 unauthenticated HTTP 对任意 regular file 和每个敏感自定义文件均返回 404/不泄露 sentinel；allowlisted symlink 也不跟随。CLI 对直接、case alias、symlink/inode ancestor overlap 全部拒绝。 |
| Minor：极端 timestamp | RED 把有限 REAL `1e300` 写入 `started_at` 或 `heartbeat_at`；旧 `_format_observed_at` 可能抛出并断开 `/api/bootstrap`。 | 格式化前验证有限值及平台 datetime 可表示范围；任一 listener 时间不可表示时整个 listener state 降为 unknown，不返回部分可信 active 状态。 | 两列各自使用 `1e300` 的真实 SQLite bootstrap 请求都返回 200、message source 仍可读、listener unknown，且不暴露错误路径。 |

## 额外审计修复

1. 初次 source validation 的“最后一次 identity 确认”竞态起初不属于 retryable branch。新增专用 `notificationSourceChanged` 分类后只重试 inode change；稳定 inode 的永久 DB 错误仍不会被无限吞掉。
2. UUID-less pre-canonical 数据没有历史 source identity。这一事实使跨 inode alias 在技术上不可安全推导；最终契约是 fail closed 并保持 migration pending，而不是用相同 rowID、payload、时间或旧 fingerprint 猜测。测试特意复制完全相同 record bytes，排除了“手工不同 ID fixture”的假阳性。
3. native self-test 中两条本应成功的 UUID-less fixture 原先遗漏 `sourceIdentity`；已补真实 source identity，缺 source 的负向 fixture仍保留。
4. Python source 分类增加 inaccessible ancestor/alias 检查；static-root overlap 增加 macOS case folding 与 inode ancestry；前端 diagnostics 与主状态共享同一 freshness 判定，避免跨页漂移。
5. launcher full-suite 暴露测试夹具竞态：`wait_for_restarted_server` 只证明新 PID 存在，随后立即开始“连续健康”窗口会偶发 `ConnectionRefusedError`。测试现在先等待 authenticated `/api/bootstrap` ready，再启动原样的 32–35 秒连续健康断言；1/2/4/8 秒重启下限、30 秒健康 reset 和 API 断言均未放宽。

## 最终 fresh 验证

工具链：macOS 13.7.8；Python 3.7.3；Apple Swift 5.2.4；Node 14.18.0。

| 范围 | 命令 / 结果 |
|---|---|
| diff | `git diff --check 8674202325a7f65ffd5801d14ec8301a1842ad31..HEAD` → exit 0。 |
| Python full | `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest scripts.test_wxfomo_lan_server` → 78 tests，OK。 |
| standalone listener | `zsh scripts/test-wecom-group-listener.sh` → 30/30 场景 PASS，exit 0。 |
| native focused | policy 1、production mapper 1、payload/reader 3、probe 15，加 listener 30，合计 50 PASS、0 FAIL。 |
| Swift 5.2 | listener 与 notification probe 两个 production script 的 `/usr/bin/swiftc -swift-version 5 -typecheck ... -lsqlite3` 均 exit 0；5 个相关 shell script 的 `zsh -n` 均 exit 0。 |
| frontend | `node scripts/test-wxfomo-lan-frontend.mjs` → `PASS: wxFomo LAN frontend state`；production/test `.mjs` 全部 `node --check` exit 0。 |
| launcher focused | `PYTHONDONTWRITEBYTECODE=1 zsh scripts/test-wxfomo-lan-launcher-readiness.sh all` → foreign-PID 与 missing-index 均 PASS。 |
| launcher full | `PYTHONDONTWRITEBYTECODE=1 zsh scripts/test-wxfomo-lan-launcher.sh` → `PASS: wxFomo LAN launcher supervision`。 |
| 浏览器 fixture | 独立 localhost 合成 DB/token/port：登录、1 条合成群消息/计数、heartbeat=0 显示“监听器未活动”、复制反馈、priority canonical unavailable 均符合；console errors 为空。浏览器 client 拒绝直接导航可疑 URL，因此 exact unauth static/API 401/404 由真实 Python HTTP tests 覆盖。浏览器 tab、server PID 与临时目录已精确清理。 |
| artifacts | repo 内没有临时 DB/token/log/pycache；测试 fixture 与测试 PID 均已清理。 |

## 本 follow-up 提交

- `4d62013` `fix: harden LAN source failure boundaries`
- `19fe435` `fix: retain LAN state through liveness failures`
- `d1fb31e` `test: prove sensitive LAN files stay private`
- `82577af` `fix: close LAN filesystem alias gaps`
- `4499850` `fix: expire stale listener presentation locally`
- `fba23e7` `fix: preserve notification identity across source changes`
- `e546a7b` `fix: retry notification source validation races`
- `869bc8e` `test: await launcher readiness before health window`
- 本报告由后续 documentation commit 纳入。

完整交付范围从 `8674202325a7f65ffd5801d14ec8301a1842ad31` 到本报告提交。

## 剩余疑虑与环境限制

- 没有已知 unresolved 生产缺陷。
- `swift build`/`swift run WxFomoSelfTest` 在此机的 Command Line Tools 环境于 `xcrun --sdk macosx --find xctest` 失败（utility not found），且 package tools version 为 5.10、系统 Swift 为 5.2.4；失败发生在 package 测试工具发现阶段，不是本次断言或 production source 编译失败。本次涉及的 Swift production paths 已由 Swift 5.2.4 listener full suite、focused native executables 和直接 typecheck 实际编译验证。
- market/priority 没有加入 workspace 必需 schema：当前 native store 不创建相应数据源，现行契约要求它们 canonical unavailable。若强制作为 workspace health 必需项，会把当前正常 workspace 错误标为 `schema_incompatible`。

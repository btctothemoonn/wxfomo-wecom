# LAN 只读工作台最终修复报告

日期：2026-09-03

分支：`codex/wecom-notification-probe`

复核基线：`8674202325a7f65ffd5801d14ec8301a1842ad31`

## 结论

`final-review-findings.md` 中的 15 项 Important 和 3 项 Minor 均已关闭。修复波保留了原有只读边界：API 字段投影、公开 HTTPS host allowlist、私有 token path、Bearer 认证、非 GET/HEAD `405`、opaque cursors 均未放宽。

本次不读取真实 Notification Center 数据，不重放或伪造真实企业微信通知，不触碰真实 launcher session 9829 / PID 71119 及其子进程。listener、launcher、HTTP 和浏览器验证均使用独立临时数据库、token、端口和配置，并在结束后停止精确 PID、清理 fixture。

## 15 项 Important 的 resolution 与 TDD 证据

| # | RED / 根因 | 最小修复 | GREEN 证据 |
|---|---|---|---|
| 1 | 旧 CLI 只拒绝未授权的 `0.0.0.0`；空 host、私网 IP 和解析到非回环的 hostname 可绕过。 | 用 IPv4 `getaddrinfo` 只解析一次；任一候选地址非 loopback 都要求 `--allow-lan`，并绑定已授权的 numeric address，避免二次 DNS 解析。 | `test_every_non_loopback_binding_requires_explicit_opt_in` 和 hostname resolved-bind 测试通过。 |
| 2 | unsafe config/store fixture 证明旧 listener 会修改现有目录/文件 mode，并存在 symlink/hardlink 跟随边界。 | 用 `lstat` + `openat/fstatat` + `O_NOFOLLOW` 验证直接父目录为当前 uid 所有的 `0700` 真实目录；文件必须是 owner、single-link、private regular file。新建配置采用同目录 `0600` 临时文件 + `fsync` + atomic `renameat`；SQLite 使用 no-follow flag。不再 chmod 任意现有目标。 | listener safe-path matrix 拒绝 shared parent、symlink config/store、hardlink store 和 special file，并断言 mode/目标未被改动。 |
| 3 | RED 分别复现：写库锁定时消息丢失；写失败前 cursor 已前移；重启跳过未提交通知；启动阶段 4s lock 直接退出；换源后旧高水位跳过新源低序号；旧 listener 可继续心跳。 | `messages` 写入与 `(timestamp, recordID)` checkpoint 放在同一 `BEGIN IMMEDIATE` 事务；BUSY/LOCKED 有界重试；`listener_state` 增加 cursor-pair invariant、`source_key` 和 `instance_id`。换源原子清空 checkpoint 并 safety-replay 最近 500 条；写入/心跳都按 instance ownership fencing。 | 19 场景 listener suite 中的 persistence-lock、startup-lock、source reset、instance fence、uncheckpointed restart recovery 全部通过。 |
| 4 | 旧 event ID 包含 title/subtitle/body/attachment，同一通知行的内容或时间更新产生新 ID 和重复消息。 | native 和 standalone 都只对 `"notification|" + (uuid || rowID)` 做同一 FNV-1a stable hash；时间/内容只用于发现 update，不进入对外 ID。 | notification update 测试只保留 1 条 message，但 durable checkpoint 前移；production native mapper 与 standalone 对 BLOB seed `000000000000002c` 均产生 `ed90e2ba579eb7e5`。 |
| 5 | native mapper 丢失 `req.usda.ct`，标题恰好等于配置群时，直聊/缺失 ct 可被当成群聊。 | `NotificationRecord` 增加 `conversationType`；decoder 从 keyed archive 解出 `ct`；mapper fail closed，仅 `ct == 1` 可通过。 | payload decoder 的 ct=1/ct=0/missing/malformed fixtures，以及 mapper 的 direct/missing-ct tests 全部通过。 |
| 6 | 旧 normalization 折叠大小写/变音并移除内部空白或不可见字符，造成非 exact group 命中。 | 统一为仅 outer trim + Unicode NFC；保留 case、diacritic、内部空格和 zero-width 差异；配置以同一 canonical key 去重。 | native policy 和 listener 的 case/diacritic/internal-space/zero-width rejection + decomposed/composed NFC match tests 通过。 |
| 7 | 旧 listener 在源 DB/schema 初始缺失时退出；旧 launcher 只看 HTTP 可达；前端首次 bootstrap 失败后可整个 session 空白。后续 RED 还证明旧 Web PID 占端口时，新 launcher 会误命中旧 server；缺 `index.html` 也会误报 ready。 | listener 对延迟源/schema 与临时 lock 持续重试。launcher 为每次整体启动生成 listener UUID，只在当前 Web 子 PID 实际 owns 配置端口、authenticated bootstrap 回报同一 UUID/新鲜 active 状态，且 authenticated `/` 返回 200 时 ready。前端对 bootstrap/message 用 2/4/8/16/30s 有界退避并保留内容。 | delayed-source listener test、launcher supervision full suite，以及 deterministic foreign-PID/missing-index readiness fixtures 均通过。 |
| 8 | 旧 workspace 错误均折叠为 unavailable/error；诊断无法区分 lock/schema/permission/corrupt；页面每 2s 固定重试并清空旧数据。追加 RED：DB 文件本身 mode `000` 被误报 unavailable；缺失父目录又不应误报 permission。 | 根据 SQLite 错误 + 实际 path access 分类 `source_locked` / `schema_incompatible` / `source_permission_denied` / `source_corrupt` / unavailable；diagnostics 验证当前 native core schema。仅 transient lock 保留旧 workspace payload 并有界退避；网络/message 失败也保留可见内容。 | lock/schema/corrupt/denied-directory/mode-000/missing-parent 后端测试与前端 retention/backoff/reason-label tests 通过。 |
| 9 | 旧 projector 的 identifier regex 丢弃 colon event IDs；native ID 与 LAN listener ID 算法不同；手写相同 fixture 无法证明真实跨层一致。 | 新 `_event_id` allowlist 显式接受 canonical/legacy colon ID；native 和 listener 共用同一 seed/hash 契约；listener test 直接编译运行 production `NotificationMapper` 取得期望 ID。 | real native mapper vs real standalone mapper 跨层比对通过；colon alert ID 可投影并 exact lookup 超出最新页的源消息。 |
| 10 | 旧 display punctuation allowlist 会将 `·`、`…`、中文 `：`、newline、`/` 和 emoji 静默变为 null。追加 RED：全放行 `Cf` 又允许 U+202E bidi override。 | model/field allowlist 仍是主边界；display text 只限长度并拒绝 `Cc`/`Cs`，`Cf` 仅保留语言/emoji 所需 U+200C/U+200D，其他 bidi/format controls 拒绝。不再枚举普通标点。 | 正常中英文标点、slash、newline、family emoji ZWJ 保留；U+202E 变为 null；超长/控制字符仍被拒绝。 |
| 11 | 原始私网 HTTP 下 Clipboard API 不可用；Meme/trading/alert 页未显示地址或可靠复制入口。 | 新 `copyText` 优先 secure Clipboard API，失败/非 secure context 时用隐藏 textarea + `execCommand("copy")`，最后显式 prompt 手动复制；页面可见渲染 address/tokenAddress 和 copy controls。 | Node14 的 `isSecureContext:false` execCommand/manual fallback 测试，以及 alerts/Meme/trading 地址渲染与复制测试通过；浏览器隔离 fixture 的消息复制显示“已复制”。 |
| 12 | 旧 auto-connect 中的 old-token 401 可在用户提交新 token 后清除新 session，旧请求也可覆盖新登录 UI。追加 RED：401 登出后 `loading` 保留为 true，重连不再加载。 | API 401 只在 sessionStorage 仍等于该 request 实际使用的 token 时清除；`connectionGeneration`/`requestGeneration` 拒绝陈旧完成；`showLogin` 重置 message loading/poll/cursors/pending state。 | old 401 不清新 token、current 401 清除当前 token、stale generation 无法更新 UI，401 后重连可替换加载，Node14 全通过。 |
| 13 | 旧 Web 子进程重启会重读已编辑 group-config，与未重启 listener 的旧配置产生分裂。 | listener 将本次启动去重群快照写入 `listener_state.group_names_json`；server/browser 优先读该快照，仅老库无 snapshot 时才回退配置文件。README 明确修改配置/代码必须停止并重启整个 launcher。 | launcher test 在运行中改配置；4 次 Web-only restart 均保留旧 snapshot，整个 launcher 重启后才采用新群，通过。 |
| 14 | 旧 UI 把“DB 可读”等同于“listener 活动”。追加 RED：上一实例的新鲜 heartbeat 可使 launcher 过早 ready；diagnostics 页的 active snapshot 不随 2s bootstrap 变为 inactive/unknown。 | listener 每秒更新心跳，bootstrap 用 5s TTL，超前 >1s 也不 active；回报 instance ID/startedAt。launcher ready 绑定当前 instance。前端 bootstrap 失败只将 freshness 失效为 unknown；diagnostics 渲染时用最新 bootstrap 覆盖陈旧 listener/message-source claim。 | heartbeat fresh/stale/future/malformed/missing tests；old-instance launcher ordering/UUID tests；diagnostics active→inactive 和 unavailable→unknown tests 通过。 |
| 15 | “重点捕捉”永久 disabled，没有只读 route/契约。 | 新增 authenticated GET `/api/priority`；当前 native 没有该数据源时返回 canonical `{available:false, reason:"source_unavailable", items:[]}`；sidebar route 可进入、无 write action。 | backend exact-payload test、frontend route/canonical unavailable test、浏览器 `#priority` DOM 验证通过。 |

## 3 项 Minor

| Minor | RED / 修复 | GREEN |
|---|---|---|
| decoded NUL path | `%00` 解码后原先会继续进入 router/filesystem。现在在 normalize/文件系统前统一返回 redacted `400 {"error":"invalid_path"}`。 | static/API NUL 测试断言 400，无 traceback/本地 path 泄露。 |
| token/Windows 文档 | 旧文案暗示 launcher 打印 token，且暗示 Mac `pbcopy` 能直接填充 Windows 剪贴板。现在 login/README 明确 launcher 只打印 token-file path，`pbcopy` 仅是 Mac 剪贴板；提供团队批准的跨设备密码管理器/E2E 通道/手工转录步骤，并明确禁止 URL、邮件、群聊、截图、Git 和终端日志。 | frontend copy/text tests、launcher 日志 token/body 负断言、浏览器登录页 DOM 验证通过。 |
| Python cache hygiene | `.gitignore` 缺少 cache 规则，两个生成目录存在。新增 `__pycache__/` 和 `*.py[cod]`；在确认只包含 CPython 3.7 `.pyc` 后，精确删除 `scripts/__pycache__` 和 `scripts/wxfomo_lan/__pycache__`。 | `find scripts -type d -name __pycache__` 无输出；后续 Python 命令均使用 `PYTHONDONTWRITEBYTECODE=1`。 |

## 最终 fresh 验证

| 范围 | 命令 / 结果 |
|---|---|
| 工具链 | macOS 13；`Python 3.7.3`；`Apple Swift 5.2.4`；`Node v14.18.0`。 |
| diff | `git diff --check` → exit 0。 |
| Python full | `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts/test_wxfomo_lan_server.py` → `Ran 65 tests ... OK`。 |
| standalone listener | `zsh scripts/test-wecom-group-listener.sh` → 19/19 场景 PASS，exit 0。 |
| native focused | `zsh scripts/test-wecom-notification-policy.sh` → PASS；`zsh scripts/test-wecom-notification-mapper.sh` → PASS；`zsh scripts/test-wecom-notification-payload-decoder.sh` → PASS。 |
| Swift 5.2 compile | `/usr/bin/swiftc -swift-version 5 -typecheck scripts/wecom-group-listener.swift -lsqlite3` → exit 0。 |
| frontend | `node scripts/test-wxfomo-lan-frontend.mjs` → `PASS: wxFomo LAN frontend state`；所有 `.mjs` `node --check` → exit 0。 |
| launcher focused | `scripts/test-wxfomo-lan-launcher-readiness.sh all` → foreign-PID 和 missing-index 两场景 PASS。 |
| launcher full | `PYTHONDONTWRITEBYTECODE=1 scripts/test-wxfomo-lan-launcher.sh` → `PASS: wxFomo LAN launcher supervision`。包含配置快照、authenticated current-instance readiness、1/2/4/8s restart backoff、30s healthy reset、暂停子进程清理和 listener-failure 路径。 |
| 浏览器 fixture | 隔离 localhost token/DB/port 上验证登录、1 条假消息与群计数、listener inactive 真实标签、复制反馈、`#priority` canonical unavailable 和 console 0 warning/error。fixture/PID 已精确清理。 |
| artifacts | 无临时 DB/token/log/pycache 出现在 `git status`。 |

## 代码提交

- `c0c20ed` `fix: harden notification listener contracts`
- `a5773c8` `fix: make LAN data-source health truthful`
- `765176c` `fix: preserve read-only workbench state`
- `bfb3ef9` `fix: authenticate launcher readiness lifecycle`
- 本报告由紧随其后的文档提交纳入分支。

## 精确技术裁定与剩余疑虑

1. **不将 `market_snapshots` 加入 workspace health 必需 schema**：当前 production `WorkspaceStore` 并不创建 market table，任务 4 契约也将 market 列为当前未提供的 canonical unavailable 数据源。将不存在的 table 强制列为健康必需项，会把每个当前正常 workspace 误报为 `schema_incompatible`。因此本次仅验证当前 native core tables/columns；`/api/market` 与 `/api/priority` 保持 canonical unavailable。
2. **SwiftPM 全包验证的本机限制**：`swift run WxFomoSelfTest` 在本机于 `xcrun --sdk macosx --find xctest` 失败（Command Line Tools 中没有 `xctest`），且 `Package.swift` 声明 tools 5.10，本机编译器为 5.2.4。这不是本次代码回归；本次改动的 production Swift 文件已由 Swift 5.2.4 focused executable tests 和 listener typecheck 实际编译。
3. **原始私网 HTTP 的浏览器环境限制**：in-app browser 可完整访问 localhost fixture，但访问本机 `192.168.3.209` 隔离 fixture 在 30s 内未建立连接。该 fixture 已停止并清理。原始 HTTP 的关键行为不依赖该环境假绿：Node14 直接以 `isSecureContext:false` 驱动 production `copyText`，分别验证 `execCommand` 成功和 prompt 手动回退。

除上述本机验证限制外，**无已知 unresolved 生产缺陷**。

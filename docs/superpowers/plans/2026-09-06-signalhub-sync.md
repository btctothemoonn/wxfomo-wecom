# Signal 完整总结同步与实时 CA Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 本项目按用户节省额度的要求优先同一任务内分批执行，避免逐任务反复派发评审。

**Goal:** Mac 独立可靠地同步完整总结，并把符合已确认规则的跨群 CA 及时送到 Signal 登录后页面。

**Architecture:** 只读报告导出与增量 CA 检测使用各自游标，共用独立 SQLite outbox、HMAC 和单请求发送器。报告导出不占用 CA 定时循环，不调用 AI。Signal 负责接收与展示，不在本计划中修改其仓库或部署。

**Tech Stack:** Python 3.7 标准库、SQLite、现有纯 JS 前端测试工具；不新增第三方依赖，不修改 Swift 监听器。

**Spec:** [已确认设计](../specs/2026-09-06-signalhub-sync-design.md)，全文是本计划的规范依据；执行前同时读取 AGENTS.md。源码基线为 `5233228`，设计提交 `95598b1`，后续文档修订以实际 HEAD 为准。

## Global Constraints

- 不改企业微信监听、已配置群、relay 归属边界、2h/6h/24h 调度、MiniMax 配置或源数据库 schema。
- 群名、昵称及来源元数据只在用户本人授权的登录页面展示；sources=[]，不上传原始聊天、附件、通讯录或运行文件。凭证绝不进入 Git、日志、正文或浏览器。
- 传输 schemaVersion=2；未知字段拒绝；完整 briefing.version=2 不降级为三条速读。请求上限 262144 字节，全部时间 UTC ISO；显示 Asia/Shanghai。
- 报告每 60 秒最多发现 10 份。CA 每 10 秒增量读取，滚动 3600 秒，至少 2 个不同群，冷却 1800 秒；页面提醒区每 15 秒刷新。
- CA 每轮最多 500 行或 2 秒，先达限保存真实进度；约 60 秒可见是正常联网、无积压、页面可见下的实测目标，不是从真实发言时间起算的保证。
- 一次一个网络请求、超时 10 秒；所有类型共用全局认证暂停和限流。新鲜 CA 优先，最多连续 3 条后给报告机会。
- 待确认与隔离 payload 合计最多 1000 条或 128 MiB；滚动索引另外最多 32 MiB。不能删除未确认 payload 腾空间。
- 私密目录 0700、文件 0600，拒绝不安全所有权/符号链接。源库只读、同步库独立。默认不安装或启用 LaunchAgent。
- 首次启用同时记录结果与消息水位，只接续新数据；不默认回填、不付费重跑。停止同步不得停止原监听或 AI。
- 每个任务先写失败测试、确认失败原因，再实现、跑对应测试。全套 Python 测试只在最终集成边界跑一次；本文件中的命令尚未执行，不代表测试通过。

## 0. 对接前置条件与分期

本次只交付计划。刚核对 Signal main 的交接文档，其 blob 仍为 `d9f5de7ba2963498b03e34be1423c050a3a6a553`，与已审阅的 55dfa50 v1 相同。**在 Signal 回传 v2 接口确认前，不执行依赖该协议的实现任务，不向生产写入。** 用户已经确认产品参数，不需要再询问同一套规则。

Signal 需确认：完整 briefing/scope/sourceReferences/caCoverage；允许身份但禁止原文；新增 ca_alert、扩展 heartbeat、CA 分页和 active 列表；15 秒可见刷新；过期、catchup、notificationVersion 和首次接收时间语义；所有读接口执行用户级授权。入口路径、HMAC、确认及错误语义沿用 v1。以上变更详见设计第 4–6 节。

收到更新文档 commit 后，只检查上述差异与样例；若改动影响用户已确认的范围，先反馈差异。先完成离线可靠发送，再接总结导出，再接实时 CA，最后验证启动与端到端；各阶段可独立测试和提交，不同时改原工作台。

## 文件与接口地图

| 新文件 | 单一职责 |
| --- | --- |
| `scripts/wxfomo_lan/signal_contract.py` | 严格 v2 白名单、规范化序列化、固定安全错误码 |
| `scripts/wxfomo_lan/signal_transport.py` | 私密配置、签名、无重定向 HTTPS、确认/重试分类 |
| `scripts/wxfomo_lan/signal_outbox.py` | 独立同步库、双水位、固定 payload、事务与确认 |
| `scripts/wxfomo_lan/signal_export.py` | 只读成功结果、完整冻结输入与报告投影 |
| `scripts/wxfomo_lan/signal_ca.py` | CA 增量最小状态、滚动窗口、episode、修订与过期 |
| `scripts/wxfomo_lan/signal_sync.py` | 有界调度、独立发送、心跳、显式 CLI 模式 |
| `scripts/wxfomo-signal-sync.py` | 薄命令行入口，不含业务规则 |
| `scripts/fixtures/signalhub-sync/` | 仅合成的 report/ca_alert/heartbeat/signature 样例 |

对应测试为 `scripts/test_wxfomo_signal_contract.py`、`test_wxfomo_signal_transport.py`、`test_wxfomo_signal_outbox.py`、`test_wxfomo_signal_export.py`、`test_wxfomo_signal_ca.py`、`test_wxfomo_signal_sync.py`。只在最后更新 README 的启动说明；不先创建空模块或重复的大型框架。

## Task 1：冻结协议与离线合成样例

**Files:** Create `scripts/wxfomo_lan/signal_contract.py`、`scripts/fixtures/signalhub-sync/{report,ca_alert,heartbeat,signature}.json`；Test `scripts/test_wxfomo_signal_contract.py`。

**Interfaces:** `encode_payload(value: dict) -> bytes` 严格校验后返回唯一 UTF-8 字节；`validate_payload(value: dict) -> None` 失败抛 `SyncError(code)`，异常字符串仅固定错误码。后续模块只发送 encode_payload 的返回值，不重新序列化。

- [ ] 按两端确认的字段准备四个完整合成 fixture，禁止从真实库复制。report 使用虚构群/昵称、来源元数据与完整 market briefing；ca_alert 使用测试地址且显式标为合成样例文件；signature 使用公开测试密钥与固定时钟。以独立 fixture 提交测试数据，不把密钥例子写进生产默认配置。
- [ ] 先写最小失败测试，再逐个增加未知键、错误版本、sources 非空、元数据含 content、非法引用、大小写、非法 UTF-16、真假布尔与整数、超限等测试：

```python
import copy
import json
import unittest
from scripts.wxfomo_lan.signal_contract import encode_payload, SyncError

class ContractTests(unittest.TestCase):
    def test_heartbeat_round_trip_and_unknown_key_rejected(self):
        value = {"schemaVersion": 2, "type": "heartbeat", "status": {
            "listener": "unknown", "worker": "unknown", "pendingReports": 0,
            "lastError": None, "caDetector": "unknown", "pendingAlerts": 0,
            "lastMessageObservedAt": None, "lastCaEvaluatedAt": None}}
        self.assertEqual(json.loads(encode_payload(value).decode("utf-8")), value)
        invalid = copy.deepcopy(value)
        invalid["status"]["content"] = "SYNTHETIC RAW CHAT"
        with self.assertRaises(SyncError):
            encode_payload(invalid)
```

- [ ] Run `python3 -m unittest scripts.test_wxfomo_signal_contract -v`，先确认因缺少接口失败。实现严格字段校验，引用与长度规则来自设计第 4–6 节，不能只检查顶层 keys。
- [ ] 使用下列序列化内核；validate_payload 逐层校验枚举/时间/计数恒等式/引用闭包/安全文字，错误统一变成固定 code；不要捕获后假装成功：

```python
def encode_payload(value):
    validate_payload(value)
    body = json.dumps(value, ensure_ascii=False, allow_nan=False,
                      sort_keys=True, separators=(",", ":")).encode("utf-8")
    if len(body) > 262144:
        raise SyncError("payload_too_large")
    return body
```

- [ ] 同命令验证转绿；从 fixture 递归检查未带入 content、附件和实际凭证。CA 中合法长地址不得被凭证检测误杀。提交本任务文件，提交消息 `feat: define Signal v2 payload contract`。

## Task 2：私密配置、HMAC 和发送分类

**Files:** Create `signal_transport.py`；Test `scripts/test_wxfomo_signal_transport.py`；读取已存在的 `credentials.py` 安全开文件模式，仅复用必要的验证思路，不调用 load_credential 读取 AI Key。

**Interfaces:** `load_sync_config(path) -> SyncConfig(url, device_id, secret)`，repr 隐藏 secret；`sign_headers(body, device_id, secret, timestamp, nonce) -> dict`；`send_payload(config, body, transport=None) -> (status, headers, response_bytes)`；`classify_response(expected, status, headers, response_bytes, now) -> dict`，返回 `action`（ack/retry/pause/quarantine）、固定 `code`、`retry_after`（秒或 null）。expected 是已入队 payload 解码对象。

- [ ] 写公开签名向量的失败测试：

```python
def test_public_signature_fixture(self):
    from pathlib import Path
    import json
    from scripts.wxfomo_lan.signal_transport import sign_headers
    path = Path("scripts/fixtures/signalhub-sync/signature.json")
    fixture = json.loads(path.read_text(encoding="utf-8"))
    headers = sign_headers(fixture["body"].encode("utf-8"), fixture["device"],
                           fixture["secret"], fixture["timestamp"], fixture["nonce"])
    self.assertEqual(headers["X-Wecom-Signature"], fixture["signature"])
```

- [ ] Run `python3 -m unittest scripts.test_wxfomo_signal_transport -v`，确认缺少模块导致失败。签名实现固定如下；生产时间与 nonce 每次尝试重新生成，body 固定：

```python
def sign_headers(body, device_id, secret, timestamp, nonce):
    digest = hashlib.sha256(body).hexdigest()
    canonical = "\n".join(("POST", "/api/wecom/ingest", device_id,
                           str(timestamp), nonce, digest)).encode("utf-8")
    signature = hmac.new(secret.encode("utf-8"), canonical,
                         hashlib.sha256).hexdigest()
    return {"Content-Type": "application/json", "X-Wecom-Device": device_id,
            "X-Wecom-Timestamp": str(timestamp), "X-Wecom-Nonce": nonce,
            "X-Wecom-Signature": signature}
```

- [ ] 配置仅允许确认过的 HTTPS 主机与精确路径，无 username/password/query/fragment；凭证文件上限 64 KiB。按 credentials.py 的 openat/O_NOFOLLOW/fstat 前后比对读取，拒绝符号链接、硬链接、不安全所有者或权限；不自动 chmod 用户既有目录，不泄漏解析异常。
- [ ] 用注入 transport 验证：200 错 id/revision、登录 HTML、所有 3xx 均非 ack；401 全局暂停；429 解析秒或 HTTP 日期、最长 900 秒；404/405/503 sync_unconfigured 低频探测；400/413/415/revision_conflict 隔离；replay 重新 nonce；408/5xx/网络错误重试。响应上限 16 KiB，超限不 ack。
- [ ] `send_payload` 默认使用校验 TLS 的 urllib opener，显式拒绝重定向，超时 10 秒；HTTPError 读取有界错误响应供分类，日志只输出固定 code。测试临时 0600 配置与伪服务，不连接生产。全部对应测试通过后提交 `feat: add authenticated Signal transport`。

## Task 3：可靠 outbox 与双游标

**Files:** Create `signal_outbox.py`；Test `scripts/test_wxfomo_signal_outbox.py`。不打开源库写连接。

**Interfaces:** `SyncStore(path)`、`close()`、`initialize(report_cursor, message_cursor, now)`、`cursor(channel)`、`enqueue_batch(channel, next_cursor, payloads, now, state_changes=())`、`pending(kind=None)`、`apply_response(kind, id, revision, decision, now)`、`status(now)`。payloads 为 Task 1 编码的 bytes；state_changes 是类型化操作列表，只允许 `{op: "upsert_mention", key, value}`、`{op: "delete_mention", key}`、`{op: "upsert_episode", key, value}`、`{op: "set_ca_meta", key, value}`，未知键或任意 SQL 拒绝。value 为已校验的无正文派生数据；逐项写独立同步库的 ca_mentions/ca_episodes/ca_meta 表，不每轮重写整个滚动状态大 JSON。

- [ ] 写先失败的原子性与重启测试；payload 用 Task 1 的完整 report fixture，不用不符合协议的简化对象：

```python
def test_fixed_payload_and_cursor_survive_restart(self):
    import tempfile
    from pathlib import Path
    from scripts.wxfomo_lan.signal_contract import encode_payload
    from scripts.wxfomo_lan.signal_outbox import SyncStore
    import json
    report = json.loads(Path("scripts/fixtures/signalhub-sync/report.json").read_text())
    body = encode_payload(report)
    with tempfile.TemporaryDirectory() as root:
        path = str(Path(root) / "outbox.sqlite3")
        store = SyncStore(path)
        store.initialize(0, 0, 1000)
        store.enqueue_batch("reports", 1, [body], 1000)
        store.close()
        restored = SyncStore(path)
        try:
            self.assertEqual(restored.cursor("reports"), 1)
            self.assertEqual(restored.pending()[0]["body"], body)
        finally:
            restored.close()
```

- [ ] Run `python3 -m unittest scripts.test_wxfomo_signal_outbox -v`。实现独立库，至少有以下核心表；CA 索引/episode 由 Task 5 在同一个同步库管理，不在源库迁移：

```sql
CREATE TABLE sync_state(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE outbox(
  kind TEXT NOT NULL, id TEXT NOT NULL, revision INTEGER NOT NULL,
  body BLOB NOT NULL, body_sha256 TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('pending','acked','quarantined')),
  attempts INTEGER NOT NULL DEFAULT 0, next_attempt_at REAL,
  error_code TEXT, created_at REAL NOT NULL,
  PRIMARY KEY(kind,id,revision)
);
CREATE INDEX outbox_due ON outbox(state,next_attempt_at);
CREATE TABLE ca_mentions(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE ca_episodes(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE ca_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
```

- [ ] enqueue_batch 使用 BEGIN IMMEDIATE；先检查字节/条数配额和同版本 body hash 冲突，再写 payload/类型化 CA 状态变更，最后写该 channel 游标并 COMMIT；任何失败 ROLLBACK。initialize 仅允许首次创建，一旦存在拒绝自动重设 storeId 或游标。
- [ ] 扩展测试：40 份积压分页；同 id/revision 相同 body 幂等、不同 body 拒绝；批次后半故障不推进；ack 丢失不删队列；只有匹配确认才 ack；隔离计入配额；1000 条、128 MiB 边界；401/429 全局状态重启保持；磁盘错误时固定 code、不跳水位。quota 值通过构造测试配置注入小上限，不真实写 128 MiB。
- [ ] sync_state 持久化文件身份和结果水位处 job_id/摘要；每次打开源时核对最大 analysis_id、消息 sqlite_sequence 和锚点。已知合法 record_version/别名变化交给 Task 5 解释，其余回退或替换暂停并报 source_generation_changed；worker instance_id 不作代际。测试结果回退、锚点改变、合法消息归并以及同锚点恢复无法完全识别的限制，不声称无条件识别所有备份恢复。
- [ ] 验证相应测试通过，提交 `feat: persist Signal outbox and checkpoints`。不得声称此时已同步报告或 CA，只有持久发送底座。

## Task 4：完整报告只读导出

**Files:** Create `signal_export.py`；Test `scripts/test_wxfomo_signal_export.py`。复用 briefing.py 校验、messages.py 别名安全读取和 cross_ca.py 全冻结聚合，不调用分析列表 API。

**Interfaces:** `completed_after(analysis_path, after_id, limit=10) -> list[dict]`；`build_report(row, source_messages, device_id, store_id) -> dict`，row 含 result_json、analysis_id、job_id、cadence、window_start/window_end、source_event_ids_json、created_at、model；source_messages 为已按冻结 ID 映射的本地 DTO；`prepare_reports(analysis_path, messages_path, after_id, device_id, store_id) -> list[dict]`，每项为 `{cursor, payload, error_code}`，payload 为 bytes 或 null。坏源行保留 cursor 与 code，不能被静默跳过。

- [ ] 写先失败的投影测试，最小用完整空信息 briefing；另外以完整 fixture 覆盖真实结构层级：

```python
def test_projection_keeps_briefing_without_sharing_raw_text(self):
    import json
    from scripts.wxfomo_lan.signal_export import build_report
    note = {"text": "无有效信息", "source_message_ids": []}
    briefing = {"version": 2, "kind": "market",
        "quick_read": {"focus": note, "news": note, "risk": note},
        "projects": [], "events": [], "gaps": [],
        "business": {"progress": [], "notices": [], "blockers": [], "tasks": []}}
    row = {"analysis_id": 1, "job_id": "fixture-job", "cadence": "two_hour",
        "window_start": 1000, "window_end": 8200, "created_at": 8300,
        "source_event_ids_json": "[]", "model": "fixture-model",
        "result_json": json.dumps({"briefing": briefing})}
    payload = build_report(row, {}, "fixture-device", "00000000-0000-4000-8000-000000000001")
    self.assertEqual(payload["report"]["briefing"]["version"], 2)
    self.assertEqual(payload["report"]["sources"], [])
```

- [ ] Run `python3 -m unittest scripts.test_wxfomo_signal_export -v`，确认失败。源查询使用 URI mode=ro 与 query_only，JOIN succeeded，analysis_id 升序；限制 10 不影响下轮接续。源库 unavailable 与真正 missing 分开处理。
- [ ] 使用不可变冻结 ID 顺序创建引用映射；只重映射引用键，不能替换正文里碰巧同名的字符串：

```python
def remap_citations(value, mapping):
    if isinstance(value, list):
        return [remap_citations(item, mapping) for item in value]
    if isinstance(value, dict):
        return {key: ([mapping[item] for item in child]
                      if key == "source_message_ids"
                      else remap_citations(child, mapping))
                for key, child in value.items()}
    return value
```

- [ ] 验证全冻结消息后只导出实际引用的元数据并集；缺失来源元数据置 null/available=false；CA 全量统计一次、优先保留 briefing，必要时从尾部减少可选 CA 卡并报告 coverage。保留地址原样，未知 EVM 桶不跨群合并。凭证或核心超限隔离，不删正文来通过。
- [ ] 增加测试：三天之外的新成功结果仍可增量读；生成时间来自 result；40 条分页；源忙不推进；本地别名/隔离别名；部分缺失；600 补充平面字符；同名不同链；引用闭包；超过 50 CA 的 total；队列重传不重读源、不重新调用 AI。通过对应测试后提交 `feat: export complete briefings to Signal`。

## Task 5：实时 CA 增量引擎

**Files:** Create `signal_ca.py`；Test `scripts/test_wxfomo_signal_ca.py`。必要时给 cross_ca.py 新增纯函数 `address_mentions(content) -> list[dict]`，返回 `{address, normalizedAddress, network}`，不改原聚合行为并运行原 cross_ca 测试。

**Interfaces:** `advance_ca(state, messages, now, catchup_until_id, device_id, store_id) -> dict` 是纯函数，返回 `{state, alerts, last_row_id, skipped_expired}`；state 是可序列化的最小滚动索引与 episode 状态，不含正文。messages 使用 `{row_id,event_id,record_version,group,sender,content,observed_at,inserted_at}`。`reconcile_ca(state, source_rows, now) -> dict` 返回修订后的 state，source_rows 按源库别名解析，消失/隔离记录明确表示，不伪装为源库空集合。`ca_state_changes(old, new) -> list[dict]` 生成 Task 3 四种允许操作的最小差异。`CAReader(path)` 提供 `after_row_id(cursor, limit)` 和 `current_rows(ids)`，均只读、每批最多 500 项，返回上面 DTO；暂不可读抛固定 SyncError，不返回假空列表。

- [ ] 写先失败的两个群测试：

```python
def test_two_groups_trigger_without_ai_and_keep_address_case(self):
    from scripts.wxfomo_lan.signal_ca import advance_ca
    address = "0x" + "Ab" * 20
    def message(row_id, group, timestamp):
        return {"row_id": row_id, "event_id": "fixture-" + str(row_id),
            "record_version": 1, "group": group, "sender": "合成昵称",
            "content": "Base CA: " + address, "observed_at": timestamp,
            "inserted_at": timestamp}
    result = advance_ca({}, [message(1, "合成甲群", 1000),
        message(2, "合成乙群", 1010)], 1010, 0,
        "fixture-device", "00000000-0000-4000-8000-000000000001")
    alert = result["alerts"][0]["alert"]
    self.assertEqual(alert["groupCount"], 2)
    self.assertEqual(alert["address"], address)
    self.assertEqual(alert["duplicateCount"], 1)
    self.assertEqual(alert["notificationVersion"], 1)
    self.assertNotIn("content", str(result["state"]))
```

- [ ] Run `python3 -m unittest scripts.test_wxfomo_signal_ca -v`。抽取保留原样的 CA 来源，内部去重按规范化地址/链；未知 EVM 加群隔离，不生成实时跨群事件。同昵称同归一化文本用摘要去重；无昵称退回事件键，不宣称独立人数。
- [ ] 窗口与失效时间算法如下，包含边界测试，不用 lastSeenAt 单独延长跨群有效期：

```python
def qualifying_expiry(mentions, now):
    latest_by_group = {}
    for item in mentions:
        if now - 3600 < item["observed_at"] <= now:
            group = item["group"]
            latest_by_group[group] = max(latest_by_group.get(group, 0),
                                         item["observed_at"])
    if len(latest_by_group) < 2:
        return None
    return sorted(latest_by_group.values(), reverse=True)[1] + 3600
```

- [ ] episode 状态保存稳定序号、revision、首次触发、原样地址、最后有效快照、冷却截止点、catchup 和 notificationVersion。只在对象实质变化时新增 revision；同 episode 只更新卡片。通过 Task 3 的同事务 state_changes+payload+message cursor 原子写入，不让纯函数自行写源库。
- [ ] 每 60 秒分批核对滚动索引的 record_version、删行、别名归并，触发前复核直接来源；暂不可读不删索引。每轮 500 行/2 秒，索引预算 32 MiB，超限暂停而非直接截成 50 卡。
- [ ] 增加假时钟测试：3600 秒精确边界；同群刷屏；搬运重复；未知链、跨链；未知/未来异常时间；迟到插入；record_version 改群或删除；别名合并；50 卡之外仍计数；无新消息时过期；30 分钟冷却；停机后过期消息只计漏检、有效 catchup 不弹；重新达到阈值新 episode；重启 ID/revision 不变。
- [ ] Run `python3 -m unittest scripts.test_wxfomo_signal_ca scripts.test_wxfomo_cross_ca -v`；通过后提交 `feat: detect timely cross-group CA episodes`。不运行 MiniMax 或 Swift 监听实机测试。

## Task 6：独立调度、离线联调与启用边界

**Files:** Create `signal_sync.py`、`scripts/wxfomo-signal-sync.py`；Test `scripts/test_wxfomo_signal_sync.py`；Modify README.md 的独立同步说明。LaunchAgent 定义由命令生成至用户指定暂存路径，不在测试或本次开发中 load。

**Interfaces:** `SyncService(store, report_source, ca_source, transport, clock, monotonic, random_delay)`；`step() -> dict` 执行一次有界调度，返回不含私密内容的状态。report_source 是接收 after_id 的 callable，在闭包中绑定 Task 4 prepare_reports 的路径/设备/storeId；ca_source 为 Task 5 CAReader；transport 接收固定 body 并返回 Task 2 的三元组。`main(argv=None) -> int` 提供 `--dry-run`、`--status`、`--initialize`、`--run`、`--render-launch-agent PATH` 互斥模式。

- [ ] 写先失败的命令安全测试；使用 subprocess 超时，避免错误默认启动常驻循环：

```python
def test_no_mode_never_starts_daemon_or_network(self):
    import subprocess
    import sys
    result = subprocess.run([sys.executable, "scripts/wxfomo-signal-sync.py"],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=3, universal_newlines=True)
    self.assertEqual(result.returncode, 2)
```

- [ ] Run `python3 -m unittest scripts.test_wxfomo_signal_sync -v`。入口仅调用 signal_sync.main；main 用 argparse 互斥参数，缺少显式模式返回 2。dry-run 只加载合成 fixture 或统计候选数，禁止打印真实 payload；status 不发送；initialize 必须在用户明确启用流程中调用，记录双水位，不上传。
- [ ] 实现发送调度：CA 10 秒；报告发现/心跳 60 秒；报告导出计算单独一个有界工作线程，禁止阻塞 CA 评估；网络发送单独一个线程且最多一个请求，结果回到单一同步库事务拥有者应用。时钟回退显式报错，退避截止采用 monotonic，跨重启存 wall deadline 并校验范围。
- [ ] 退避及公平性内核按以下规则实现，随机量可注入，不用真实 sleep 测失败：

```python
def retry_delay(attempt, jitter):
    base = min(300, 5 * (2 ** min(max(attempt - 1, 0), 6)))
    return min(300, base + jitter)

def choose_kind(has_fresh_ca, has_report, consecutive_ca):
    if has_report and (not has_fresh_ca or consecutive_ca >= 3):
        return "report"
    if has_fresh_ca:
        return "ca_alert"
    return "report" if has_report else None
```

- [ ] 心跳只读实际 listener/worker/CA 证据：5 秒 listener、15 秒 worker；检测器超过 30 秒无成功有界评估为 offline，源不可读为 unknown，暂停/积压明确固定 code。全局 401/429 暂停包括心跳，不因新任务绕过。旧 CA 有独立低优先级队列选择，不以此绕过 3:1 公平策略。
- [ ] 用临时 SQLite、假 clock、假 transport 联调：监听两条合成消息→CA outbox→签名接收确认；报告 fixture→完整导出→重启→固定字节重试；确认丢失；服务器重复/旧版/冲突；服务未就绪；断网后过期/迟到；校验原库 schema/hash 与 relay 边界未被写入。fake transport 收到未预期主机立即失败，不允许测试访问生产 URL。
- [ ] 参数文件与 LaunchAgent renderer 使用 plistlib，并验证参数数组包含绝对 Python/脚本/配置路径；生成动作与安装、launchctl enable 分离。README 分别说明代码完成、离线通过、网站就绪、用户显式启用四种状态，禁止把 render 当作已开机启动。
- [ ] Run `python3 -m unittest scripts.test_wxfomo_signal_sync -v`；本任务通过后，最后仅一次运行 `python3 -m unittest discover -s scripts -p 'test_wxfomo_*.py'`，再运行 `node scripts/test-wxfomo-lan-frontend.mjs` 与 `git diff --check`。没有动原 launcher 不跑无关 Swift/launcher 长测试。提交 `feat: add opt-in Signal sync runner`。

## 交接、验收与回滚

- [ ] Mac 交接给 Signal：实际 repo/branch/commit、确认后的 schema fixture、通过与未通过的测试、真实同步尚未启用。只推送代码和合成样例，不推运行配置；Git 推送需用户授权。
- [ ] Signal 独立完成 v2 receiver、登录与用户级授权、sourceReferences 展示、CA history/active 接口与 15 秒可见刷新、首次进入不弹历史、首次接收时间、expiresAt/catchup 显示以及资源预算。由 Signal 回传其测试与部署 commit，Mac 不代称其已经完成。
- [ ] 双端以合成数据验证签名与拒绝匿名读写、完整报告、跨群 CA 时效、断网保留缓存、确认丢失后幂等。只有端到端实测采集→浏览器显示后，才能报告是否达到约 60 秒目标。
- [ ] 用户在私密配置填专用凭证并明确启用时才 initialize 双水位，随后安装独立 LaunchAgent。没有凭证/截止点/接口就绪则不启用，不把未发送说成同步成功。
- [ ] 回滚仅停止独立同步 LaunchAgent，保留 outbox 和原库；不要 reset 数据库、删队列或停止原监听。Signal 回滚其独立接收器时 Mac 继续保留未确认数据。

## 计划自查

- 设计第 1–3 节及身份边界：全局约束、Task 1/4/6。
- 设计第 4 节完整报告、来源、长度及 CA 快照：Task 1/4。
- 设计第 5 节实时窗口、事件、过期和 catchup：Task 1/5/6；网站职责在交接验收，未冒充 Mac 代码覆盖。
- 设计第 6 节持久队列、权限、签名、故障和资源：Task 2/3/5/6。
- 设计第 7–8 节初始水位、独立运行与验收：Task 3/6 及交接回滚。
- 当前明确前置条件只有 Signal 尚未确认 v2 文档；没有需要用户再次确认的产品默认值。本计划未执行，测试状态全部待运行。

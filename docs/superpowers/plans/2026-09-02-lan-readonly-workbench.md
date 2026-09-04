# wxFomo LAN Read-Only Workbench Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist verified Mac enterprise-WeChat group notifications and expose a read-only, wxFomo-matching workbench to a Windows browser on the same LAN.

**Architecture:** The Swift 5.2 notification listener remains the only message writer and stores idempotent events in a private SQLite database. A dependency-free Python 3.7 service opens message/workspace data read-only, exposes authenticated GET-only JSON endpoints, and serves a static browser workbench that mirrors the existing SwiftUI information architecture.

**Tech Stack:** Swift 5.2 script, SQLite3, Python 3.7 standard library, HTML/CSS, ES2018 browser modules, Node 14 for pure-JavaScript tests.

**Spec:** `docs/superpowers/specs/2026-09-02-lan-readonly-workbench-design.md`

## Global Constraints

- Listener compatibility floor is macOS 13 with Apple Swift 5.2.4.
- Server compatibility floor is the system Python 3.7.3; add no PyPI dependency.
- Browser target is current Edge or Chrome on Windows 10/11.
- Enterprise-WeChat capture happens only on the Mac.
- Every browser endpoint is read-only; all non-GET/HEAD API methods return HTTP 405.
- Never send API keys, access tokens, private keys, signing material, full local paths, or raw configuration documents to the browser.
- Do not synthesize data for unavailable Mac sources.
- Use the existing SwiftUI views and `docs/screenshots/` as the visual and navigation source of truth.
- Use TDD for every production behavior and run each named failing test before implementing it.

---

### Task 1: Persist Verified Group Messages Idempotently

**Files:**
- Modify: `scripts/test-wecom-group-listener.sh`
- Modify: `scripts/wecom-group-listener.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: existing `StoredNotification`, `GroupMessage`, `decodeMessage`, and the verified `usda.ct == 1` policy.
- Produces: `Options.storePath: String`, `MessageDatabase.init(path:)`, and `MessageDatabase.insert(notification:message:) -> Bool`.
- Produces database tables `schema_migrations`, `conversations`, and `messages`, compatible with the relevant MessageStore v1 columns.

- [ ] **Step 1: Isolate test storage from the real user database**

Add this immediately after `fixture_dir` is created in `scripts/test-wecom-group-listener.sh`:

```zsh
export WXFOMO_LAN_DATABASE="$fixture_dir/messages.sqlite3"
```

Production option precedence must be `--store PATH`, then `WXFOMO_LAN_DATABASE`, then `~/Library/Application Support/wxFomo LAN/messages.sqlite3`.

- [ ] **Step 2: Write a failing persistence and idempotency test**

Add a test that creates one `ct=1` configured-group notification, runs the listener twice with `--include-existing --once`, and queries the store:

```zsh
test_persists_verified_messages_idempotently() {
  local database="$fixture_dir/persist-source.db"
  local config="$fixture_dir/persist/groups.txt"
  local store="$fixture_dir/persist/messages.sqlite3"
  make_database "$database"
  write_config "$config" "目标群"
  insert_notification "$database" 41 1 100 "目标群" "张三" "持久化消息"

  swift "$listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1
  swift "$listener" --database "$database" --config "$config" --store "$store" \
    --include-existing --once --timeout 1 >/dev/null 2>&1

  [[ "$(sqlite3 "$store" 'SELECT COUNT(*) FROM messages;')" == "1" ]] \
    || fail "persisted message was not idempotent"
  [[ "$(sqlite3 "$store" 'SELECT group_name||char(9)||sender_display_name||char(9)||content FROM messages;')" \
    == $'目标群\t张三\t持久化消息' ]] || fail "persisted message fields mismatch"
  [[ "$(stat -f %Lp "${store:h}")" == "700" ]] || fail "store directory mode is not 0700"
  [[ "$(stat -f %Lp "$store")" == "600" ]] || fail "store file mode is not 0600"
}
```

- [ ] **Step 3: Run the listener test and verify RED**

Run:

```bash
scripts/test-wecom-group-listener.sh
```

Expected: the new test fails because `--store` is unknown or the database does not exist.

- [ ] **Step 4: Implement the private message database**

Add `storePath` to `Options` and parse `--store`. Add a `MessageDatabase` that:

```swift
private final class MessageDatabase {
  private let database: OpaquePointer

  init(path: String) throws
  deinit
  func insert(notification: StoredNotification, message: GroupMessage) throws -> Bool
}
```

Create the directory with `0700`, open SQLite with `SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX`, enable `busy_timeout=1000`, `foreign_keys=ON`, and `journal_mode=WAL`, then create:

```sql
CREATE TABLE IF NOT EXISTS schema_migrations(
  version INTEGER PRIMARY KEY,
  applied_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS conversations(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  source TEXT NOT NULL DEFAULT 'wecom_notification',
  group_name TEXT NOT NULL,
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL,
  last_message_at REAL,
  message_count INTEGER NOT NULL DEFAULT 0,
  UNIQUE(source, group_name)
);
CREATE TABLE IF NOT EXISTS messages(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  event_id TEXT NOT NULL UNIQUE,
  conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE RESTRICT,
  group_name TEXT NOT NULL,
  sender_display_name TEXT,
  sender_stable_id TEXT,
  content TEXT NOT NULL,
  message_type TEXT NOT NULL CHECK(message_type IN ('text','media','system','unknown')),
  observed_at REAL NOT NULL,
  source_sequence INTEGER,
  attachments_json BLOB NOT NULL DEFAULT X'5B5D',
  attachment_count INTEGER NOT NULL DEFAULT 0,
  sender_confidence TEXT NOT NULL DEFAULT 'notification_payload',
  is_from_self INTEGER NOT NULL DEFAULT 0 CHECK(is_from_self IN (0,1)),
  inserted_at REAL NOT NULL,
  record_version INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS messages_lan_timeline_idx
  ON messages(observed_at, event_id, id);
```

Use `notification.fingerprint` as `event_id`, Unix seconds for `observed_at`, and `INSERT OR IGNORE` inside a transaction. Update `conversations.message_count` only when the insert changed one row. Infer `media` when content contains `[图片]`, `[视频]`, `[语音]`, `[文件]`, `[Photo]`, `[Video]`, or `[File]`; otherwise use `text`.

Call `insert` only after `decodeMessage` succeeds and before terminal output. Persistence failure is permanent and exits with a clear Chinese error; it must never silently drop a verified message.

- [ ] **Step 5: Run the listener tests and verify GREEN**

Run:

```bash
scripts/test-wecom-group-listener.sh
```

Expected: all previous tests plus `PASS: persists verified messages idempotently`.

- [ ] **Step 6: Document storage behavior and commit**

Document the default path, `--store`, permissions, and idempotency in `README.md`.

```bash
git add scripts/wecom-group-listener.swift scripts/test-wecom-group-listener.sh README.md
git commit -m "feat: persist verified WeCom group messages"
```

---

### Task 2: Build the Authenticated GET-Only Server Foundation

**Files:**
- Create: `scripts/wxfomo_lan/__init__.py`
- Create: `scripts/wxfomo_lan/security.py`
- Create: `scripts/wxfomo_lan/server.py`
- Create: `scripts/wxfomo-lan-server.py`
- Create: `scripts/test_wxfomo_lan_server.py`
- Create: `web/wxfomo-lan/index.html`

**Interfaces:**
- Consumes: Python 3.7 standard library only.
- Produces: `ensure_access_token(path) -> str`, `ServerOptions`, `create_server(options) -> ThreadingHTTPServer`, and executable `scripts/wxfomo-lan-server.py`.
- Static root: `web/wxfomo-lan` resolved relative to the repository, never from a request-supplied filesystem path.

- [ ] **Step 1: Write failing authentication, method, and token-permission tests**

Use `unittest`, `tempfile.TemporaryDirectory`, a server bound to `127.0.0.1:0`, and `http.client.HTTPConnection`. Cover:

```python
def test_api_requires_bearer_token(self):
    status, _, _ = self.request("GET", "/api/bootstrap")
    self.assertEqual(status, 401)

def test_authorized_get_reaches_api(self):
    status, _, body = self.request(
        "GET", "/api/bootstrap", {"Authorization": "Bearer test-token"}
    )
    self.assertEqual(status, 200)
    self.assertEqual(json.loads(body)["readOnly"], True)

def test_post_is_never_allowed(self):
    status, headers, _ = self.request(
        "POST", "/api/bootstrap", {"Authorization": "Bearer test-token"}
    )
    self.assertEqual(status, 405)
    self.assertEqual(headers["Allow"], "GET, HEAD")

def test_generated_token_file_is_private(self):
    token = security.ensure_access_token(self.token_path)
    self.assertGreaterEqual(len(token), 43)
    self.assertEqual(stat.S_IMODE(os.stat(self.token_path).st_mode), 0o600)
    self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(self.token_path)).st_mode), 0o700)
```

- [ ] **Step 2: Run the server tests and verify RED**

Run:

```bash
python3 -m unittest -v scripts/test_wxfomo_lan_server.py
```

Expected: import failure because `scripts/wxfomo_lan` does not exist.

- [ ] **Step 3: Implement token storage and constant-time validation**

In `security.py`, use `secrets.token_urlsafe(32)`, atomic write via a sibling temporary file plus `os.replace`, directory mode `0700`, file mode `0600`, and `hmac.compare_digest`:

```python
def ensure_access_token(path):
    if os.path.exists(path):
        return open(path, "r", encoding="utf-8").read().strip()
    token = secrets.token_urlsafe(32)
    # create directory, atomically replace, chmod, then return token
    return token

def authorized(header_value, token):
    prefix = "Bearer "
    return bool(header_value and header_value.startswith(prefix)) and hmac.compare_digest(
        header_value[len(prefix):], token
    )
```

- [ ] **Step 4: Implement a safe HTTP server factory**

Define:

```python
@dataclass(frozen=True)
class ServerOptions:
    host: str
    port: int
    token: str
    static_root: str
    message_database: str
    workspace_database: str

def create_server(options):
    handler = build_handler(options)
    return ThreadingHTTPServer((options.host, options.port), handler)
```

The handler must normalize URL paths, reject `..`, serve only the fixed static root, require bearer authentication for `/api/*`, return JSON UTF-8, and add these headers to every response:

```text
Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'
X-Content-Type-Options: nosniff
Referrer-Policy: no-referrer
Cache-Control: no-store
```

Implement `do_POST`, `do_PUT`, `do_PATCH`, and `do_DELETE` as 405 before reading a request body.

- [ ] **Step 5: Implement the executable argument boundary**

`scripts/wxfomo-lan-server.py` parses:

```text
--allow-lan
--host HOST
--port PORT
--database PATH
--workspace-database PATH
--token-file PATH
--tls-cert PATH
--tls-key PATH
```

Defaults are loopback, port 8765, the private message DB, the existing wxFomo workspace DB location, and a private token file. Refuse `--host 0.0.0.0` unless `--allow-lan` is present. Require TLS cert/key together and wrap the socket with `ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)` when present.

- [ ] **Step 6: Run tests and commit**

```bash
python3 -m unittest -v scripts/test_wxfomo_lan_server.py
git add scripts/wxfomo_lan scripts/wxfomo-lan-server.py scripts/test_wxfomo_lan_server.py web/wxfomo-lan/index.html
git commit -m "feat: add authenticated read-only LAN server"
```

---

### Task 3: Add Bootstrap, Message Search, and Stable Cursor APIs

**Files:**
- Create: `scripts/wxfomo_lan/messages.py`
- Modify: `scripts/wxfomo_lan/server.py`
- Modify: `scripts/test_wxfomo_lan_server.py`

**Interfaces:**
- Consumes: Task 1 `conversations/messages` schema.
- Produces: `MessageRepository.bootstrap()`, `MessageRepository.query(filters)`, `/api/bootstrap`, and `/api/messages`.
- Cursor format: URL-safe base64 of compact JSON `{"t": observed_at, "e": event_id}` without padding.

- [ ] **Step 1: Write failing repository/API tests with a temporary SQLite fixture**

Insert three groups and messages sharing timestamps/event IDs. Assert:

```python
def test_bootstrap_returns_groups_counts_and_source_status(self):
    payload = self.authorized_json("/api/bootstrap")
    self.assertEqual(payload["readOnly"], True)
    self.assertEqual(payload["messageSource"]["available"], True)
    self.assertEqual([g["name"] for g in payload["groups"]], ["甲群", "乙群"])
    self.assertEqual(payload["counts"]["inbox"], 3)

def test_messages_filter_by_exact_group_and_keyword(self):
    payload = self.authorized_json(
        "/api/messages?group=%E7%94%B2%E7%BE%A4&q=alpha&limit=50"
    )
    self.assertEqual([item["content"] for item in payload["items"]], ["alpha message"])

def test_cursor_paginates_equal_timestamps_without_duplicate_or_gap(self):
    first = self.authorized_json("/api/messages?limit=2")
    second = self.authorized_json(
        "/api/messages?limit=2&before=" + urllib.parse.quote(first["nextBefore"])
    )
    ids = [x["eventId"] for x in first["items"] + second["items"]]
    self.assertEqual(ids, ["event-c", "event-b", "event-a"])
```

Also test `after` returns only messages newer than the supplied cursor, query terms are parameter-bound, `limit` is clamped to 200, and missing DB returns `available:false` instead of creating a file.

- [ ] **Step 2: Run the targeted tests and verify RED**

```bash
python3 -m unittest -v scripts.test_wxfomo_lan_server.LanServerTests.test_bootstrap_returns_groups_counts_and_source_status scripts.test_wxfomo_lan_server.LanServerTests.test_cursor_paginates_equal_timestamps_without_duplicate_or_gap
```

Expected: 404 or missing repository.

- [ ] **Step 3: Implement read-only SQLite opening and cursor helpers**

Open via URI mode read-only with a 250ms timeout:

```python
uri = "file:{}?mode=ro".format(urllib.parse.quote(os.path.abspath(path)))
connection = sqlite3.connect(uri, uri=True, timeout=0.25)
connection.row_factory = sqlite3.Row
connection.execute("PRAGMA query_only=ON")
```

Implement `encode_cursor(observed_at, event_id)` and strict `decode_cursor`; reject malformed cursors with HTTP 400 without echoing raw input.

- [ ] **Step 4: Implement parameterized message queries**

Use descending `(observed_at, event_id)` ordering. `before` adds:

```sql
AND (observed_at < ? OR (observed_at = ? AND event_id < ?))
```

`after` adds the corresponding `>` comparison and returns ascending rows so the browser can merge incrementally. Exact group uses `group_name = ?`; keyword uses `content LIKE ? ESCAPE '\\' OR sender_display_name LIKE ? ESCAPE '\\'`. Escape `%`, `_`, and `\` before binding.

DTO fields are exactly:

```json
{
  "eventId": "...",
  "group": "...",
  "sender": "...",
  "content": "...",
  "messageType": "text",
  "observedAt": "2026-09-02T06:00:00Z",
  "sourceSequence": 41
}
```

- [ ] **Step 5: Run all Python tests and commit**

```bash
python3 -m unittest -v scripts/test_wxfomo_lan_server.py
git add scripts/wxfomo_lan/messages.py scripts/wxfomo_lan/server.py scripts/test_wxfomo_lan_server.py
git commit -m "feat: expose read-only message APIs"
```

---

### Task 4: Add Redacted Workspace Data Adapters

**Files:**
- Create: `scripts/wxfomo_lan/workspace.py`
- Modify: `scripts/wxfomo_lan/server.py`
- Modify: `scripts/test_wxfomo_lan_server.py`

**Interfaces:**
- Consumes: existing `workspace.sqlite3` tables and the optional local configuration-center JSON.
- Produces: `/api/alerts`, `/api/analyses`, `/api/meme`, `/api/market`, `/api/rules`, `/api/automations`, `/api/trades`, `/api/settings/status`, `/api/diagnostics`.
- Every response shape is `{ "available": bool, "reason": str|null, "items": [...] }`, except diagnostics which also reports source health.

- [ ] **Step 1: Write failing fixture-based endpoint tests**

Create a temporary workspace DB containing the exact schema columns used by the endpoints. Insert:

- one `workspace_alerts` row;
- one `analysis_jobs` plus `analysis_results` row;
- one `message_rules` row whose JSON contains safe display fields;
- one `ca_watch_pool_items` row;
- one `trade_automation_rules` and one `trade_intents` row;
- configuration JSON containing `apiKey: "NEVER_EXPOSE_THIS"`.

Assert each endpoint returns its display-safe fields and:

```python
combined = json.dumps(all_payloads, ensure_ascii=False)
self.assertNotIn("NEVER_EXPOSE_THIS", combined)
self.assertNotIn("configuration_json", combined)
self.assertNotIn("intent_json", combined)
self.assertNotIn(self.workspace_path, combined)
```

Assert a missing database returns HTTP 200 with `available:false`, and `market` returns `available:false` when no persisted market table exists.

- [ ] **Step 2: Run endpoint tests and verify RED**

```bash
python3 -m unittest -v scripts.test_wxfomo_lan_server.WorkspaceEndpointTests
```

Expected: endpoints return 404.

- [ ] **Step 3: Implement a schema-aware read-only adapter**

Before querying, read `sqlite_master` and require the endpoint's exact table set. Use explicit SELECT column lists. Parse stored JSON, then create allowlisted DTOs; never return raw JSON blobs.

Required allowlists:

```python
SAFE_RULE_FIELDS = {"id", "name", "description", "priority", "condition", "actions"}
SAFE_INTENT_FIELDS = {"symbol", "tokenName", "network", "reason", "riskSummary"}
SAFE_WATCH_FIELDS = {"symbol", "name", "network", "priceUsd", "marketCapUsd", "liquidityUsd"}
SAFE_ANALYSIS_FIELDS = {"summary", "topics", "findings", "sourceReferences", "uncertainties"}
```

If a blob is invalid JSON, omit only that row and include `invalidRows` in the response. Never include the decoding exception text when it could contain source data.

- [ ] **Step 4: Implement safe configuration status**

`/api/settings/status` may return only booleans and provider display names:

```json
{
  "available": true,
  "aiConfigured": true,
  "speechConfigured": false,
  "providerNames": ["OpenAI Compatible"],
  "tradingConfigured": false
}
```

It must not return base URLs containing credentials, headers, model secrets, or file paths.

- [ ] **Step 5: Run tests and commit**

```bash
python3 -m unittest -v scripts/test_wxfomo_lan_server.py
git add scripts/wxfomo_lan/workspace.py scripts/wxfomo_lan/server.py scripts/test_wxfomo_lan_server.py
git commit -m "feat: expose redacted workspace data"
```

---

### Task 5: Reproduce the wxFomo Shell and Live Message Workbench

**Files:**
- Create: `web/wxfomo-lan/styles.css`
- Create: `web/wxfomo-lan/api.mjs`
- Create: `web/wxfomo-lan/state.mjs`
- Create: `web/wxfomo-lan/app.mjs`
- Create: `web/wxfomo-lan/icons.svg`
- Modify: `web/wxfomo-lan/index.html`
- Create: `scripts/test-wxfomo-lan-frontend.mjs`
- Modify: `scripts/test_wxfomo_lan_server.py`

**Interfaces:**
- Consumes: `/api/bootstrap` and `/api/messages`.
- Produces: token login, 286px wxFomo sidebar, inbox/group navigation, filters, stable pagination, 2-second incremental refresh, and diagnostics footer.
- Pure state functions: `mergeNewMessages(existing, incoming)` and `routeFromHash(hash)`.

- [ ] **Step 1: Write failing pure-JavaScript state tests**

In `scripts/test-wxfomo-lan-frontend.mjs`, import `state.mjs` and assert:

```javascript
assert.deepStrictEqual(
  mergeNewMessages(
    [{ eventId: "b", observedAt: "2026-09-02T00:00:02Z" }],
    [
      { eventId: "a", observedAt: "2026-09-02T00:00:01Z" },
      { eventId: "b", observedAt: "2026-09-02T00:00:02Z" },
      { eventId: "c", observedAt: "2026-09-02T00:00:03Z" },
    ]
  ).map((item) => item.eventId),
  ["c", "b", "a"]
);
assert.deepStrictEqual(routeFromHash("#group/%E7%94%B2%E7%BE%A4"), {
  page: "group",
  group: "甲群",
});
```

Also assert invalid hashes fall back to inbox and duplicate event IDs never appear.

- [ ] **Step 2: Run Node tests and verify RED**

```bash
node scripts/test-wxfomo-lan-frontend.mjs
```

Expected: module-not-found for `state.mjs`.

- [ ] **Step 3: Implement login and API client**

`api.mjs` stores the token only in `sessionStorage`, sends `Authorization: Bearer`, clears the token on 401, and never places it in a URL. `index.html` contains a token form whose password input has autocomplete disabled and whose submit calls `authenticate(token)`.

- [ ] **Step 4: Implement the shared shell using safe DOM APIs**

Build dynamic content with `document.createElement` and `textContent`; do not interpolate group names, senders, content, URLs, or API values into `innerHTML`. Static icon SVG may be referenced with `<use>`.

Match `Sources/WxFomoApp/ContentView.swift`:

```text
wxFomo / 群聊信号台
消息: 收件箱 / 重点捕捉 / 提醒中心
监听群: dynamic exact group names
工作台: Meme 观察 / 市场趋势 / 分析记录 / 监控规则 / 交易工作台 / 自动化交易
设置: 声音与提醒 / 配置中心 / 运行诊断
采集状态 footer
```

CSS tokens must use the screenshots as reference: background `#151515`, sidebar `#1b1b1b`, raised panel `#202020`, border `#343434`, primary text `#f0f0f0`, secondary `#8d8d93`, signal green `#35d1a2`, priority red `#ff5f57`, warning amber `#f5a623`, sidebar width `286px`.

- [ ] **Step 5: Implement inbox and group feed behavior**

The toolbar includes 30 minutes / 2 hours / 6 hours / today ranges, type chips, exact group picker, keyword search, and a visible read-only badge. Load 100 rows, expose “载入更早消息” using `nextBefore`, and poll `after=latestCursor` every 2 seconds only while `document.visibilityState === "visible"`.

Message cards show group, sender initial avatar, sender, timestamp, body, media badge, and copied-state feedback. Preserve line breaks using `white-space: pre-wrap`.

- [ ] **Step 6: Add static asset and security assertions**

Extend Python tests to GET `/`, `/styles.css`, and `/app.mjs`, verifying MIME types and security headers. Assert the HTML contains no external `http://` or `https://` assets and no enabled element with a write-action data attribute.

- [ ] **Step 7: Run tests and commit**

```bash
node scripts/test-wxfomo-lan-frontend.mjs
python3 -m unittest -v scripts/test_wxfomo_lan_server.py
git add web/wxfomo-lan scripts/test-wxfomo-lan-frontend.mjs scripts/test_wxfomo_lan_server.py
git commit -m "feat: reproduce wxFomo message workbench"
```

---

### Task 6: Reproduce Every Remaining Read-Only Workbench Page

**Files:**
- Create: `web/wxfomo-lan/pages.mjs`
- Modify: `web/wxfomo-lan/app.mjs`
- Modify: `web/wxfomo-lan/styles.css`
- Modify: `scripts/test-wxfomo-lan-frontend.mjs`

**Interfaces:**
- Consumes: all Task 4 endpoints.
- Produces: page renderers `renderAlerts`, `renderAnalyses`, `renderMeme`, `renderMarket`, `renderRules`, `renderTrading`, `renderAutomations`, `renderSounds`, `renderProviders`, and `renderDiagnostics`.
- All renderers accept `{ root, payload, api }` and return a cleanup function that cancels page-local polling.

- [ ] **Step 1: Write failing navigation and page-contract tests**

Export `WORKSPACE_PAGES` and assert exact coverage:

```javascript
assert.deepStrictEqual(
  WORKSPACE_PAGES.map((page) => page.id),
  [
    "meme", "market", "analyses", "rules", "trading", "automations",
    "sounds", "providers", "diagnostics",
  ]
);
for (const page of WORKSPACE_PAGES) {
  assert.strictEqual(typeof page.render, "function");
  assert.strictEqual(page.readOnly, true);
}
```

Use a tiny fake DOM adapter supplied by the test to assert unavailable payloads render the exact text `当前 Mac 后台尚未生成此类数据` and render no `button[data-write-action]`.

- [ ] **Step 2: Run Node tests and verify RED**

```bash
node scripts/test-wxfomo-lan-frontend.mjs
```

Expected: missing `pages.mjs` or missing exports.

- [ ] **Step 3: Implement the page registry and shared read-only components**

Provide components for `WorkspacePage`, `MetricCard`, `StatusPill`, `EmptyState`, `ReadonlyControl`, `SourceLink`, and `JsonFindingList`. All user/API text uses `textContent`; external links accept only `https:` URLs and open with `rel="noopener noreferrer"`.

- [ ] **Step 4: Implement the message-adjacent pages**

- Alerts: 待处理/全部 tabs, severity, occurrence count, source messages, token/address links.
- Analyses: job list plus summary/topics/findings/source references; no create/cancel/retry controls.
- Rules: priority, enabled state, conditions and actions; no edit/new/recommended-rule controls.

Match the information hierarchy in `alerts-token-links.png` and `analysis-workbench.png`.

- [ ] **Step 5: Implement market and trading pages**

- Meme: watch cards, network badge, market cap/liquidity/price, group heat and latest seen.
- Market: chain tabs and persisted trend rows when available; otherwise the canonical unavailable state.
- Trading: recorded wallet-safe status, intents and trade history; never show wallet private material or enabled buy/sell controls.
- Automations: configuration status, rules, risk limits and recent intent states; simulation and execution buttons omitted.

- [ ] **Step 6: Implement settings and diagnostics pages**

- Sounds: display configured/not-configured status only.
- Providers: reproduce configuration-center sections but show only provider display names and configured booleans. Key fields are rendered as `••••••••` without receiving secret values.
- Diagnostics: message DB, optional workspace DB, listener activity, last message time, API read-only status, and retriable errors. Never show full local paths.

- [ ] **Step 7: Run tests and commit**

```bash
node scripts/test-wxfomo-lan-frontend.mjs
python3 -m unittest -v scripts/test_wxfomo_lan_server.py
git add web/wxfomo-lan/pages.mjs web/wxfomo-lan/app.mjs web/wxfomo-lan/styles.css scripts/test-wxfomo-lan-frontend.mjs
git commit -m "feat: reproduce read-only wxFomo workspaces"
```

---

### Task 7: Add a Safe Launcher and End-to-End Verification

**Files:**
- Create: `scripts/start-wxfomo-lan.sh`
- Create: `scripts/test-wxfomo-lan-launcher.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: listener, LAN server, private config and message DB.
- Produces: one foreground launcher supervising both processes and printing the Windows URL plus token-file location.
- Does not install a LaunchAgent or expose the service to the internet.

- [ ] **Step 1: Write a failing launcher smoke test**

The test supplies temporary config/database/token paths and a random port, launches the script, waits for `wxFomo LAN 已启动`, verifies both `/api/bootstrap` and a stored message, sends TERM, and confirms both child PIDs exit. It must not print message bodies or the token.

```zsh
scripts/start-wxfomo-lan.sh \
  --notification-database "$source_database" \
  --group-config "$group_config" \
  --message-database "$message_database" \
  --token-file "$token_file" \
  --port "$port" \
  --allow-lan
```

- [ ] **Step 2: Run launcher test and verify RED**

```bash
scripts/test-wxfomo-lan-launcher.sh
```

Expected: launcher file missing.

- [ ] **Step 3: Implement foreground supervision**

Use zsh `set -euo pipefail`, explicit paths, and a trap:

```zsh
cleanup() {
  [[ -n "${listener_pid:-}" ]] && kill "$listener_pid" 2>/dev/null || true
  [[ -n "${server_pid:-}" ]] && kill "$server_pid" 2>/dev/null || true
  [[ -n "${listener_pid:-}" ]] && wait "$listener_pid" 2>/dev/null || true
  [[ -n "${server_pid:-}" ]] && wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
```

Start the listener with the chosen `--store`, start Python with the same DB and `--allow-lan`, and keep the launcher in the foreground. If the listener exits, fail the launcher; if only the web server exits, leave the listener running and restart the server after a bounded 1, 2, 4, then 8 second backoff. Reset the backoff after the server remains healthy for 30 seconds. Print the LAN URL, not the token value.

- [ ] **Step 4: Document exact Mac and Windows usage**

README must cover:

```bash
scripts/start-wxfomo-lan.sh --allow-lan
```

Then explain how to read the printed private IPv4 URL on Windows, retrieve the token locally on the Mac, log in, stop with Control-C, handle the macOS firewall prompt, and enable optional TLS. State explicitly that raw LAN HTTP can be observed by other devices on that LAN.

- [ ] **Step 5: Run all automated verification**

```bash
git diff --check
scripts/test-wecom-group-listener.sh
python3 -m unittest -v scripts/test_wxfomo_lan_server.py
node scripts/test-wxfomo-lan-frontend.mjs
scripts/test-wxfomo-lan-launcher.sh
```

Expected: every command exits 0 with no warnings or failures.

- [ ] **Step 6: Run real Mac integration without replaying history**

Stop the old terminal-only listener, start `scripts/start-wxfomo-lan.sh --allow-lan`, and confirm:

- the listener reports six configured groups;
- the server reports a private-LAN URL;
- a new configured-group notification is inserted exactly once;
- stopping/restarting the web server does not stop or duplicate the listener data.

- [ ] **Step 7: Verify the browser end-to-end**

Use the in-app browser/browser verification tool against the local URL:

- log in with the generated token;
- check console errors are empty;
- exercise every sidebar route;
- confirm message search, exact group filter, older pagination and 2-second incremental merge;
- confirm every absent data source uses the canonical empty state;
- attempt POST/PUT/PATCH/DELETE and confirm 405;
- capture screenshots at 1440×900 for inbox, analysis empty/result, alerts, and configuration status;
- compare visual hierarchy against the four reference screenshots named in the spec.

- [ ] **Step 8: Request code review, fix findings, verify again, and commit**

Use `superpowers:requesting-code-review`, resolve all Critical/Important findings using `superpowers:receiving-code-review`, then repeat Step 5.

```bash
git add scripts/start-wxfomo-lan.sh scripts/test-wxfomo-lan-launcher.sh README.md
git commit -m "feat: launch wxFomo LAN workbench"
```

Do not claim completion until `superpowers:verification-before-completion` has checked fresh output from Step 5 and the real browser flow.

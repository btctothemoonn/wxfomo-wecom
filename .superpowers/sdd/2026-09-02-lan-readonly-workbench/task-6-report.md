# Task 6 Report: Read-Only Workbench Pages

## TDD record

1. Added the page registry, unavailable-state, provider-redaction, HTTPS-link, and renderer cleanup contracts before creating `pages.mjs`.
   - RED: `node scripts/test-wxfomo-lan-frontend.mjs`
   - Expected failure: `ERR_MODULE_NOT_FOUND` for `web/wxfomo-lan/pages.mjs`.
2. Added the read-only hash navigation contract before exporting its resolver.
   - RED: the module did not provide `readOnlyPageFromHash`.
3. Added behavior tests for the alert pending/all tabs and market chain tabs before implementing filtering.
   - RED: the acknowledged alert remained visible in the default pending view.
4. Added regression tests after independent review for stale page responses, truthful listener status, retriable diagnostics, and matched safe source messages.
   - RED: missing current-request guard export; listener readability was presented as activity; safe source-message content was absent.
5. Implemented only the behavior needed by those contracts and reran the Node test after each cycle.
   - GREEN: `PASS: wxFomo LAN frontend state`.
6. Review follow-up began with server and renderer contracts for real Task 4 response shapes.
   - RED: message DTO had no `links`; alert DTO had no `tokenContext`; the frontend module had no `isCurrentMessageRequest` export, so the Node contract could not load.
   - GREEN: the focused Python tests passed 2/2 and the Node contract passed after the minimal projections/rendering and catch guards were added.
7. Added adversarial URL cases before final verification: HTTP, userinfo, localhost, private/link-local/reserved IP literals, credential-like query/path data, IPv4-mapped loopback IPv6, and malformed escapes must not become anchors. The Python fixture keeps only the explicit query-free public HTTPS link.
8. Review follow-up added a second RED for precise alert-source lookup and a stricter link boundary.
   - RED: `/api/alerts` had no exact source DTO; the URL projector accepted non-empty query/fragment values and malformed UTF-8 percent escapes; the client accepted non-empty query/fragment values.
   - GREEN: alert sources are fetched by bound exact event IDs in SQLite batches, while server and client reject every non-empty query/fragment and malformed percent escape. A regression test inserts 205 newer messages and still resolves the alert's older source ID.
9. Round 2 review replaced the remaining generic-host assumption with an explicit public-source contract.
   - RED: Python projected query-free `router`, `nas`, `home.arpa`, and special-use domains; the Node module did not export the host contract.
   - GREEN: server and client use the same tested exact-host set derived from the Swift token, market, and explorer integrations. Single-label hosts, private/reserved IPs, special-use/example domains, trailing-dot variants, and unlisted subdomains are rejected; real DexScreener and GeckoTerminal links pass.

## Implementation

- Added `WORKSPACE_PAGES` with the exact nine-page order and read-only metadata.
- Added the required ten renderers: alerts, analyses, meme, market, rules, trading, automations, sounds, providers, and diagnostics.
- Added shared `WorkspacePage`, `MetricCard`, `StatusPill`, `EmptyState`, `ReadonlyControl`, `SourceLink`, and `JsonFindingList` components.
- Connected the Task 5 shell to the Task 4 GET-only endpoints without changing login, message pagination, or message polling behavior. Message polling is disabled while a read-only workspace page is active and resumes on return.
- Guarded workspace requests plus ordinary initial/older message success and failure paths and message-poll failures by request generation/page identity. The shared helper is used directly by both `catch` paths, so route changes cannot surface stale errors.
- Resolves alert source event IDs through an exact, bound, read-only SQLite lookup and returns safe source DTOs directly from `/api/alerts`; this is independent of message recency. Unmatched IDs remain visible as identifiers. Explicit links already present in message content are projected through a public-HTTPS allowlist and rendered with `noopener noreferrer`; links are never synthesized from an address.
- Projected the persisted cross-group incident context for alerts (`family`, `network`, normalized address, mention count, display-safe group names) without exposing internal rows or original opaque data.
- Projected the watch-pool's persisted `mentionCount` and `groupNames` and labeled their scope as the `持久化观察窗口`; the Meme page no longer uses a fixed heat placeholder.
- Rules now display all Task 4 safe condition fields, including exclusions, match modes, regex count, time windows, and every projected action identifier/severity. Regex bodies and script arguments remain absent.
- Automations now display every Task 4 projected scope, threshold, security requirement, amount/slippage/anti-MEV/cooldown limit, and protection-order field.
- Matched the existing SwiftUI hierarchy with compact page headers, split analysis task/result columns, alert tabs, watch/metric cards, market chain tabs, configuration sections, and diagnostic rows.
- Kept unavailable sources honest with the exact text `当前 Mac 后台尚未生成此类数据`; no demo records are synthesized.
- Added no create, edit, retry, run, buy, sell, simulate, execute, or other write control. Alert/market buttons are read-only filters only.
- Rendered API and user strings through `createElement` plus `textContent`; no HTML string insertion is used.
- Restricted public external links to credential-free `https:` on an exact allowlist of the public token/market/explorer hosts used by wxFomo, with no query or fragment, and set `target="_blank"` plus `rel="noopener noreferrer"`. The Python test reads the exported JavaScript constant and verifies both layers have the same set. Userinfo, single-label/internal/special-use/unlisted hosts, IP literals, unlisted subdomains, sensitive path markers, non-443 explicit ports, and malformed escapes are rejected by the server projection and client defense-in-depth.
- Providers consume display names and configured booleans only. Credential rows always show `••••••••`; unknown secret fields are ignored.
- Diagnostics map known source states and retry codes to fixed labels and never render source paths or arbitrary error text.
- Diagnostics no longer equate database readability with listener activity; until the backend exposes an explicit state, it says the backend did not provide one. Allowlisted 503 codes remain visible even when the diagnostic request itself fails.
- Did not add Task 7 launcher or README work.

## Verification

- `node scripts/test-wxfomo-lan-frontend.mjs` — PASS.
- `python3 --version` — Python 3.7.3.
- `python3 -m unittest -v scripts/test_wxfomo_lan_server.py` — 34 tests, OK.
- `node --check scripts/test-wxfomo-lan-frontend.mjs` — PASS.
- `node --check web/wxfomo-lan/pages.mjs` — PASS.
- `node --check web/wxfomo-lan/app.mjs` — PASS.
- `git diff --check` — PASS.
- Local in-app browser smoke test — login and navigation worked; canonical unavailable text appeared; diagnostics showed message/workspace/API status without full paths; zero `button[data-write-action]`; zero console warnings/errors.

## Self-review and remaining limitations

- Round 2 focused re-review found no remaining Critical, Important, or Minor issue in the host allowlist change.
- Final focused re-review confirmed the exact alert lookup and strict URL boundary are closed; no Critical, Important, or Minor issues remained in the requested scope.
- Alert links remain deliberately limited to explicit public HTTPS URLs already present in the exact persisted source messages. No chain explorer URL is manufactured. Address/mention context still appears from the persisted incident row.
- Adding a new public source host requires an explicit review and matching update to the Python and JavaScript allowlist contract; arbitrary source domains are intentionally non-clickable.
- Watch heat reflects the persisted watch item's lifetime/current observation window; it is not a rolling-period aggregation because the Swift model does not persist a rolling boundary.
- Page renderers do not start their own timers, so their cleanup functions are intentionally no-ops. The application-owned Task 5 message timer remains the only browser polling loop and is paused on workspace pages.
- Existing untracked `__pycache__` directories were left untouched and excluded from staging.

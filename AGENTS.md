# wxFomo summary-lite: minimal context map

## Scope
- Product: macOS WeCom notification capture → local rules + MiniMax summaries → read-only browser.
- Retain all configured groups, 2h/6h/24h summaries and source-backed cross-group CA discussions.
- Do not restore trading, market rankings, voice, native SwiftUI App or workspace.sqlite3 dependencies.
- Respond in Chinese. Prefer one focused change, targeted tests and concise output; avoid repeated full scans or multi-agent review loops unless requested.

## Start here, then read only the relevant files
- Startup and process ownership: scripts/start-wxfomo-lan.sh.
- Notification capture/dedup: scripts/wecom-group-listener.swift (standalone; no Sources/).
- Message DTO/search: scripts/wxfomo_lan/messages.py; new-only nickname extraction: relay.py.
- Rule matching: rules.py; scheduling and frozen input: scheduler.py, analysis_source.py, analysis_worker.py.
- Analysis persistence: analysis_store.py; MiniMax HTTPS/validation/chunking: minimax.py; local credentials: credentials.py.
- Read-only API: server.py, analysis.py; CA grouping: cross_ca.py; authentication: security.py.
- UI: web/wxfomo-lan/app.mjs (shell), pages.mjs (reports/rules/status), state.mjs (races/retries), api.mjs.
- Matching tests: scripts/test_wxfomo_<module>.py; frontend: scripts/test-wxfomo-lan-frontend.mjs.

## Guardrails
- Never print credentials, full chat dumps or reports during diagnostics. Never commit runtime files.
- Data lives outside Git in ~/Library/Application Support/wxFomo LAN/. Do not reset, migrate or rewrite it for cleanup.
- Preserve messages.sqlite3.relay.json and its fixed afterRowId. No retroactive sender rewrite or paid historical reruns.
- Keep verified source IDs, bounded retries, notification dedup and GET/HEAD-only auth protections.
- CA counts use the full frozen window, not the capped displayed references. Unknown EVM chains stay separate by group; nickname counts are not identity counts.
- No third-party dependencies required: Python 3.7 stdlib, Swift 5.2, plain JS. Keep compatible with this Mac.
- Existing docs/superpowers and screenshots are historical; do not read them for every change.
- Full pre-slim code is recoverable at codex/pre-summary-lite-20260905. Avoid resurrecting it unintentionally.

## Verification
- Run affected unittest module(s) and/or node scripts/test-wxfomo-lan-frontend.mjs first.
- Run the full Python suite once at an integration boundary: python3 -m unittest discover -s scripts -p 'test_wxfomo_*.py'.
- Launcher changes: zsh scripts/test-wxfomo-lan-launcher-readiness.sh; listener changes: its dedicated Swift fixtures.
- Do not rerun unrelated expensive Swift tests for documentation or report UI changes.
- Before runtime restart, resolve the exact launcher PID; use graceful TERM, preserve data, verify listener/worker readiness. Never use killall.

"""Authenticated, read-only HTTP server factory for the wxFomo LAN UI."""

from dataclasses import dataclass
import json
import os
import posixpath
import stat
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

from .analysis import AnalysisRepository
from .messages import (
    InvalidCursor, MessageRepository, MessageSourceUnavailable,
    merge_message_annotations,
)
from .security import authorized


SECURITY_HEADERS = {
    "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; "
    "img-src 'self' data:; connect-src 'self'; object-src 'none'; base-uri 'none'; "
    "frame-ancestors 'none'",
    "X-Content-Type-Options": "nosniff",
    "Referrer-Policy": "no-referrer",
    "Cache-Control": "no-store",
}

PUBLIC_ASSETS = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/styles.css": ("styles.css", "text/css; charset=utf-8"),
    "/app.mjs": ("app.mjs", "application/javascript; charset=utf-8"),
    "/api.mjs": ("api.mjs", "application/javascript; charset=utf-8"),
    "/clipboard.mjs": ("clipboard.mjs", "application/javascript; charset=utf-8"),
    "/pages.mjs": ("pages.mjs", "application/javascript; charset=utf-8"),
    "/state.mjs": ("state.mjs", "application/javascript; charset=utf-8"),
    "/icons.svg": ("icons.svg", "image/svg+xml; charset=utf-8"),
}


@dataclass(frozen=True)
class ServerOptions:
    host: str
    port: int
    token: str
    static_root: str
    message_database: str
    group_config_path: str
    # Deprecated CLI compatibility; never read. Still deny access as sensitive paths.
    workspace_database: str = ""
    configuration_path: str = ""
    analysis_database: str = ""
    notification_database: str = ""
    token_path: str = ""
    tls_key_path: str = ""


def build_handler(options):
    static_root = os.path.realpath(options.static_root)
    sensitive_paths = tuple(
        path
        for path in (
            options.notification_database,
            options.message_database,
            options.group_config_path,
            options.workspace_database,
            options.configuration_path,
            options.analysis_database,
            options.token_path,
            options.tls_key_path,
        )
        if path
    )
    messages = MessageRepository(options.message_database, options.group_config_path)
    analysis = AnalysisRepository(options.analysis_database)
    analysis_enabled = bool(options.analysis_database)

    class ReadOnlyHandler(BaseHTTPRequestHandler):
        def __getattr__(self, name):
            if name.startswith("do_"):
                return self._method_not_allowed
            raise AttributeError(name)

        def end_headers(self):
            for name, value in SECURITY_HEADERS.items():
                self.send_header(name, value)
            super().end_headers()

        def log_message(self, format, *args):
            return

        def do_GET(self):
            self._handle_get(send_body=True)

        def do_HEAD(self):
            self._handle_get(send_body=False)

        def do_POST(self):
            self._method_not_allowed()

        def do_PUT(self):
            self._method_not_allowed()

        def do_PATCH(self):
            self._method_not_allowed()

        def do_DELETE(self):
            self._method_not_allowed()

        def do_OPTIONS(self):
            self._method_not_allowed()

        def do_TRACE(self):
            self._method_not_allowed()

        def do_CONNECT(self):
            self._method_not_allowed()

        def _handle_get(self, send_body):
            parsed = urlsplit(self.path)
            path = unquote(parsed.path)
            if "\x00" in path or ".." in path.split("/"):
                self._send_json(400, {"error": "invalid_path"}, send_body)
                return
            path = posixpath.normpath(path)
            if not path.startswith("/"):
                path = "/" + path
            if path.startswith("/api/"):
                self._handle_api(path, parsed.query, send_body)
                return
            self._serve_static(path, send_body)

        def _handle_api(self, path, query, send_body):
            if not authorized(self.headers.get("Authorization"), options.token):
                self._send_json(401, {"error": "unauthorized"}, send_body)
                return
            if path == "/api/bootstrap":
                self._send_json(200, messages.bootstrap(), send_body)
                return
            if path == "/api/messages":
                filters = {
                    name: values[0]
                    for name, values in parse_qs(query, keep_blank_values=True).items()
                    if name in ("group", "q", "limit", "before", "after") and values
                }
                try:
                    payload = messages.query(filters)
                except InvalidCursor:
                    self._send_json(400, {"error": "invalid_cursor"}, send_body)
                    return
                except MessageSourceUnavailable as error:
                    self._send_json(
                        503,
                        {
                            "error": "message_source_unavailable",
                            "reason": error.reason,
                        },
                        send_body,
                    )
                    return
                if analysis_enabled:
                    payload["items"] = merge_message_annotations(
                        payload["items"],
                        analysis.annotations(
                            [item["eventId"] for item in payload["items"]]
                        ),
                    )
                self._send_json(200, payload, send_body)
                return
            if path == "/api/alerts":
                payload = analysis.alerts()
                if payload.get("available") and isinstance(payload.get("items"), list):
                    event_ids = []
                    for alert in payload["items"]:
                        event_ids.extend(alert.get("sourceEventIds", []))
                    try:
                        source_messages = messages.by_event_ids(event_ids)
                    except MessageSourceUnavailable:
                        source_messages = []
                    if analysis_enabled:
                        source_messages = merge_message_annotations(
                            source_messages,
                            analysis.annotations(
                                [message["eventId"] for message in source_messages]
                            ),
                        )
                    messages_by_id = {
                        message["eventId"]: message for message in source_messages
                    }
                    for alert in payload["items"]:
                        alert["sourceMessages"] = [
                            messages_by_id[event_id]
                            for event_id in alert.get("sourceEventIds", [])
                            if event_id in messages_by_id
                        ]
                self._send_json(200, payload, send_body)
                return
            if path == "/api/priority":
                payload = analysis.priority(messages)
                self._send_json(200, payload, send_body)
                return
            if path == "/api/analyses":
                payload = analysis.analyses(messages)
                self._send_json(200, payload, send_body)
                return
            if path == "/api/rules":
                payload = analysis.rules()
                self._send_json(200, payload, send_body)
                return
            if path == "/api/settings/status":
                self._send_json(200, analysis.settings_status(), send_body)
                return
            if path == "/api/diagnostics":
                message_source = messages.bootstrap()["messageSource"]
                payload = analysis.diagnostics()
                payload["sources"]["messages"] = {
                    "available": bool(message_source.get("available")),
                    "reason": message_source.get("reason")
                    if not message_source.get("available") else None,
                }
                payload["listenerState"] = message_source.get("listenerState", "unknown")
                self._send_json(200, payload, send_body)
                return
            self._send_json(404, {"error": "not_found"}, send_body)

        def _serve_static(self, path, send_body):
            asset = PUBLIC_ASSETS.get(path)
            if asset is None:
                self._send_json(404, {"error": "not_found"}, send_body)
                return
            filename, content_type = asset
            candidate = os.path.join(static_root, filename)
            descriptor = None
            try:
                before_open = os.lstat(candidate)
                if not stat.S_ISREG(before_open.st_mode) or before_open.st_nlink != 1:
                    raise OSError("public asset is not a single-link regular file")
                flags = os.O_RDONLY
                for flag_name in ("O_CLOEXEC", "O_NOFOLLOW", "O_BINARY"):
                    flags |= getattr(os, flag_name, 0)
                descriptor = os.open(candidate, flags)
                after_open = os.fstat(descriptor)
                if (
                    not stat.S_ISREG(after_open.st_mode)
                    or after_open.st_nlink != 1
                    or (before_open.st_dev, before_open.st_ino)
                    != (after_open.st_dev, after_open.st_ino)
                ):
                    raise OSError("public asset changed while opening")
                for sensitive_path in sensitive_paths:
                    try:
                        sensitive_identity = os.stat(sensitive_path)
                    except OSError:
                        continue
                    if (after_open.st_dev, after_open.st_ino) == (
                        sensitive_identity.st_dev,
                        sensitive_identity.st_ino,
                    ):
                        raise OSError("public asset aliases a sensitive file")
                with os.fdopen(descriptor, "rb") as stream:
                    descriptor = None
                    content = stream.read()
            except (OSError, ValueError):
                if descriptor is not None:
                    os.close(descriptor)
                self._send_json(404, {"error": "not_found"}, send_body)
                return
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            if send_body:
                self.wfile.write(content)

        def _method_not_allowed(self):
            self.send_response(405)
            self.send_header("Allow", "GET, HEAD")
            self.send_header("Content-Length", "0")
            self.end_headers()

        def _send_json(self, status, value, send_body):
            content = json.dumps(value, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            if send_body:
                self.wfile.write(content)

    return ReadOnlyHandler


def create_server(options):
    handler = build_handler(options)
    server = ThreadingHTTPServer((options.host, options.port), handler)
    server.daemon_threads = True
    return server

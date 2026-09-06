"""Opt-in Signal transport primitives. No startup, background work or defaults."""
import base64
import email.utils
import hashlib
import hmac
import json
import math
import os
import re
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request
from collections import namedtuple

from .credentials import (
    CredentialError, _safe_private_parent, _entry_metadata,
    _validate_file, _same_file_version,
)
from .signal_contract import SyncError, encode_payload, require, validate_payload


INGEST_URL = 'https://holdrich.online/api/wecom/ingest'
MAX_RESPONSE_BYTES = 16384
REQUEST_TIMEOUT = 10.0


class SyncConfig(namedtuple('SyncConfigBase', 'url device_id secret')):
    __slots__ = ()
    def __repr__(self):
        return 'SyncConfig(url=<configured>, device_id=<redacted>, secret=<redacted>)'


def _unique_object(pairs):
    value = {}
    for key, child in pairs:
        require(key not in value, 'response_invalid')
        value[key] = child
    return value


def _json(raw):
    return json.loads(raw.decode('utf-8'), object_pairs_hook=_unique_object,
                      parse_constant=lambda unused: (_ for _ in ()).throw(ValueError()))


def _identity(device_id, secret):
    require(type(device_id) is str and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', device_id), 'config_invalid')
    require(type(secret) is str and 32 <= len(secret) <= 4096, 'config_invalid')
    require(not any(ord(c) < 33 or ord(c) == 127 for c in secret), 'config_invalid')
    secret.encode('utf-8')


def _config(config):
    require(isinstance(config, SyncConfig) and config.url == INGEST_URL, 'config_invalid')
    _identity(config.device_id, config.secret)
    require(not config.secret.startswith('TEST-ONLY-'), 'config_invalid')


def load_sync_config(path):
    """Read only the supplied sync file, never MiniMax or LAN credentials."""
    parent = descriptor = None
    failure = None
    try:
        parent, name = _safe_private_parent(path, create=False)
        before = _entry_metadata(parent, name)
        require(before is not None, 'config_unavailable')
        _validate_file(before)
        flags = os.O_RDONLY | getattr(os, 'O_CLOEXEC', 0) | getattr(os, 'O_NOFOLLOW', 0)
        descriptor = os.open(name, flags, dir_fd=parent)
        opened = os.fstat(descriptor)
        _validate_file(opened)
        require(_same_file_version(before, opened), 'config_unsafe')
        raw = b''
        while len(raw) <= 65536:
            part = os.read(descriptor, min(8192, 65537 - len(raw)))
            if not part:
                break
            raw += part
        require(len(raw) <= 65536, 'config_invalid')
        after = os.fstat(descriptor)
        _validate_file(after)
        entry = _entry_metadata(parent, name)
        require(entry is not None and _same_file_version(opened, after)
                and _same_file_version(after, entry), 'config_unsafe')
        value = _json(raw)
        require(type(value) is dict and set(value) == {'url', 'deviceId', 'secret'}, 'config_invalid')
        config = SyncConfig(value['url'], value['deviceId'], value['secret'])
        _config(config)
    except SyncError as error:
        failure = error.code if error.code.startswith('config_') else 'config_invalid'
    except (CredentialError, OSError, ValueError, TypeError, RecursionError):
        failure = 'config_unsafe'
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if parent is not None:
            os.close(parent)
    if failure:
        raise SyncError(failure)
    return config


def sign_headers(body, device_id, secret, timestamp, nonce):
    failure = False
    try:
        _identity(device_id, secret)
        require(type(body) is bytes and 0 < len(body) <= 262144, 'payload_invalid')
        require(type(timestamp) in (str, int) and re.fullmatch(r'[0-9]{10}', str(timestamp)), 'signing_invalid')
        require(type(nonce) is str and re.fullmatch(r'[0-9a-f]{32}', nonce), 'signing_invalid')
        digest = hashlib.sha256(body).hexdigest()
        canonical = '\n'.join(('POST', '/api/wecom/ingest', device_id, str(timestamp), nonce, digest))
        signature = hmac.new(secret.encode('utf-8'), canonical.encode('utf-8'), hashlib.sha256).hexdigest()
    except (SyncError, UnicodeError, TypeError, ValueError):
        failure = True
    if failure:
        raise SyncError('signing_invalid')
    return {'Content-Type': 'application/json', 'X-Wecom-Device': device_id,
            'X-Wecom-Timestamp': str(timestamp), 'X-Wecom-Nonce': nonce,
            'X-Wecom-Signature': signature}


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


def _open(request, timeout):
    return urllib.request.build_opener(_RejectRedirects()).open(request, timeout=timeout)


def _response_metadata(status, headers):
    require(type(status) is int and 100 <= status <= 599, 'response_invalid')
    # No cookies, arbitrary headers or server text cross the private IPC boundary.
    retry = next((value for key, value in headers.items() if key.lower() == 'retry-after'), None)
    safe = {'Retry-After': retry} if type(retry) is str and len(retry) <= 256 else {}
    return status, safe


def _read_response(request, transport, on_headers=None):
    response = None
    try:
        try:
            response = transport(request, timeout=REQUEST_TIMEOUT)
        except urllib.error.HTTPError as error:
            response = error
        status = getattr(response, 'status', None)
        if status is None:
            status = response.getcode()
        status, headers = _response_metadata(status, dict(getattr(response, 'headers', {}) or {}))
        if on_headers is not None:
            on_headers({'status': status, 'headers': headers})
        # These global decisions need no body. A broken/oversized body must not
        # hide an authentication failure or the server's rate-limit instruction.
        if status in (401, 429):
            return status, headers, b''
        raw = b''
        while len(raw) <= MAX_RESPONSE_BYTES:
            chunk = response.read(min(4096, MAX_RESPONSE_BYTES + 1 - len(raw)))
            if not chunk:
                break
            require(type(chunk) is bytes, 'response_invalid')
            raw += chunk
        require(len(raw) <= MAX_RESPONSE_BYTES, 'response_too_large')
        return status, headers, raw
    finally:
        if response is not None:
            try:
                response.close()
            except Exception:
                pass


def _bounded_request(request):
    """A short-lived child makes the deadline cover DNS, headers and slow reads.

    Socket timeouts alone cannot bound a trickling response. Do not leave a
    timed-out thread/request in flight: terminate and reap this one child first.
    Signed headers and body travel only over anonymous pipes, never argv/files.
    """
    packet = json.dumps({'headers': dict(request.header_items()),
                         'body': base64.b64encode(request.data).decode('ascii')}).encode('utf-8')
    started = time.monotonic()
    child = None
    timed_out = False
    try:
        child = subprocess.Popen(
            [sys.executable, '-m', 'wxfomo_lan.signal_transport'],
            cwd=os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            output, _ = child.communicate(packet, timeout=max(.001, REQUEST_TIMEOUT - (time.monotonic() - started)))
        except subprocess.TimeoutExpired:
            timed_out = True
            child.kill()
            output, _ = child.communicate()
    finally:
        if child is not None and child.poll() is None:
            child.kill()
            child.communicate()
    require(len(output) <= MAX_RESPONSE_BYTES * 2, 'response_invalid')
    head, separator, tail = output.partition(b'\n')
    require(separator, 'transport_error')
    metadata = _json(head)
    require(type(metadata) is dict and set(metadata) == {'status', 'headers'}, 'transport_error')
    status, headers = _response_metadata(metadata['status'], metadata['headers'])
    if status in (401, 429):
        return status, headers, b''
    require(not timed_out and time.monotonic() - started < REQUEST_TIMEOUT
            and child.returncode == 0, 'transport_error')
    result = _json(tail)
    if type(result) is dict and set(result) == {'error'}:
        require(False, result['error'] if result['error'] in (
            'response_invalid', 'response_too_large') else 'transport_error')
    require(type(result) is dict and set(result) == {'body'}, 'response_invalid')
    raw = base64.b64decode(result['body'], validate=True)
    require(len(raw) <= MAX_RESPONSE_BYTES, 'response_too_large')
    return status, headers, raw


def _http_child():
    """Private one-request entry point; no listener, scheduler or credentials."""
    def emit(value):
        sys.stdout.buffer.write(json.dumps(value, separators=(',', ':')).encode('utf-8') + b'\n')
        sys.stdout.buffer.flush()
    try:
        packet = _json(sys.stdin.buffer.read(360449))
        require(type(packet) is dict and set(packet) == {'headers', 'body'}, 'transport_error')
        body = base64.b64decode(packet['body'], validate=True)
        require(0 < len(body) <= 262144, 'transport_error')
        request = urllib.request.Request(INGEST_URL, data=body, headers=packet['headers'], method='POST')
        _, _, raw = _read_response(request, _open, on_headers=emit)
        emit({'body': base64.b64encode(raw).decode('ascii')})
    except SyncError as error:
        emit({'error': error.code})
    except Exception:
        emit({'error': 'transport_error'})


def send_payload(config, body, transport=None):
    """One bounded request. Optional in-process transport is for offline tests only."""
    failure = None
    try:
        _config(config)
        require(type(body) is bytes and len(body) <= 262144, 'payload_invalid')
        value = _json(body)
        require(encode_payload(value) == body, 'payload_invalid')
        pending = [value]
        while pending:
            item = pending.pop()
            if type(item) is str:
                require(config.secret not in item, 'payload_sensitive')
            elif type(item) is dict:
                pending.extend(item.keys())
                pending.extend(item.values())
            elif type(item) is list:
                pending.extend(item)
        headers = sign_headers(body, config.device_id, config.secret, int(time.time()), secrets.token_hex(16))
        request = urllib.request.Request(config.url, data=body, headers=headers, method='POST')
        result = _bounded_request(request) if transport is None else _read_response(request, transport)
    except SyncError as error:
        failure = error.code
    except Exception:
        failure = 'transport_error'
    if failure:
        raise SyncError(failure)
    return result


def _retry_after(headers, now):
    value = next((value for key, value in headers.items() if key.lower() == 'retry-after'), None)
    if type(value) is str:
        if re.fullmatch(r'[0-9]+', value.strip()):
            return min(900, int(value))
        try:
            date = email.utils.parsedate_to_datetime(value)
            if date.tzinfo is not None:
                return min(900, max(0, date.timestamp() - now))
        except (TypeError, ValueError, OverflowError):
            pass
    return 60


def classify_response(expected, status, headers, response_bytes, now):
    """Decisions only. 'schema' pause must not quarantine or downgrade v2 items."""
    validate_payload(expected)
    require(type(status) is int and 100 <= status <= 599, 'response_invalid')
    require(type(now) in (int, float) and math.isfinite(now), 'clock_invalid')
    require(isinstance(headers, dict), 'response_invalid')
    def decision(action, code, retry_after=None, scope='item'):
        return dict(action=action, code=code, retry_after=retry_after, scope=scope)
    value = None
    if type(response_bytes) is bytes and len(response_bytes) <= MAX_RESPONSE_BYTES:
        try:
            value = _json(response_bytes)
        except (SyncError, ValueError, TypeError, RecursionError):
            pass
    error = value.get('error') if type(value) is dict else None
    if status == 401:
        return decision('pause', 'authentication_failed', scope='global')
    if status == 429:
        return decision('retry', 'rate_limited', _retry_after(headers, now), 'global')
    if status == 400 and error == 'unsupported_schema':
        return decision('pause', 'unsupported_schema', scope='schema')
    if status in (404, 405) or (status == 503 and error == 'sync_unconfigured'):
        return decision('retry', 'sync_unconfigured', 300)
    if status == 409:
        if error == 'replay':
            return decision('retry', 'replay')
        if error == 'revision_conflict':
            return decision('quarantine', 'revision_conflict')
        return decision('retry', 'response_invalid')
    if status == 413:
        return decision('quarantine', 'payload_too_large')
    if status in (400, 415):
        return decision('quarantine', 'request_invalid')
    if status == 408:
        return decision('retry', 'transport_error')
    if status >= 500:
        return decision('retry', 'provider_unavailable')
    if status == 200 and type(value) is dict and value.get('ok') is True:
        if expected['type'] == 'heartbeat':
            if set(value) == {'ok'}:
                return decision('ack', None)
        elif set(value) == {'ok', 'id', 'revision', 'disposition'}:
            item = expected['report' if expected['type'] == 'report' else 'alert']
            if (value['id'] == item['id'] and type(value['revision']) is int
                    and value['revision'] == item['revision']
                    and value['disposition'] in ('stored', 'duplicate', 'stale')):
                return decision('ack', None)
    return decision('retry', 'response_invalid')


if __name__ == '__main__':
    _http_child()

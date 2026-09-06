"""Bounded MiniMax Anthropic-compatible analysis client.

Model output is treated as untrusted data.  Only a small validated projection is
returned; provider bodies, headers, credentials, and thinking blocks are never
attached to errors.
"""

import copy
import datetime
import email.utils
import ipaddress
import json
import math
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import namedtuple

from .briefing import SYSTEM_PROMPT, BriefingError, references as briefing_references, result_projection, validate_briefing, normalize_missing_text, compact_provider_projects


MAINLAND_BASE_URL = "https://api.minimaxi.com/anthropic"
DEFAULT_MODEL = "MiniMax-M2.7"
MAX_REQUEST_BYTES = 512 * 1024
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
DEFAULT_CHUNK_CONTENT_BYTES = 128 * 1024
_MAX_RESULT_ITEMS = 200
_MAX_TEXT_BYTES = 64 * 1024
# A result is encoded once as synthesis JSON and again as the Anthropic user
# message string.  This cap leaves room for two worst-case escaped results plus
# the fixed prompt/document envelope inside MAX_REQUEST_BYTES.
_MAX_PROJECTED_RESULT_BYTES = 32 * 1024
_SYNTHESIS_BATCH_SIZE = 8
_MESSAGE_BATCH_SIZE = 300
# Large, non-streaming briefings can exceed 90 seconds before any response header.
# Keep a finite wait; this does not increase the existing bounded repair/retries.
_TIMEOUT_SECONDS = 180.0

_TOP_LEVEL_KEYS = frozenset(
    ("summary", "summary_source_message_ids", "topics", "findings", "crypto_addresses")
)
_TOPIC_KEYS = frozenset(("title", "summary", "source_message_ids"))
_FINDING_KEYS = frozenset(("category", "text", "status", "source_message_ids"))
_ADDRESS_KEYS = frozenset(
    ("address", "context_summary", "status", "source_message_ids")
)
_FINDING_CATEGORIES = frozenset(
    (
        "key_claim",
        "action_item",
        "deadline",
        "risk",
        "opportunity",
        "disagreement",
        "open_question",
    )
)
_EPISTEMIC_STATUSES = frozenset(("fact", "inference", "uncertain"))
_MESSAGE_FIELDS = (
    "eventId",
    "groupName",
    "senderDisplayName",
    "content",
    "messageType",
    "observedAt",
    "segmentIndex",
    "segmentCount",
)
_EVM_ADDRESS = re.compile(r"(?i)(?<![0-9a-f])0x[0-9a-f]{40}(?![0-9a-f])")
_SOLANA_ADDRESS = re.compile(
    r"(?<![1-9A-HJ-NP-Za-km-z])[1-9A-HJ-NP-Za-km-z]{32,44}"
    r"(?![1-9A-HJ-NP-Za-km-z])"
)
_SOLANA_CUE = re.compile(
    r"(?i)(?:\bsol(?:ana)?\b|\bSPL\b|\bCA\b|\bmint\b|contract\s*address|"
    r"合约(?:地址)?|合約(?:地址)?|地址|gmgn\.ai|dexscreener\.com|"
    r"birdeye\.so|solscan\.io|pump\.fun)"
)

_SYSTEM_PROMPT = SYSTEM_PROMPT + '''
crypto_address_evidence 区分地址原文与附近讨论：每项 address 是原样地址，direct_source_message_ids 是实际出现该大小写地址的消息；context_source_message_ids 仅表示附近讨论，不能单独用作 CA 出现的证据。输出 addresses 时必须逐字选择对应 address，并引用该项至少一个 direct_source_message_ids；不得把其他大小写变体或其他 CA 的引用混用。没有直接来源时，不要给该项目填入未经支持的 CA。
'''


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None


_NO_REDIRECT_OPENER = urllib.request.build_opener(_RejectRedirects())


def _default_transport(request, timeout):
    return _NO_REDIRECT_OPENER.open(request, timeout=timeout)


class MiniMaxError(Exception):
    """A redacted provider failure represented only by stable scheduling data."""

    __slots__ = ("code", "retryable", "retry_after", "validation_detail")

    def __init__(self, code, retryable=False, retry_after=None, validation_detail=None):
        self.code = code
        self.retryable = bool(retryable)
        self.retry_after = retry_after
        self.validation_detail = validation_detail
        super().__init__(code)

    def __repr__(self):
        return "MiniMaxError(code={!r}, retryable={!r}, retry_after={!r})".format(
            self.code, self.retryable, self.retry_after
        )


class AnalysisOutcome(
    namedtuple(
        "AnalysisOutcomeBase",
        ("result", "model", "provider_request_id", "input_tokens", "output_tokens"),
    )
):
    __slots__ = ()


def _utf8_parts(text, maximum_bytes):
    if maximum_bytes <= 0:
        raise MiniMaxError("request_invalid", False, None)
    if not text:
        return [""]
    parts = []
    characters = []
    byte_count = 0
    for character in text:
        encoding_failed = False
        try:
            size = len(character.encode("utf-8"))
        except UnicodeEncodeError:
            encoding_failed = True
            size = None
        if encoding_failed:
            raise MiniMaxError("request_invalid", False, None)
        if size > maximum_bytes:
            raise MiniMaxError("request_invalid", False, None)
        if characters and byte_count + size > maximum_bytes:
            parts.append("".join(characters))
            characters = []
            byte_count = 0
        characters.append(character)
        byte_count += size
    if characters:
        parts.append("".join(characters))
    return parts


def _finite_number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    conversion_failed = False
    try:
        number = float(value)
    except (OverflowError, TypeError, ValueError):
        conversion_failed = True
        number = None
    if conversion_failed or not math.isfinite(number):
        return None
    return number


def _sort_key(item):
    timestamp = _finite_number(item.get("observedAt", 0.0))
    if timestamp is None:
        raise MiniMaxError("request_invalid", False, None)
    event_id = item.get("eventId")
    if not isinstance(event_id, str) or not event_id:
        raise MiniMaxError("request_invalid", False, None)
    return timestamp, event_id


def _project_message(message):
    if not isinstance(message, dict):
        raise MiniMaxError("request_invalid", False, None)
    _sort_key(message)
    content = message.get("content")
    if not isinstance(content, str):
        raise MiniMaxError("request_invalid", False, None)
    result = {}
    for field in _MESSAGE_FIELDS:
        if field in message:
            result[field] = copy.deepcopy(message[field])
    for field in ("groupName", "senderDisplayName", "messageType"):
        if field in result and not isinstance(result[field], str):
            raise MiniMaxError("request_invalid", False, None)
    return result


def chunk_messages(messages, maximum_content_bytes):
    """Return chronological chunks while preserving every UTF-8 character."""

    if (
        isinstance(maximum_content_bytes, bool)
        or not isinstance(maximum_content_bytes, int)
        or maximum_content_bytes <= 0
    ):
        raise MiniMaxError("request_invalid", False, None)
    if not isinstance(messages, (list, tuple)):
        raise MiniMaxError("request_invalid", False, None)

    projected = [_project_message(item) for item in messages]
    projected.sort(key=_sort_key)
    expanded = []
    for item in projected:
        pieces = _utf8_parts(item["content"], maximum_content_bytes)
        if len(pieces) == 1:
            expanded.append(item)
            continue
        for index, piece in enumerate(pieces, 1):
            segment = copy.deepcopy(item)
            segment["content"] = piece
            segment["segmentIndex"] = index
            segment["segmentCount"] = len(pieces)
            expanded.append(segment)

    chunks = []
    current = []
    current_bytes = 0
    for item in expanded:
        content_bytes = len(item["content"].encode("utf-8"))
        weight = max(1, content_bytes)
        if current and current_bytes + weight > maximum_content_bytes:
            chunks.append(current)
            current = []
            current_bytes = 0
        current.append(item)
        current_bytes += weight
    if current:
        chunks.append(current)
    return chunks


def _base58_decoded_size(value):
    number = 0
    alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
    lookup = {character: index for index, character in enumerate(alphabet)}
    try:
        for character in value:
            number = number * 58 + lookup[character]
    except KeyError:
        return None
    payload_size = (number.bit_length() + 7) // 8
    return len(value) - len(value.lstrip("1")) + payload_size


def _address_evidence(messages):
    evidence = {}
    for message_index, message in enumerate(messages):
        content = message["content"]
        for match in _EVM_ADDRESS.finditer(content):
            address = match.group(0)
            normalized = address.lower()
            item = evidence.setdefault(
                normalized, {"address": address, "direct_indices": []}
            )
            item["direct_indices"].append(message_index)
            item.setdefault("verbatim_sources", {}).setdefault(address, []).append(message["eventId"])
        stripped = content.strip()
        for match in _SOLANA_ADDRESS.finditer(content):
            address = match.group(0)
            if _base58_decoded_size(address) != 32:
                continue
            if stripped != address and not _SOLANA_CUE.search(content):
                continue
            item = evidence.setdefault(
                address, {"address": address, "direct_indices": []}
            )
            item["direct_indices"].append(message_index)
            item.setdefault("verbatim_sources", {}).setdefault(address, []).append(message["eventId"])
    for item in evidence.values():
        context_indices = set()
        for direct_index in item.pop("direct_indices"):
            direct = messages[direct_index]
            lower = max(0, direct_index - 2)
            upper = min(len(messages), direct_index + 3)
            for candidate_index in range(lower, upper):
                candidate = messages[candidate_index]
                if candidate.get("groupName") != direct.get("groupName"):
                    continue
                if abs(
                    float(candidate.get("observedAt", 0.0))
                    - float(direct.get("observedAt", 0.0))
                ) >= 300.0:
                    continue
                context_indices.add(candidate_index)
        item["source_message_ids"] = [
            messages[index]["eventId"] for index in sorted(context_indices)
        ]
    return evidence


def _header(headers, name):
    if headers is None:
        return None
    try:
        value = headers.get(name)
    except AttributeError:
        value = None
    if value is not None:
        return value
    try:
        for key, candidate in headers.items():
            if str(key).lower() == name.lower():
                return candidate
    except (AttributeError, TypeError):
        return None
    return None


def _safe_request_id(value):
    if not isinstance(value, str):
        return None
    value = value.strip()
    encoding_failed = False
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError:
        encoding_failed = True
        encoded = None
    if encoding_failed or not value or len(encoded) > 256:
        return None
    if not value.isprintable():
        return None
    return value


def _retry_after(value):
    if not isinstance(value, str):
        return None
    try:
        seconds = float(value.strip())
    except (TypeError, ValueError):
        seconds = None
    if seconds is not None and math.isfinite(seconds) and seconds >= 0:
        return seconds
    try:
        parsed = email.utils.parsedate_to_datetime(value)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=datetime.timezone.utc)
        return max(0.0, parsed.timestamp() - time.time())
    except (TypeError, ValueError, OverflowError):
        return None


def _error_for_status(status, headers):
    retry = _retry_after(_header(headers, "Retry-After"))
    if status in (401, 403):
        return MiniMaxError("credential_unavailable", False, None)
    if status == 429:
        return MiniMaxError("rate_limited", True, retry)
    if status in (408, 409, 425, 500, 502, 503, 504, 529):
        return MiniMaxError("provider_unavailable", True, retry)
    return MiniMaxError("request_invalid", False, None)


def _read_bounded(response, maximum_bytes):
    chunks = []
    total = 0
    while True:
        chunk = response.read(min(64 * 1024, maximum_bytes + 1 - total))
        if not chunk:
            break
        total += len(chunk)
        if total > maximum_bytes:
            raise MiniMaxError("invalid_response", False, None)
        chunks.append(chunk)
    return b"".join(chunks)


def _unique_json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate_json_key")
        result[key] = value
    return result


def _strict_json(text, allow_missing_wrapper=False):
    stripped = text.strip()
    if stripped.startswith("```"):
        lines = stripped.splitlines()
        if len(lines) < 3 or lines[-1].strip() != "```":
            raise MiniMaxError("invalid_response", False, None)
        opener = lines[0].strip().lower()
        if opener not in ("```", "```json"):
            raise MiniMaxError("invalid_response", False, None)
        stripped = "\n".join(lines[1:-1]).strip()
    parse_failed = False
    try:
        value = json.loads(
            stripped,
            parse_constant=lambda unused: (_ for _ in ()).throw(ValueError()),
            object_pairs_hook=_unique_json_object,
        )
    except (RecursionError, TypeError, ValueError) as error:
        parse_failed = True
        value = None
        # Some end_turn responses contain a complete briefing object but omit
        # only its outer wrapper's final brace. Decode that WHOLE inner object;
        # never complete strings, numbers, arrays, citations or missing fields.
        if allow_missing_wrapper and isinstance(error, json.JSONDecodeError) and error.pos == len(stripped):
            prefix = re.match(r'^\{\s*"briefing"\s*:\s*', stripped)
            if prefix:
                try:
                    inner, end = json.JSONDecoder(
                        parse_constant=lambda unused: (_ for _ in ()).throw(ValueError()),
                        object_pairs_hook=_unique_json_object,
                    ).raw_decode(stripped, prefix.end())
                    if isinstance(inner, dict) and end == len(stripped):
                        value, parse_failed = {'briefing': inner}, False
                except (RecursionError, TypeError, ValueError):
                    pass
    if parse_failed:
        raise MiniMaxError("invalid_response", False, None)
    return value


def _text(value):
    if not isinstance(value, str) or not value.strip():
        raise MiniMaxError("invalid_response", False, None)
    encoding_failed = False
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError:
        encoding_failed = True
        encoded = None
    if encoding_failed or len(encoded) > _MAX_TEXT_BYTES:
        raise MiniMaxError("invalid_response", False, None)
    return value


def _source_ids(value, known_ids, allowed_ids=None):
    if not isinstance(value, list) or len(value) > _MAX_RESULT_ITEMS:
        raise MiniMaxError("invalid_response", False, None)
    result = []
    allowed = known_ids if allowed_ids is None else allowed_ids
    for event_id in value:
        if not isinstance(event_id, str):
            raise MiniMaxError("invalid_response", False, None)
        if event_id not in known_ids or event_id not in allowed:
            raise MiniMaxError("invalid_source_reference", False, None)
        if event_id not in result:
            result.append(event_id)
    return result


def _exact_object(value, keys):
    if not isinstance(value, dict) or frozenset(value) != keys:
        raise MiniMaxError("invalid_response", False, None)


def _validated_result(value, known_ids, evidence, maximum_result_bytes):
    if isinstance(value, dict) and set(value) == {"briefing"}:
        try:
            briefing = normalize_missing_text(value['briefing'])
            # Citation count is a display bound, not a reason to regenerate
            # conclusions. Check EVERY ID before reducing; unknown tail IDs
            # must not disappear through truncation. Keep a direct CA citation
            # already supplied by the model; never invent a new citation.
            pending = [briefing]
            while pending:
                item = pending.pop()
                if isinstance(item, dict):
                    ids = item.get('source_message_ids')
                    if isinstance(ids, list) and len(ids) > 5:
                        if any(not isinstance(ref, str) or ref not in known_ids for ref in ids):
                            raise MiniMaxError('invalid_source_reference', False, None)
                        unique = list(dict.fromkeys(ids))
                        selected = unique[:5]
                        raw = item.get('address')
                        if isinstance(raw, str):
                            key = raw.lower() if raw.lower().startswith('0x') else raw
                            direct = evidence.get(key, {}).get('verbatim_sources', {}).get(raw, [])
                            if not set(selected).intersection(direct):
                                existing = next((ref for ref in unique if ref in direct), None)
                                if existing is not None:
                                    selected = selected[:4] + [existing]
                        item['source_message_ids'] = selected
                    pending.extend(item.values())
                elif isinstance(item, list):
                    pending.extend(item)
            result = result_projection(compact_provider_projects(briefing, known_ids, evidence))
        except BriefingError as error:
            raise MiniMaxError(error.code, False, None, validation_detail=error.detail)
        if len(json.dumps(result, ensure_ascii=False).encode('utf-8')) > maximum_result_bytes:
            raise MiniMaxError('invalid_response', False, None)
        return result
    _exact_object(value, _TOP_LEVEL_KEYS)
    summary = _text(value["summary"])
    summary_ids = _source_ids(value["summary_source_message_ids"], known_ids)

    topics_value = value["topics"]
    findings_value = value["findings"]
    addresses_value = value["crypto_addresses"]
    if any(
        not isinstance(items, list) or len(items) > _MAX_RESULT_ITEMS
        for items in (topics_value, findings_value, addresses_value)
    ):
        raise MiniMaxError("invalid_response", False, None)

    topics = []
    for index, topic in enumerate(topics_value, 1):
        _exact_object(topic, _TOPIC_KEYS)
        topics.append(
            {
                "topicID": "topic-{0}".format(index),
                "title": _text(topic["title"]),
                "summary": _text(topic["summary"]),
                "sourceMessageIDs": _source_ids(
                    topic["source_message_ids"], known_ids
                ),
            }
        )

    findings = []
    for index, finding in enumerate(findings_value, 1):
        _exact_object(finding, _FINDING_KEYS)
        if (
            not isinstance(finding["category"], str)
            or finding["category"] not in _FINDING_CATEGORIES
        ):
            raise MiniMaxError("invalid_response", False, None)
        if (
            not isinstance(finding["status"], str)
            or finding["status"] not in _EPISTEMIC_STATUSES
        ):
            raise MiniMaxError("invalid_response", False, None)
        findings.append(
            {
                "findingID": "finding-{0}".format(index),
                "category": finding["category"],
                "text": _text(finding["text"]),
                "epistemicStatus": finding["status"],
                "sourceMessageIDs": _source_ids(
                    finding["source_message_ids"], known_ids
                ),
            }
        )

    addresses = []
    seen_addresses = set()
    for address_value in addresses_value:
        _exact_object(address_value, _ADDRESS_KEYS)
        address = address_value["address"]
        if not isinstance(address, str):
            raise MiniMaxError("invalid_response", False, None)
        normalized = address.lower() if address.lower().startswith("0x") else address
        evidence_item = evidence.get(normalized)
        if evidence_item is None:
            raise MiniMaxError("invalid_address_reference", False, None)
        if (
            not isinstance(address_value["status"], str)
            or address_value["status"] not in _EPISTEMIC_STATUSES
        ):
            raise MiniMaxError("invalid_response", False, None)
        source_ids = _source_ids(
            address_value["source_message_ids"],
            known_ids,
            frozenset(evidence_item["source_message_ids"]),
        )
        if not source_ids:
            raise MiniMaxError("invalid_response", False, None)
        if normalized in seen_addresses:
            raise MiniMaxError("invalid_response", False, None)
        seen_addresses.add(normalized)
        addresses.append(
            {
                "address": evidence_item["address"],
                "normalizedAddress": normalized,
                "contextSummary": _text(address_value["context_summary"]),
                "epistemicStatus": address_value["status"],
                "sourceMessageIDs": source_ids,
            }
        )

    result = {
        "summary": summary,
        "summarySourceMessageIDs": summary_ids,
        "topics": topics,
        "findings": findings,
        "cryptoAddresses": addresses,
    }
    if len(json.dumps(result, ensure_ascii=False).encode("utf-8")) > maximum_result_bytes:
        raise MiniMaxError("invalid_response", False, None)
    return result


class MiniMaxClient(object):
    def __init__(
        self,
        api_key,
        base_url=MAINLAND_BASE_URL,
        model=DEFAULT_MODEL,
        transport=None,
        _allow_insecure_loopback=False,
        _maximum_request_bytes=MAX_REQUEST_BYTES,
        _chunk_content_bytes=DEFAULT_CHUNK_CONTENT_BYTES,
    ):
        if not isinstance(api_key, str) or not api_key.strip():
            raise MiniMaxError("credential_unavailable", False, None)
        if not isinstance(model, str) or model != DEFAULT_MODEL:
            raise MiniMaxError("invalid_configuration", False, None)
        self.base_url = self._validated_base_url(
            base_url, _allow_insecure_loopback
        )
        if (
            isinstance(_maximum_request_bytes, bool)
            or not isinstance(_maximum_request_bytes, int)
            or _maximum_request_bytes <= 0
            or isinstance(_chunk_content_bytes, bool)
            or not isinstance(_chunk_content_bytes, int)
            or _chunk_content_bytes <= 0
        ):
            raise MiniMaxError("invalid_configuration", False, None)
        self.api_key = api_key.strip()
        self.model = DEFAULT_MODEL
        self.transport = transport or _default_transport
        self.maximum_request_bytes = min(_maximum_request_bytes, MAX_REQUEST_BYTES)
        self.chunk_content_bytes = min(
            _chunk_content_bytes, self.maximum_request_bytes
        )
        empty_synthesis = {
            "task": "synthesize_analyses",
            "cadence": "two_hour",
            "window_start": 0.0,
            "window_end": 1.0,
            "frozen_source_message_ids": [],
            "crypto_address_evidence": [],
            "analyses": [],
        }
        available = max(
            0, self.maximum_request_bytes - len(self._encoded_request(empty_synthesis))
        )
        self.maximum_projected_result_bytes = min(
            _MAX_PROJECTED_RESULT_BYTES, max(128, available // 4)
        )

    @staticmethod
    def _validated_base_url(value, allow_insecure_loopback):
        if not isinstance(value, str):
            raise MiniMaxError("invalid_configuration", False, None)
        parse_failed = False
        try:
            parsed = urllib.parse.urlsplit(value)
            parsed.port
        except ValueError:
            parse_failed = True
            parsed = None
        if parse_failed:
            raise MiniMaxError("invalid_configuration", False, None)
        if (
            not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.query
            or parsed.fragment
        ):
            raise MiniMaxError("invalid_configuration", False, None)
        path = parsed.path.rstrip("/")
        if parsed.scheme == "https":
            if (
                parsed.hostname != "api.minimaxi.com"
                or parsed.port is not None
                or path != "/anthropic"
            ):
                raise MiniMaxError("invalid_configuration", False, None)
            return MAINLAND_BASE_URL
        else:
            loopback = False
            if parsed.scheme == "http" and allow_insecure_loopback:
                try:
                    loopback = ipaddress.ip_address(parsed.hostname).is_loopback
                except ValueError:
                    loopback = parsed.hostname == "localhost"
            if not loopback:
                raise MiniMaxError("invalid_configuration", False, None)
        return urllib.parse.urlunsplit(
            (parsed.scheme, parsed.netloc, path, "", "")
        )

    def _request_body(self, system_prompt, input_document):
        return {
            "model": self.model,
            "max_tokens": 8192,
            "stream": False,
            "system": system_prompt,
            "messages": [
                {
                    "role": "user",
                    "content": json.dumps(input_document, ensure_ascii=False),
                }
            ],
        }

    def _encoded_request(self, input_document):
        body = self._request_body(_SYSTEM_PROMPT, input_document)
        encoding_failed = False
        try:
            encoded = json.dumps(
                body, ensure_ascii=False, separators=(",", ":")
            ).encode("utf-8")
        except (TypeError, ValueError, UnicodeEncodeError):
            encoding_failed = True
            encoded = None
        if encoding_failed:
            raise MiniMaxError("request_invalid", False, None)
        return encoded

    def _request_fits(self, input_document):
        return len(self._encoded_request(input_document)) <= self.maximum_request_bytes

    def _guard_provider_value(self, value):
        pending = [value]
        while pending:
            item = pending.pop()
            if isinstance(item, str):
                if self.api_key in item:
                    raise MiniMaxError("invalid_response", False, None)
            elif isinstance(item, dict):
                pending.extend(item.keys())
                pending.extend(item.values())
            elif isinstance(item, (list, tuple)):
                pending.extend(item)
        return value

    def _open(self, request):
        failure = None
        try:
            if callable(self.transport):
                response = self.transport(request, timeout=_TIMEOUT_SECONDS)
            else:
                response = self.transport.open(request, timeout=_TIMEOUT_SECONDS)
        except urllib.error.HTTPError as error:
            failure = _error_for_status(error.code, error.headers)
            error.close()
            response = None
        except MiniMaxError as error:
            failure = MiniMaxError(error.code, error.retryable, error.retry_after)
            response = None
        except Exception:
            failure = MiniMaxError("transport_error", True, None)
            response = None
        if failure is not None:
            raise failure
        return response

    def _post(self, input_document):
        encoded = self._encoded_request(input_document)
        if len(encoded) > self.maximum_request_bytes:
            raise MiniMaxError("request_invalid", False, None)
        request = urllib.request.Request(
            self.base_url + "/v1/messages",
            data=encoded,
            headers={
                "Content-Type": "application/json",
                "X-Api-Key": self.api_key,
                "anthropic-version": "2023-06-01",
            },
            method="POST",
        )
        response = self._open(request)
        failure = None
        try:
            status = getattr(response, "status", None)
            if status is None:
                status = response.getcode()
            headers = getattr(response, "headers", None)
            if not 200 <= int(status) < 300:
                raise _error_for_status(int(status), headers)
            raw = _read_bounded(response, MAX_RESPONSE_BYTES)
        except MiniMaxError as error:
            failure = MiniMaxError(error.code, error.retryable, error.retry_after)
            raw = None
        except Exception:
            failure = MiniMaxError("transport_error", True, None)
            raw = None
        finally:
            try:
                response.close()
            except Exception:
                pass
        if failure is not None:
            raise failure
        decoding_failed = False
        try:
            envelope = json.loads(
                raw.decode("utf-8"),
                parse_constant=lambda unused: (_ for _ in ()).throw(ValueError()),
                object_pairs_hook=_unique_json_object,
            )
        except (RecursionError, UnicodeDecodeError, TypeError, ValueError):
            decoding_failed = True
            envelope = None
        if decoding_failed:
            raise MiniMaxError("invalid_response", False, None)
        if not isinstance(envelope, dict):
            raise MiniMaxError("invalid_response", False, None)
        provider_request_id = _safe_request_id(
            _header(headers, "x-request-id") or _header(headers, "request-id")
        )
        if provider_request_id is not None:
            self._guard_provider_value(provider_request_id)
        usage = envelope.get("usage")
        input_tokens = None
        output_tokens = None
        if isinstance(usage, dict):
            input_tokens = self._token_count(usage.get("input_tokens"))
            output_tokens = self._token_count(usage.get("output_tokens"))
        return envelope, provider_request_id, input_tokens, output_tokens

    @staticmethod
    def _token_count(value):
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            return None
        return value

    @staticmethod
    def _response_text(envelope):
        content = envelope.get("content")
        if not isinstance(content, list) or len(content) > _MAX_RESULT_ITEMS:
            raise MiniMaxError("invalid_response", False, None)
        texts = []
        for block in content:
            if not isinstance(block, dict):
                raise MiniMaxError("invalid_response", False, None)
            if block.get("type") == "text":
                text = block.get("text")
                if not isinstance(text, str):
                    raise MiniMaxError("invalid_response", False, None)
                texts.append(text)
        if not texts:
            raise MiniMaxError("invalid_response", False, None)
        return "".join(texts)

    def _analyze_document(self, document, known_ids, evidence):
        current_document = document
        original_failure = None
        usage = []
        for attempt in range(2):
            # Network and envelope failures retain their scheduling classification.
            # Never send an untrusted previous answer back as a repair instruction.
            response_failure = None
            try:
                envelope, request_id, input_tokens, output_tokens = self._post(current_document)
                usage.append((input_tokens, output_tokens))
                model_text = self._guard_provider_value(self._response_text(envelope))
            except MiniMaxError as error:
                response_failure = MiniMaxError(error.code, error.retryable, error.retry_after)
            if response_failure is not None:
                if original_failure is not None and response_failure.code == "invalid_response":
                    raise original_failure
                raise response_failure
            validation_failure = None
            try:
                model_value = _strict_json(model_text, allow_missing_wrapper=envelope.get('stop_reason') == 'end_turn')
            except MiniMaxError as error:
                validation_failure = MiniMaxError(error.code, False, None)
            if validation_failure is None:
                # Decode JSON escapes before checking reflected secrets. This
                # guard must terminate, not enter the format-repair path.
                self._guard_provider_value(model_value)
                try:
                    # Stable JSON mode shares the bounded format repair, but
                    # never accepts fences or the legacy result envelope.
                    if envelope.get('stop_reason') == 'json_complete' and (
                        not model_text.lstrip().startswith('{')
                        or not isinstance(model_value, dict)
                        or set(model_value) != {'briefing'}
                    ):
                        raise MiniMaxError('invalid_response', False, None)
                    result = _validated_result(
                        model_value, known_ids, evidence,
                        self.maximum_projected_result_bytes,
                    )
                except MiniMaxError as error:
                    validation_failure = MiniMaxError(error.code, False, None,
                                                      validation_detail=error.validation_detail)
            if validation_failure is None:
                self._guard_provider_value(result)
                return AnalysisOutcome(
                    result, self.model, request_id,
                    self._usage_total(row[0] for row in usage),
                    self._usage_total(row[1] for row in usage),
                )
            if original_failure is None:
                original_failure = validation_failure
            if attempt or validation_failure.code not in (
                "invalid_response", "invalid_source_reference", "invalid_address_reference"
            ):
                raise original_failure
            current_document = dict(document, validation_feedback=validation_failure.code)
            if validation_failure.validation_detail is not None:
                current_document['validation_detail'] = validation_failure.validation_detail
            if not self._request_fits(current_document):
                raise original_failure

    @staticmethod
    def _ordered_ids(items):
        result = []
        for item in items:
            event_id = item["eventId"]
            if event_id not in result:
                result.append(event_id)
        return result

    @staticmethod
    def _evidence_for_ids(evidence, source_ids, address_keys=None):
        allowed = frozenset(source_ids)
        allowed_addresses = (
            None if address_keys is None else frozenset(address_keys)
        )
        filtered = {}
        for key, item in evidence.items():
            if allowed_addresses is not None and key not in allowed_addresses:
                continue
            context_ids = [
                event_id
                for event_id in item["source_message_ids"]
                if event_id in allowed
            ]
            if context_ids:
                filtered[key] = {
                    "address": item["address"],
                    "source_message_ids": context_ids,
                    "verbatim_sources": {raw: [i for i in ids if i in allowed]
                        for raw, ids in item.get('verbatim_sources', {}).items()},
                }
        return filtered

    @staticmethod
    def _evidence_document(evidence):
        result = []
        for item in evidence.values():
            variants = [(raw, ids) for raw, ids in item.get('verbatim_sources', {}).items() if ids]
            # Context-only legacy evidence stays explicit. Each spelling is sent
            # once, so address-heavy inputs still fit the bounded request budget.
            for raw, direct_ids in variants or [(item['address'], [])]:
                result.append(dict(address=raw, direct_source_message_ids=direct_ids,
                                   context_source_message_ids=item['source_message_ids']))
        return result

    @staticmethod
    def _result_source_ids(result):
        source_ids = []
        references = [result["summarySourceMessageIDs"]]
        references.extend(item["sourceMessageIDs"] for item in result["topics"])
        references.extend(item["sourceMessageIDs"] for item in result["findings"])
        references.extend(
            item["sourceMessageIDs"] for item in result["cryptoAddresses"]
        )
        if 'briefing' in result:
            references.append(briefing_references(result['briefing']))
        for referenced_ids in references:
            for event_id in referenced_ids:
                if event_id not in source_ids:
                    source_ids.append(event_id)
        return source_ids

    @staticmethod
    def _result_address_keys(result):
        return [
            item["normalizedAddress"] for item in result["cryptoAddresses"]
        ]

    def _work_item(self, outcome):
        return {
            "outcome": outcome,
            "source_ids": self._result_source_ids(outcome.result),
            "address_keys": self._result_address_keys(outcome.result),
        }

    def _message_document(self, items, cadence, window_start, window_end, evidence):
        source_ids = self._ordered_ids(items)
        local_evidence = self._evidence_for_ids(evidence, source_ids)
        return {
            "task": "analyze_message_chunk",
            "cadence": cadence,
            "window_start": float(window_start),
            "window_end": float(window_end),
            "frozen_source_message_ids": source_ids,
            "crypto_address_evidence": self._evidence_document(local_evidence),
            "messages": items,
        }, local_evidence, source_ids

    @staticmethod
    def _segment(item, content, index, count):
        segment = copy.deepcopy(item)
        segment["content"] = content
        segment["segmentIndex"] = index
        segment["segmentCount"] = count
        return segment

    def _segments_for_message(
        self, item, cadence, window_start, window_end, evidence
    ):
        plain_document, unused_evidence, unused_ids = self._message_document(
            [item], cadence, window_start, window_end, evidence
        )
        content = item["content"]
        encoding_failed = False
        try:
            content_bytes = len(content.encode("utf-8"))
        except UnicodeEncodeError:
            encoding_failed = True
            content_bytes = None
        if encoding_failed:
            raise MiniMaxError("request_invalid", False, None)
        if (
            content_bytes <= self.chunk_content_bytes
            and self._request_fits(plain_document)
        ):
            return [item]
        if not content:
            raise MiniMaxError("request_invalid", False, None)

        initial_parts = _utf8_parts(content, self.chunk_content_bytes)
        marker = max(1, len(content))
        parts = []
        for initial in initial_parts:
            remaining = initial
            while remaining:
                low = 1
                high = len(remaining)
                fitting = 0
                while low <= high:
                    middle = (low + high) // 2
                    trial = self._segment(
                        item, remaining[:middle], marker, marker
                    )
                    document, unused_evidence, unused_ids = self._message_document(
                        [trial], cadence, window_start, window_end, evidence
                    )
                    if self._request_fits(document):
                        fitting = middle
                        low = middle + 1
                    else:
                        high = middle - 1
                if fitting == 0:
                    raise MiniMaxError("request_invalid", False, None)
                parts.append(remaining[:fitting])
                remaining = remaining[fitting:]

        segments = [
            self._segment(item, part, index, len(parts))
            for index, part in enumerate(parts, 1)
        ]
        for segment in segments:
            document, unused_evidence, unused_ids = self._message_document(
                [segment], cadence, window_start, window_end, evidence
            )
            if not self._request_fits(document):
                raise MiniMaxError("request_invalid", False, None)
        return segments

    def _request_sized_message_chunks(
        self, messages, cadence, window_start, window_end, evidence
    ):
        expanded = []
        for message in messages:
            expanded.extend(
                self._segments_for_message(
                    message, cadence, window_start, window_end, evidence
                )
            )
        chunks = []
        current = []
        current_content_bytes = 0
        for item in expanded:
            item_content_bytes = len(item["content"].encode("utf-8"))
            candidate = current + [item]
            document, unused_evidence, unused_ids = self._message_document(
                candidate, cadence, window_start, window_end, evidence
            )
            if (
                current_content_bytes + max(1, item_content_bytes)
                <= self.chunk_content_bytes
                and len(candidate) <= _MESSAGE_BATCH_SIZE
                and self._request_fits(document)
            ):
                current = candidate
                current_content_bytes += max(1, item_content_bytes)
                continue
            if not current:
                raise MiniMaxError("request_invalid", False, None)
            chunks.append(current)
            current = [item]
            current_content_bytes = max(1, item_content_bytes)
        if current:
            chunks.append(current)
        return chunks

    def _synthesis_document(
        self, batch, cadence, window_start, window_end, evidence
    ):
        source_ids = []
        address_keys = []
        for item in batch:
            for event_id in item["source_ids"]:
                if event_id not in source_ids:
                    source_ids.append(event_id)
            for address_key in item["address_keys"]:
                if address_key not in address_keys:
                    address_keys.append(address_key)
        local_evidence = self._evidence_for_ids(
            evidence, source_ids, address_keys
        )
        document = {
            "task": "synthesize_analyses",
            "cadence": cadence,
            "window_start": float(window_start),
            "window_end": float(window_end),
            "frozen_source_message_ids": source_ids,
            "crypto_address_evidence": self._evidence_document(local_evidence),
            "analyses": [item["outcome"].result for item in batch],
        }
        return document, local_evidence, source_ids

    @staticmethod
    def _usage_total(values):
        values = list(values)
        return None if any(value is None for value in values) else sum(values)

    def _restore_capture_ids(self, outcome, mapping):
        if not mapping:
            return outcome
        def restore(value):
            if isinstance(value, list):
                return [restore(item) for item in value]
            if isinstance(value, dict):
                result = {}
                for key, child in value.items():
                    if key in ('source_message_ids', 'sourceMessageIDs', 'summarySourceMessageIDs'):
                        if any(item not in mapping for item in child):
                            raise MiniMaxError('invalid_source_reference', False, None)
                        result[key] = [mapping[item] for item in child]
                    else:
                        result[key] = restore(child)
                return result
            return value
        return outcome._replace(result=self._guard_provider_value(restore(outcome.result)))

    def analyze_window(self, messages, cadence=None, window_start=None, window_end=None):
        default_window = cadence is None and window_start is None and window_end is None
        if default_window:
            window_end = time.time()
            window_start = window_end - 12 * 3600
        if cadence not in (None, "two_hour", "six_hour", "daily"):
            raise MiniMaxError("request_invalid", False, None)
        normalized_start = _finite_number(window_start)
        normalized_end = _finite_number(window_end)
        if normalized_start is None or normalized_end is None:
            raise MiniMaxError("request_invalid", False, None)
        if normalized_start >= normalized_end:
            raise MiniMaxError("request_invalid", False, None)
        if not isinstance(messages, (list, tuple)):
            raise MiniMaxError("request_invalid", False, None)
        projected = [_project_message(item) for item in messages]
        if default_window:
            projected = [item for item in projected if normalized_start <= item['observedAt'] < normalized_end]
        projected.sort(key=_sort_key)
        if not projected:
            raise MiniMaxError("request_invalid", False, None)
        event_ids = [item["eventId"] for item in projected]
        if len(set(event_ids)) != len(event_ids):
            raise MiniMaxError("request_invalid", False, None)
        # Long capture hashes are expensive and error-prone to reproduce. A
        # window-local bijection keeps every source while shortening only IDs.
        # Already-short caller IDs remain supported; persisted IDs never change.
        capture_ids = {}
        if any(len(event_id) > 12 for event_id in event_ids):
            for index, item in enumerate(projected, 1):
                alias = 'M{:04d}'.format(index)
                capture_ids[alias] = item['eventId']
                item['eventId'] = alias
        evidence = _address_evidence(projected)
        work = []
        usage = []
        chunks = self._request_sized_message_chunks(
            projected, cadence, normalized_start, normalized_end, evidence
        )
        for chunk in chunks:
            document, local_evidence, source_ids = self._message_document(
                chunk, cadence, normalized_start, normalized_end, evidence
            )
            outcome = self._analyze_document(document, frozenset(source_ids), local_evidence)
            work.append(self._work_item(outcome))
            usage.append((outcome.input_tokens, outcome.output_tokens))

        if len(work) == 1:
            return self._restore_capture_ids(work[0]["outcome"], capture_ids)
        while len(work) > 1:
            batches = []
            current = []
            for item in work:
                candidate = current + [item]
                document, unused_evidence, unused_ids = self._synthesis_document(
                    candidate, cadence, normalized_start, normalized_end, evidence
                )
                if len(candidate) <= _SYNTHESIS_BATCH_SIZE and self._request_fits(document):
                    current = candidate
                    continue
                if current:
                    batches.append(current)
                    current = [item]
                else:
                    raise MiniMaxError("request_invalid", False, None)
            if current:
                batches.append(current)
            if all(len(batch) == 1 for batch in batches):
                raise MiniMaxError("request_invalid", False, None)

            merged = []
            for batch in batches:
                if len(batch) == 1:
                    merged.append(batch[0])
                    continue
                document, local_evidence, source_ids = self._synthesis_document(
                    batch, cadence, normalized_start, normalized_end, evidence
                )
                outcome = self._analyze_document(document, frozenset(source_ids), local_evidence)
                merged.append(self._work_item(outcome))
                usage.append((outcome.input_tokens, outcome.output_tokens))
            work = merged
        return self._restore_capture_ids(work[0]["outcome"]._replace(
            input_tokens=self._usage_total(row[0] for row in usage),
            output_tokens=self._usage_total(row[1] for row in usage),
        ), capture_ids)

    def test_connection(self):
        envelope, request_id, unused_input, unused_output = self._post(
            {
                "task": "connection_test",
                "instruction": "Return a short acknowledgement.",
            }
        )
        self._guard_provider_value(self._response_text(envelope))
        result = {"model": self.model}
        if request_id is not None:
            result["providerRequestId"] = request_id
        return result

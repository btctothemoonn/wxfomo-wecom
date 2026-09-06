"""DeepSeek JSON output with shared bounded chunking and local evidence checks.

Use the stable JSON endpoint verified with a complete real window. The strict
Beta tool endpoint returned malformed arguments during this integration; no
automatic retry against another provider or output mode is performed.
"""

import json
import urllib.request

from .minimax import (
    DEFAULT_CHUNK_CONTENT_BYTES, MAX_REQUEST_BYTES, MAX_RESPONSE_BYTES,
    MiniMaxClient, MiniMaxError, _error_for_status, _header, _read_bounded,
    _safe_request_id, _unique_json_object,
)


BASE_URL = 'https://api.deepseek.com'
DEFAULT_MODEL = 'deepseek-v4-flash'

# JSON mode guarantees syntax, not this application's semantic contract. Keep
# these cross-field constraints next to the output instruction, including on
# the one bounded repair. Never coerce mixed sections or invent missing cites.
_JSON_CHECKLIST = '''
Before returning JSON, check ALL of these conditions, not only validation_feedback:
1. Pick exactly ONE output kind based on the actual discussion, not the presence of an address. Crypto/market discussion without a CA is still market.
2. kind=business: projects=[] AND events=[]. Put supported business events in progress/notices/blockers/tasks, not events.
3. kind=market: business={"progress":[],"notices":[],"blockers":[],"tasks":[]}.
4. Every gaps item describes a SPECIFIC supplied record and cites its actual local ID(s). NEVER leave a substantive gap with [] citations. General collection limitations are already displayed by the application; do not add uncited generic disclaimers to gaps. If no record-specific gap exists use gaps=[]. Do not fabricate a citation to fill this field.
5. A missing optional scalar is "未提供" (chain: "未确认"), never null/false. A missing list is []. All required keys must exist. Each address.chain must equal its containing project.chain; use separate projects for different chains/addresses.
6. Recheck every citation against frozen_source_message_ids and retain only conclusions actually supported by supplied records. The final JSON is exactly {"briefing":{...}} with no extra brace or text.
'''


class DeepSeekClient(MiniMaxClient):
    def __init__(self, api_key, base_url=BASE_URL, model=DEFAULT_MODEL,
                 transport=None, _maximum_request_bytes=MAX_REQUEST_BYTES,
                 _chunk_content_bytes=DEFAULT_CHUNK_CONTENT_BYTES):
        if not isinstance(model, str) or model != DEFAULT_MODEL:
            raise MiniMaxError('invalid_configuration', False, None)
        # The parent validates its own model only. Its initialization is reused
        # for credentials and finite limits; our request encoder always uses the
        # validated DeepSeek model, including the parent's size-budget probe.
        super().__init__(api_key, base_url=base_url, transport=transport,
                         _maximum_request_bytes=_maximum_request_bytes,
                         _chunk_content_bytes=_chunk_content_bytes)
        self.model = DEFAULT_MODEL

    @staticmethod
    def _validated_base_url(value, allow_insecure_loopback):
        if value != BASE_URL:
            raise MiniMaxError('invalid_configuration', False, None)
        return BASE_URL

    def _request_body(self, system_prompt, input_document):
        return {
            'model': DEFAULT_MODEL, 'max_tokens': 8192, 'stream': False,
            'thinking': {'type': 'disabled'},
            'response_format': {'type': 'json_object'},
            'messages': [
                {'role': 'system', 'content': system_prompt + _JSON_CHECKLIST},
                {'role': 'user', 'content': json.dumps(input_document, ensure_ascii=False)},
            ],
        }

    def _json_content(self, envelope):
        self._guard_provider_value(envelope)
        choices = envelope.get('choices')
        if not isinstance(choices, list) or len(choices) != 1:
            raise MiniMaxError('invalid_response', False, None)
        choice = choices[0]
        if not isinstance(choice, dict) or choice.get('finish_reason') != 'stop':
            raise MiniMaxError('invalid_response', False, None)
        message = choice.get('message')
        if (not isinstance(message, dict) or message.get('role') != 'assistant'
                or message.get('tool_calls')):
            raise MiniMaxError('invalid_response', False, None)
        arguments = message.get('content')
        if not isinstance(arguments, str):
            raise MiniMaxError('invalid_response', False, None)
        # A complete stop envelope can carry malformed model JSON. The shared
        # validation stage owns its one repair, using only the original input.
        return arguments

    def _post(self, input_document):
        encoded = self._encoded_request(input_document)
        if len(encoded) > self.maximum_request_bytes:
            raise MiniMaxError('request_invalid', False, None)
        request = urllib.request.Request(
            self.base_url + '/chat/completions', data=encoded,
            headers={'Content-Type': 'application/json',
                     'Authorization': 'Bearer ' + self.api_key}, method='POST')
        # The shared default transport rejects redirects and has a finite wait.
        response = self._open(request)
        failure = None
        try:
            status = getattr(response, 'status', None)
            if status is None:
                status = response.getcode()
            headers = getattr(response, 'headers', None)
            if not 200 <= int(status) < 300:
                raise _error_for_status(int(status), headers)
            raw = _read_bounded(response, MAX_RESPONSE_BYTES)
        except MiniMaxError as error:
            failure = MiniMaxError(error.code, error.retryable, error.retry_after)
            raw = None
        except Exception:
            failure = MiniMaxError('transport_error', True, None)
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
            envelope = json.loads(raw.decode('utf-8'),
                parse_constant=lambda unused: (_ for _ in ()).throw(ValueError()),
                object_pairs_hook=_unique_json_object)
        except (RecursionError, UnicodeDecodeError, TypeError, ValueError):
            decoding_failed = True
            envelope = None
        if decoding_failed or not isinstance(envelope, dict):
            raise MiniMaxError('invalid_response', False, None)
        arguments = self._json_content(envelope)
        request_id = _safe_request_id(_header(headers, 'x-request-id') or
                                      _header(headers, 'request-id'))
        self._guard_provider_value(request_id)
        usage = envelope.get('usage')
        usage = usage if isinstance(usage, dict) else {}
        # JSON mode is never eligible for the Anthropic wrapper recovery path.
        normalized = {'stop_reason': 'json_complete',
                      'content': [{'type': 'text', 'text': arguments}]}
        return (normalized, request_id, self._token_count(usage.get('prompt_tokens')),
                self._token_count(usage.get('completion_tokens')))

    def test_connection(self):
        outcome = self.analyze_window([{
            'eventId': 'connection', 'groupName': '合成测试',
            'senderDisplayName': '合成测试', 'messageType': 'text',
            'content': '这是合成连接测试，不包含真实群消息。', 'observedAt': 0.0,
        }], 'two_hour', 0.0, 7200.0)
        result = {'model': self.model}
        if outcome.provider_request_id is not None:
            result['providerRequestId'] = outcome.provider_request_id
        return result

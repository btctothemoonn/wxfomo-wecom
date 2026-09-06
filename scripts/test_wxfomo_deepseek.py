import copy
import io
import json
import unittest
import urllib.error

from scripts.test_wxfomo_briefing import ADDRESS, briefing_payload, note
from scripts.test_wxfomo_minimax import FakeResponse, message, result_payload
from scripts.wxfomo_lan.deepseek import DeepSeekClient
from scripts.wxfomo_lan.minimax import MAX_RESPONSE_BYTES, MiniMaxError


def envelope(payload=None, arguments=None):
    return {'model': 'deepseek-v4-flash', 'choices': [{'finish_reason': 'stop', 'message': {
        'role': 'assistant', 'content': arguments if arguments is not None else
        json.dumps(payload if payload is not None else briefing_payload())}}],
        'usage': {'prompt_tokens': 12, 'completion_tokens': 7}}


def small_payload(ids):
    return {'briefing': {'version': 2, 'kind': 'market',
        'quick_read': {'focus': note('已收到合成进展', ids[:1]), 'news': note(), 'risk': note()},
        'projects': [], 'events': [], 'gaps': [],
        'business': {'progress': [], 'notices': [], 'blockers': [], 'tasks': []}}}


class DeepSeekTests(unittest.TestCase):
    def client(self, transport=None, **kwargs):
        return DeepSeekClient('test-only-deepseek-key', transport=transport, **kwargs)

    def analyze(self, client):
        return client.analyze_window([message('e1', 'CA ' + ADDRESS, 1),
                                      message('e2', '风险 [图片]', 2)], 'two_hour', 0, 7200)

    def test_default_uses_verified_stable_json_mode_not_beta_tools(self):
        calls = []
        def transport(request, timeout):
            calls.append(request)
            self.assertTrue(0 < timeout <= 180)
            return FakeResponse(200, envelope(), {'x-request-id': 'safe-request-1'})
        outcome = self.analyze(self.client(transport))
        self.assertEqual(outcome.result['briefing'], briefing_payload()['briefing'])
        self.assertEqual(outcome.model, 'deepseek-v4-flash')
        self.assertEqual((outcome.input_tokens, outcome.output_tokens), (12, 7))
        self.assertEqual(outcome.provider_request_id, 'safe-request-1')
        self.assertEqual(calls[0].full_url, 'https://api.deepseek.com/chat/completions')
        self.assertEqual(calls[0].get_header('Authorization'), 'Bearer test-only-deepseek-key')
        self.assertIsNone(calls[0].get_header('X-api-key'))
        body = json.loads(calls[0].data)
        self.assertEqual(body['response_format'], {'type': 'json_object'})
        self.assertEqual(body['thinking'], {'type': 'disabled'})
        self.assertNotIn('tools', body)
        self.assertEqual(body['stream'], False)
        self.assertLessEqual(body['max_tokens'], 8192)
        self.assertEqual([item['role'] for item in body['messages']], ['system', 'user'])

    def test_json_prompt_enforces_exclusive_sections_and_cited_gaps(self):
        body = self.client()._request_body('trusted summary rules', {'task': 'analyze_message_chunk'})
        prompt = body['messages'][0]['content']
        self.assertIn('kind=business: projects=[] AND events=[]', prompt)
        self.assertIn('kind=market: business=', prompt)
        self.assertIn('gaps=[]', prompt)
        self.assertIn('NEVER leave a substantive gap with [] citations', prompt)
        self.assertTrue(prompt.startswith('trusted summary rules'))

    def test_foreign_hosts_insecure_urls_and_other_models_are_rejected(self):
        for url in ('https://api.deepseek.com.evil', 'https://evil.invalid',
                    'http://api.deepseek.com', 'https://api.deepseek.com?x=1',
                    'https://user@api.deepseek.com', 'https://api.deepseek.com:443',
                    'https://api.deepseek.com/beta', 'http://127.0.0.1'):
            with self.subTest(url=url), self.assertRaisesRegex(MiniMaxError, 'invalid_configuration'):
                self.client(base_url=url)
        with self.assertRaisesRegex(MiniMaxError, 'invalid_configuration'):
            self.client(model='MiniMax-M2.7')

    def test_incomplete_or_mixed_envelopes_are_rejected_without_repair(self):
        responses = []
        for reason in ('length', 'tool_calls', 'content_filter', None):
            item = envelope()
            item['choices'][0]['finish_reason'] = reason
            responses.append(item)
        item = envelope()
        item['choices'][0]['message']['tool_calls'] = [{'function': {'name': 'execute_shell'}}]
        responses.append(item)
        item = envelope()
        item['choices'].append(copy.deepcopy(item['choices'][0]))
        responses.append(item)
        for content in (None, {}, []):
            item = envelope()
            item['choices'][0]['message']['content'] = content
            responses.append(item)
        for index, item in enumerate(responses):
            calls = []
            def transport(request, timeout):
                calls.append(request)
                return FakeResponse(200, item)
            with self.subTest(case=index), self.assertRaisesRegex(MiniMaxError, 'invalid_response'):
                self.analyze(self.client(transport))
            self.assertEqual(len(calls), 1)

    def test_stop_json_format_failure_gets_one_safe_repair(self):
        # A complete HTTP/stop envelope must not bypass the existing repair
        # simply because its body fails before semantic briefing validation.
        payload = briefing_payload()
        payload['briefing']['quick_read']['focus']['text'] = 'discarded-provider-answer'
        malformed = json.dumps(payload)[:-1]
        wrong_shape = json.dumps({'unexpected': 'discarded-provider-answer'})
        for raw in (malformed, wrong_shape):
            calls = []
            def transport(request, timeout):
                calls.append(json.loads(json.loads(request.data)['messages'][1]['content']))
                return FakeResponse(200, envelope(arguments=raw) if len(calls) == 1 else envelope())
            with self.subTest(body=raw[:20]):
                try:
                    outcome = self.analyze(self.client(transport))
                except MiniMaxError as error:
                    self.fail('complete stop response did not get its format repair: {}'.format(error.code))
                self.assertEqual(outcome.result['briefing'], briefing_payload()['briefing'])
                self.assertEqual((outcome.input_tokens, outcome.output_tokens), (24, 14))
                self.assertEqual(len(calls), 2)
                self.assertEqual(calls[1], dict(calls[0], validation_feedback='invalid_response'))
                self.assertNotIn('discarded-provider-answer', json.dumps(calls[1]))

    def test_repeated_stop_json_failures_are_never_accepted_or_retried_again(self):
        # JSON mode must not accept wrapper recovery, fences, or the shared
        # validator's legacy format when moving parsing into the repair loop.
        raw_cases = (
            '', '{}', '{"briefing":', '{"briefing":{},"briefing":{}}',
            '{"briefing":{"version":NaN}}', json.dumps(briefing_payload()) + '}',
            json.dumps(briefing_payload())[:-1], json.dumps(briefing_payload()) + '{}',
            '```json\n' + json.dumps(briefing_payload()) + '\n```',
            json.dumps(result_payload(['e1'])), json.dumps([briefing_payload()]),
            json.dumps(dict(briefing_payload(), unexpected='untrusted')),
        )
        for index, raw in enumerate(raw_cases):
            calls = []
            def transport(request, timeout):
                calls.append(request)
                return FakeResponse(200, envelope(arguments=raw))
            with self.subTest(case=index), self.assertRaisesRegex(MiniMaxError, 'invalid_response'):
                self.analyze(self.client(transport))
            self.assertEqual(len(calls), 2)

    def test_syntax_repair_does_not_restart_the_semantic_repair_budget(self):
        # Separate JSON and citation loops would accidentally allow a third call.
        payload = briefing_payload()
        payload['briefing']['quick_read']['focus']['source_message_ids'] = ['invented']
        calls = []
        def transport(request, timeout):
            calls.append(request)
            return FakeResponse(200, envelope(arguments='{"briefing":') if len(calls) == 1 else envelope(payload))
        with self.assertRaisesRegex(MiniMaxError, 'invalid_response'):
            self.analyze(self.client(transport))
        self.assertEqual(len(calls), 2)

    def test_malformed_http_json_envelopes_are_not_repaired(self):
        # A broken transport envelope cannot prove stop/assistant and is not a body repair.
        for raw in (b'{', b'[]', b'{"choices":[],"choices":[]}', b'\xff'):
            calls = []
            def transport(request, timeout):
                calls.append(request)
                return FakeResponse(200, None, raw=raw)
            with self.subTest(raw=repr(raw)), self.assertRaisesRegex(MiniMaxError, 'invalid_response'):
                self.analyze(self.client(transport))
            self.assertEqual(len(calls), 1)

    def test_unknown_ids_and_invented_addresses_get_only_one_safe_repair(self):
        for expected, mutate in (
                ('invalid_source_reference', lambda item: item['quick_read']['focus'].update(source_message_ids=['invented'])),
                ('invalid_address_reference', lambda item: item['projects'][0]['addresses'][0].update(address=ADDRESS.lower()))):
            payload = briefing_payload()
            mutate(payload['briefing'])
            calls = []
            def transport(request, timeout):
                calls.append(json.loads(json.loads(request.data)['messages'][1]['content']))
                return FakeResponse(200, envelope(payload))
            with self.assertRaisesRegex(MiniMaxError, expected):
                self.analyze(self.client(transport))
            self.assertEqual(len(calls), 2)
            self.assertEqual(calls[1]['validation_feedback'], expected)
            self.assertEqual(calls[0]['messages'], calls[1]['messages'])
            self.assertNotIn('invented', json.dumps(calls[1]))

    def test_reflected_key_in_any_field_is_redacted_without_repair(self):
        items = []
        item = envelope()
        item['choices'][0]['message']['reasoning_content'] = 'test-only-deepseek-key'
        items.append(item)
        payload = briefing_payload()
        payload['briefing']['quick_read']['focus']['text'] = 'test-only-deepseek-key'
        items.append(envelope(payload))
        items.append(envelope(arguments=json.dumps(payload).replace('test-only', '\\u0074est-only')))
        # The decoded-secret guard must run before a repairable shape rejection.
        wrong_shape = json.dumps({'unexpected': 'test-only-deepseek-key'}).replace('test-only', '\\u0074est-only')
        items.append(envelope(arguments=wrong_shape))
        items.append(envelope(arguments=json.dumps(payload)[:-1]))
        for item in items:
            calls = []
            def transport(request, timeout):
                calls.append(request)
                return FakeResponse(200, item)
            with self.assertRaises(MiniMaxError) as caught:
                self.analyze(self.client(transport))
            self.assertNotIn('test-only-deepseek-key', repr(caught.exception))
            self.assertIsNone(caught.exception.__context__)
            self.assertEqual(len(calls), 1)

    def test_status_errors_and_oversized_responses_are_bounded(self):
        for status, code, retryable in ((401, 'credential_unavailable', False),
                                       (429, 'rate_limited', True), (503, 'provider_unavailable', True),
                                       (302, 'request_invalid', False)):
            def transport(request, timeout):
                raise urllib.error.HTTPError(request.full_url, status, 'private-provider-body',
                                             {'Retry-After': '12'}, io.BytesIO(b'private-provider-body'))
            with self.subTest(status=status), self.assertRaises(MiniMaxError) as caught:
                self.analyze(self.client(transport))
            self.assertEqual(caught.exception.code, code)
            self.assertEqual(caught.exception.retryable, retryable)
            self.assertNotIn('private', repr(caught.exception))
            self.assertIsNone(caught.exception.__context__)
        with self.assertRaisesRegex(MiniMaxError, 'invalid_response'):
            self.analyze(self.client(lambda request, timeout: FakeResponse(200, None, raw=b' ' * (MAX_RESPONSE_BYTES + 1))))

    def test_chunks_keep_every_message_and_restore_capture_ids(self):
        captured, tasks = [], []
        def transport(request, timeout):
            self.assertLessEqual(len(request.data), 512 * 1024)
            document = json.loads(json.loads(request.data)['messages'][1]['content'])
            tasks.append(document['task'])
            captured.extend(item['content'] for item in document.get('messages', []))
            return FakeResponse(200, envelope(small_payload(document['frozen_source_message_ids'])))
        messages = [message('notification-capture-id-{}'.format(i), '项目进展 {}'.format(i), i) for i in range(350)]
        result = self.client(transport).analyze_window(messages, 'two_hour', 0, 7200)
        self.assertEqual(captured, [item['content'] for item in messages])
        self.assertEqual(tasks, ['analyze_message_chunk', 'analyze_message_chunk', 'synthesize_analyses'])
        self.assertEqual(result.result['briefing']['quick_read']['focus']['source_message_ids'], ['notification-capture-id-0'])

    def test_connection_uses_only_synthetic_input(self):
        calls = []
        def transport(request, timeout):
            document = json.loads(json.loads(request.data)['messages'][1]['content'])
            calls.append(document)
            return FakeResponse(200, envelope(small_payload(document['frozen_source_message_ids'])))
        result = self.client(transport).test_connection()
        self.assertEqual(result['model'], 'deepseek-v4-flash')
        self.assertEqual(calls[0]['messages'][0]['eventId'], 'connection')
        self.assertEqual(len(calls), 1)

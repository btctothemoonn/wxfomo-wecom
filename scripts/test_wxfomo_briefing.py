import copy
import json
import socket
import unittest
from unittest import mock

from scripts.test_wxfomo_minimax import FakeResponse, message
from scripts.wxfomo_lan.minimax import MiniMaxClient, MiniMaxError
from scripts.wxfomo_lan.analysis import _project_result


ADDRESS = '0x' + 'aB' * 20


def note(text='未提供', ids=None):
    return dict(text=text, source_message_ids=ids or [])


def briefing_payload():
    return {'briefing': {
        'version': 2, 'kind': 'market',
        'quick_read': {'focus': note('据甲自述已买入 Test（测试币）', ['e1']),
                       'news': note(), 'risk': note('乙质疑风险，待核实', ['e2'])},
        'projects': [{
            'name': 'Test / TEST / 测试币', 'chain': '未确认',
            'summary': '据甲自述已买入', 'catalysts': '未提供',
            'latest': '乙随后提出质疑', 'risks': '双方有分歧，未独立证实',
            'data': [{'value': '100', 'unit': 'USD', 'source': '甲自述',
                      'recorded_at': '未提供', 'kind': '历史快照',
                      'source_message_ids': ['e1']}],
            'addresses': [{'address': ADDRESS, 'chain': '未确认', 'source_message_ids': ['e1']}],
            'source_message_ids': ['e1', 'e2']}],
        'events': [{'event': '乙质疑风险', 'asset': 'Test', 'nature': '推测',
                    'impact': '待核实', 'pending': '未提供独立依据',
                    'source_message_ids': ['e2']}],
        'gaps': [note('原消息含图片，未读取', ['e2'])],
        'business': {'progress': [], 'notices': [], 'blockers': [], 'tasks': []},
    }}


def response(payload):
    return FakeResponse(200, {'content': [{'type': 'text', 'text': json.dumps(payload)}]})


class BriefingTests(unittest.TestCase):
    def test_optional_pending_flag_is_missing_text_not_a_verified_fact(self):
        payload = briefing_payload()
        payload['briefing']['events'][0]['pending'] = False
        payload['briefing']['events'][0]['impact'] = None
        client = MiniMaxClient('test-only-key', transport=lambda request, timeout: response(payload))
        actual = client.analyze_window([message('e1', 'CA '+ADDRESS, 1), message('e2', 'risk', 2)], 'two_hour', 0, 7200).result
        self.assertEqual(actual['briefing']['events'][0]['pending'], '未提供')
        self.assertEqual(actual['briefing']['events'][0]['impact'], '未提供')
        payload['briefing']['events'][0]['event'] = False
        with self.assertRaises(MiniMaxError):
            client.analyze_window([message('e1', 'CA '+ADDRESS, 1), message('e2', 'risk', 2)], 'two_hour', 0, 7200)

    def test_missing_project_optional_containers_do_not_invent_content(self):
        payload = briefing_payload()
        project = payload['briefing']['projects'][0]
        del project['data']
        del project['addresses']
        outcome = MiniMaxClient('test-only-key', transport=lambda request, timeout: response(payload)).analyze_window(
            [message('e1', '进展', 1), message('e2', '风险', 2)], 'two_hour', 0, 7200)
        actual = outcome.result['briefing']['projects'][0]
        self.assertEqual(actual['data'], [])
        self.assertEqual(actual['addresses'], [])
        self.assertEqual(actual['summary'], project['summary'])
        self.assertNotIn('data', project)
        project['data'] = None
        with self.assertRaises(MiniMaxError):
            MiniMaxClient('test-only-key', transport=lambda request, timeout: response(payload)).analyze_window(
                [message('e1', '进展', 1), message('e2', '风险', 2)], 'two_hour', 0, 7200)

    def test_excess_known_citations_are_bounded_without_hiding_unknown_ids(self):
        payload = briefing_payload()
        payload['briefing']['quick_read']['focus']['source_message_ids'] = ['e{}'.format(i) for i in range(1, 8)]
        messages = [message('e{}'.format(i), 'CA ' + ADDRESS, i) for i in range(1, 8)]
        client = MiniMaxClient('test-only-key', transport=lambda request, timeout: response(payload))
        outcome = client.analyze_window(messages, 'two_hour', 0, 7200)
        self.assertEqual(outcome.result['briefing']['quick_read']['focus']['source_message_ids'], ['e1','e2','e3','e4','e5'])
        self.assertEqual(payload['briefing']['quick_read']['focus']['source_message_ids'][-1], 'e7')
        payload['briefing']['quick_read']['focus']['source_message_ids'][-1] = 'fabricated'
        with self.assertRaises(MiniMaxError) as caught:
            client.analyze_window(messages, 'two_hour', 0, 7200)
        self.assertEqual(caught.exception.code, 'invalid_source_reference')

    def test_large_window_is_split_without_dropping_messages_then_synthesized(self):
        captured = []
        tasks = []
        def transport(request, timeout):
            self.assertLessEqual(len(request.data), 512 * 1024)
            document = json.loads(json.loads(request.data)['messages'][0]['content'])
            tasks.append(document['task'])
            if 'messages' in document:
                self.assertLessEqual(len(document['messages']), 300)
                captured.extend(item['eventId'] for item in document['messages'])
            source_ids = document['frozen_source_message_ids']
            payload = {'briefing': {'version': 2, 'kind': 'market',
                'quick_read': {'focus': note('已收到合成进展', source_ids[:1]), 'news': note(), 'risk': note()},
                'projects': [], 'events': [], 'gaps': [],
                'business': {'progress': [], 'notices': [], 'blockers': [], 'tasks': []}}}
            return response(payload)
        messages = [message('event-{}'.format(i), '合成进展 ' * 12, i) for i in range(1000)]
        outcome = MiniMaxClient('test-only-key', transport=transport).analyze_window(messages, 'two_hour', 0, 7200)
        self.assertEqual(captured, [item['eventId'] for item in messages])
        self.assertGreater(tasks.count('analyze_message_chunk'), 1)
        self.assertEqual(tasks[-1], 'synthesize_analyses')
        self.assertEqual(outcome.result['briefing']['version'], 2)

    def test_complete_briefing_with_only_missing_outer_wrapper_is_recovered(self):
        payload = briefing_payload()
        text = json.dumps(payload)[:-1]
        calls = []
        def transport(request, timeout):
            calls.append(request)
            return FakeResponse(200, {'stop_reason': 'end_turn', 'content': [{'type': 'text', 'text': text}]})
        outcome = MiniMaxClient('test-only-key', transport=transport).analyze_window(
            [message('e1', 'CA ' + ADDRESS, 1), message('e2', '风险', 2)], 'two_hour', 0, 7200)
        self.assertEqual(outcome.result['briefing'], payload['briefing'])
        self.assertEqual(len(calls), 1)

    def test_long_capture_ids_use_short_provider_references_and_restore_exactly(self):
        originals = ['a' * 16, 'b' * 16]
        payload = briefing_payload()
        def rename(value):
            if isinstance(value, list):
                return [rename(item) for item in value]
            if isinstance(value, dict):
                return {key: ([{'e1': 'M0001', 'e2': 'M0002'}[item] for item in child]
                              if key == 'source_message_ids' else rename(child)) for key, child in value.items()}
            return value
        payload = rename(payload)
        payload['briefing']['projects'][0]['name'] = 'M0001 is a literal name, not a citation'
        requests = []
        def transport(request, timeout):
            requests.append(json.loads(json.loads(request.data)['messages'][0]['content']))
            return response(payload)
        outcome = MiniMaxClient('test-only-key', transport=transport).analyze_window(
            [message(originals[0], 'CA ' + ADDRESS, 1), message(originals[1], '风险', 2)], 'two_hour', 0, 7200)
        self.assertEqual(len(requests), 1)
        self.assertEqual(requests[0]['frozen_source_message_ids'], ['M0001', 'M0002'])
        self.assertEqual([item['eventId'] for item in requests[0]['messages']], ['M0001', 'M0002'])
        self.assertEqual(outcome.result['briefing']['projects'][0]['source_message_ids'], originals)
        self.assertEqual(outcome.result['cryptoAddresses'][0]['sourceMessageIDs'], originals[:1])
        self.assertEqual(outcome.result['briefing']['projects'][0]['name'], payload['briefing']['projects'][0]['name'])
        self.assertEqual(outcome.result['cryptoAddresses'][0]['address'], ADDRESS)

    def test_wrapper_recovery_does_not_accept_truncated_or_untrusted_content(self):
        valid = json.dumps(briefing_payload())
        cases = [(valid[:-1], 'max_tokens'), (valid[:-2], 'end_turn'),
                 ('{"briefing":{"version":2,"kind":"mark', 'end_turn'),
                 ('{"other":{},"briefing":' + valid[12:-1], 'end_turn')]
        for text, stop in cases:
            with self.subTest(stop=stop, length=len(text)):
                calls = []
                def transport(request, timeout):
                    calls.append(request)
                    return FakeResponse(200, {'stop_reason': stop,
                        'content': [{'type': 'text', 'text': text}]})
                with self.assertRaises(MiniMaxError):
                    MiniMaxClient('test-only-key', transport=transport).analyze_window(
                        [message('e1', 'CA ' + ADDRESS, 1), message('e2', '风险', 2)],
                        'two_hour', 0, 7200)
                self.assertEqual(len(calls), 2)

    def test_blank_normalization_does_not_bypass_missing_evidence(self):
        for field in ('summary', 'name', 'source_message_ids'):
            payload = briefing_payload()
            payload['briefing']['projects'][0][field] = [] if field.endswith('_ids') else ''
            payload['briefing']['projects'][0]['catalysts'] = ''
            with self.subTest(field=field), self.assertRaises(MiniMaxError):
                MiniMaxClient('test-only-key', transport=lambda request, timeout: response(payload)).analyze_window(
                    [message('e1', 'CA ' + ADDRESS, 1), message('e2', '风险', 2)],
                    'two_hour', 0, 7200)

    def test_large_summary_can_finish_after_ninety_seconds_without_extra_request(self):
        requests = []
        def transport(request, timeout):
            requests.append(request)
            if timeout < 120:
                raise socket.timeout('synthetic slow generation')
            self.assertLessEqual(timeout, 180)
            return response(briefing_payload())
        outcome = MiniMaxClient('test-only-key', transport=transport).analyze_window(
            [message('e1', 'CA ' + ADDRESS, 1), message('e2', '风险', 2)], 'two_hour', 0, 7200)
        self.assertEqual(outcome.result['briefing']['version'], 2)
        self.assertEqual(len(requests), 1)

    def test_empty_optional_information_is_a_placeholder_not_a_failed_report(self):
        payload = briefing_payload()
        project = payload['briefing']['projects'][0]
        for key in ('chain', 'catalysts', 'latest', 'risks'):
            project[key] = '  '
        for key in ('unit', 'source', 'recorded_at'):
            project['data'][0][key] = ''
        for key in ('asset', 'impact', 'pending'):
            payload['briefing']['events'][0][key] = ''
        payload['briefing']['quick_read']['news']['text'] = ''
        before = copy.deepcopy(payload)
        requests = []
        def transport(request, timeout):
            requests.append(request)
            return response(payload)
        result = MiniMaxClient('test-only-key', transport=transport).analyze_window(
            [message('e1', 'CA ' + ADDRESS, 1), message('e2', '风险', 2)], 'two_hour', 0, 7200).result
        self.assertEqual(len(requests), 1)
        self.assertEqual(payload, before)
        actual = result['briefing']
        self.assertEqual(actual['projects'][0]['chain'], '未确认')
        self.assertEqual(actual['projects'][0]['catalysts'], '未提供')
        self.assertEqual(actual['projects'][0]['data'][0]['recorded_at'], '未提供')
        self.assertEqual(actual['events'][0]['pending'], '未提供')
        self.assertEqual(actual['quick_read']['news'], note())
        self.assertEqual(actual['projects'][0]['addresses'][0]['address'], ADDRESS)
        self.assertEqual(actual['projects'][0]['source_message_ids'], ['e1', 'e2'])
        self.assertEqual(actual['events'][0]['event'], '乙质疑风险')

    def test_blank_task_owner_and_deadline_do_not_invent_an_assignment(self):
        payload = briefing_payload()
        payload['briefing'].update(kind='business', projects=[], events=[])
        payload['briefing']['business']['tasks'] = [dict(
            text='请补充文档', owner='', deadline='\n ', source_message_ids=['e1'])]
        result = self.run_report(payload)
        self.assertEqual(result['briefing']['business']['tasks'], [dict(
            text='请补充文档', owner='未提供', deadline='未提供', source_message_ids=['e1'])])

    def test_malformed_quick_read_gets_precise_safe_feedback_and_one_repair(self):
        for malformed in ('PRIVATE MODEL OUTPUT', None, [], {}, {'PRIVATE FIELD': 'PRIVATE MODEL OUTPUT'}):
            with self.subTest(shape=type(malformed).__name__):
                requests = []
                bad = briefing_payload()
                bad['briefing']['quick_read']['focus'] = malformed
                def transport(request, timeout):
                    document = json.loads(json.loads(request.data)['messages'][0]['content'])
                    requests.append(document)
                    return response(bad if len(requests) == 1 else briefing_payload())
                outcome = MiniMaxClient('test-only-key', transport=transport).analyze_window(
                    [message('e1', 'CA ' + ADDRESS, 1), message('e2', '风险 [图片]', 2)], 'two_hour', 0, 7200)
                self.assertEqual(outcome.result['briefing'], briefing_payload()['briefing'])
                self.assertEqual(len(requests), 2)
                self.assertEqual(requests[1].get('validation_detail'), {
                    'path': 'briefing.quick_read.focus', 'rule': 'object_fields',
                    'required_fields': ['text', 'source_message_ids'],
                })
                self.assertEqual(requests[1]['messages'], requests[0]['messages'])
                self.assertNotIn('PRIVATE', json.dumps(requests[1]))

    def test_nested_feedback_pinpoints_invalid_reference_without_echoing_it(self):
        bad = briefing_payload()
        bad['briefing']['projects'][0]['data'][0]['source_message_ids'] = ['PRIVATE-INVENTED-ID']
        requests = []
        def transport(request, timeout):
            requests.append(json.loads(json.loads(request.data)['messages'][0]['content']))
            return response(bad)
        with self.assertRaises(MiniMaxError) as caught:
            MiniMaxClient('test-only-key', transport=transport).analyze_window(
                [message('e1', 'CA ' + ADDRESS, 1), message('e2', '风险', 2)], 'two_hour', 0, 7200)
        self.assertEqual(caught.exception.code, 'invalid_source_reference')
        self.assertEqual(len(requests), 2)
        self.assertEqual(requests[1].get('validation_detail'), {
            'path': 'briefing.projects[0].data[0].source_message_ids', 'rule': 'known_source_ids',
        })
        self.assertNotIn('PRIVATE', json.dumps(requests[1]))

    def run_report(self, payload=None, messages=None, **options):
        payload = payload or briefing_payload()
        inputs = messages or [message('e1', '甲：我买了 CA ' + ADDRESS, 1),
                              message('e2', '乙：有风险 [图片]', 2)]
        client = MiniMaxClient('test-only-key', transport=lambda request, timeout: response(payload))
        return client.analyze_window(inputs, **(options or dict(cadence='two_hour', window_start=0, window_end=7200))).result

    def test_new_template_survives_validation_and_readonly_projection(self):
        try:
            result = self.run_report()
        except MiniMaxError as error:
            self.fail('new template rejected: ' + error.code)
        self.assertEqual(result['briefing'], briefing_payload()['briefing'])
        self.assertEqual(result['cryptoAddresses'][0]['address'], ADDRESS)
        self.assertEqual(_project_result(result, ['e1', 'e2'])['briefing'], result['briefing'])

    def test_rejects_ca_case_change_instead_of_silently_rewriting_it(self):
        payload = briefing_payload()
        payload['briefing']['projects'][0]['addresses'][0]['address'] = ADDRESS.lower()
        with self.assertRaises(MiniMaxError) as caught:
            self.run_report(payload)
        self.assertEqual(caught.exception.code, 'invalid_address_reference')

    def test_rejects_unrelated_ca_citation_and_uncited_conclusions(self):
        for field in ['address', 'project', 'quick']:
            with self.subTest(field=field):
                payload = briefing_payload()
                project = payload['briefing']['projects'][0]
                if field == 'address':
                    project['addresses'][0]['source_message_ids'] = ['e2']
                elif field == 'project':
                    project['source_message_ids'] = []
                else:
                    payload['briefing']['quick_read']['focus']['source_message_ids'] = []
                with self.assertRaises(MiniMaxError):
                    self.run_report(payload)

    def test_rejects_claim_of_external_verification(self):
        payload = briefing_payload()
        payload['briefing']['events'][0]['nature'] = '已核验事实'
        with self.assertRaises(MiniMaxError):
            self.run_report(payload)

    def test_different_ca_or_chain_cannot_share_one_project_record(self):
        for variation in ('different_ca', 'different_chain'):
            payload = briefing_payload()
            project = payload['briefing']['projects'][0]
            other = copy.deepcopy(project['addresses'][0])
            other['address'] = '0x' + 'cD' * 20
            if variation == 'different_ca':
                project['addresses'].append(other)
            else:
                project['addresses'][0]['chain'] = 'Base'
            with self.subTest(variation=variation), self.assertRaises(MiniMaxError):
                self.run_report(payload, [message('e1', 'CA ' + ADDRESS + ' CA ' + other['address'], 1), message('e2', '质疑', 2)])

    def test_business_report_preserves_unspecified_owner_and_deadline(self):
        payload = briefing_payload()
        payload['briefing'].update(kind='business', projects=[], events=[])
        payload['briefing']['business']['tasks'] = [dict(text='请补充文档', owner='未提供',
            deadline='未提供', source_message_ids=['e1'])]
        try:
            result = self.run_report(payload)
        except MiniMaxError as error:
            self.fail('business template rejected: ' + error.code)
        self.assertEqual(result['briefing']['business']['tasks'][0]['owner'], '未提供')

    def test_default_request_only_reads_last_twelve_hours(self):
        captured = []
        def transport(request, timeout):
            doc = json.loads(json.loads(request.data)['messages'][0]['content'])
            captured.append(doc)
            return response({'summary': '无有效信息', 'summary_source_message_ids': ['e1'],
                'topics': [], 'findings': [], 'crypto_addresses': []})
        with mock.patch('scripts.wxfomo_lan.minimax.time.time', return_value=50000):
            try:
                MiniMaxClient('test-only-key', transport=transport).analyze_window(
                    [message('old', '超出范围', 100), message('e1', '你好', 49999)])
            except TypeError as error:
                self.fail(str(error))
        self.assertEqual(captured[0]['window_start'], 6800)
        self.assertEqual(captured[0]['window_end'], 50000)
        self.assertEqual(captured[0]['frozen_source_message_ids'], ['e1'])

    def test_synthesis_preserves_all_nested_citations_and_original_ca(self):
        requests = []
        payload = briefing_payload()
        def transport(request, timeout):
            doc = json.loads(json.loads(request.data)['messages'][0]['content'])
            requests.append(doc)
            if doc['task'] == 'synthesize_analyses':
                self.assertEqual(set(doc['frozen_source_message_ids']), {'e1', 'e2'})
                return response(payload)
            part = copy.deepcopy(payload)
            if doc['frozen_source_message_ids'] == ['e1']:
                part['briefing']['quick_read']['risk'] = note()
                part['briefing']['projects'][0]['source_message_ids'] = ['e1']
                part['briefing']['events'] = []
                part['briefing']['gaps'] = []
            else:
                part['briefing']['quick_read']['focus'] = note()
                part['briefing']['projects'] = []
            return response(part)
        try:
            result = MiniMaxClient('test-only-key', transport=transport, _chunk_content_bytes=80).analyze_window(
                [message('e1', 'CA ' + ADDRESS, 1), message('e2', '风险' * 12, 2)], 'two_hour', 0, 7200)
        except MiniMaxError as error:
            self.fail('synthesis rejected: ' + error.code)
        self.assertGreater(len(requests), 2)
        self.assertEqual(result.result['briefing']['projects'][0]['addresses'][0]['address'], ADDRESS)


if __name__ == '__main__':
    unittest.main()

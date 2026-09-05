import copy
import json
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

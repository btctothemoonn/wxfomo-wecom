import copy
import json
import unittest

from scripts.test_wxfomo_briefing import ADDRESS, briefing_payload, response
from scripts.test_wxfomo_minimax import message
from scripts.test_wxfomo_briefing_limits import provider_briefing
from scripts.wxfomo_lan.minimax import MiniMaxClient, MiniMaxError, _address_evidence


class ProviderEvidenceTests(unittest.TestCase):
    def test_valid_project_overflow_is_compacted_in_actual_provider_pipeline(self):
        payload = {'briefing': provider_briefing(9)}
        calls = []
        def transport(request, timeout):
            calls.append(request)
            return response(payload)
        client = MiniMaxClient('synthetic-key', transport=transport)
        outcome = client.analyze_window([message('e1', 'CA '+ADDRESS, 1)], 'daily', 0, 86400)
        self.assertEqual(len(calls), 1)
        self.assertEqual(len(outcome.result['briefing']['projects']), 8)
        self.assertEqual(len(payload['briefing']['projects']), 9)
        payload['briefing']['projects'][8]['source_message_ids'] = ['invented']
        with self.assertRaises(MiniMaxError) as caught:
            client.analyze_window([message('e1', 'CA '+ADDRESS, 1)], 'daily', 0, 86400)
        self.assertEqual(caught.exception.code, 'invalid_source_reference')

    def test_request_separates_verbatim_ca_sources_from_neighboring_discussion(self):
        requests = []
        def transport(request, timeout):
            requests.append(json.loads(json.loads(request.data)['messages'][0]['content']))
            return response(briefing_payload())
        MiniMaxClient('synthetic-key', transport=transport).analyze_window(
            [message('e1', 'CA '+ADDRESS, 1), message('e2', 'a nearby opinion', 2)],
            'daily', 0, 86400)
        self.assertEqual(requests[0]['crypto_address_evidence'], [{
            'address': ADDRESS, 'context_source_message_ids': ['e1', 'e2'],
            'direct_source_message_ids': ['e1'],
        }])

    def test_chunk_evidence_preserves_case_and_excludes_other_chunk_direct_ids(self):
        evidence = _address_evidence([
            message('e1', 'CA '+ADDRESS, 1), message('e2', 'CA '+ADDRESS.lower(), 2)])
        local = MiniMaxClient._evidence_for_ids(evidence, ['e2'])
        exported = MiniMaxClient._evidence_document(local)
        self.assertEqual(exported[0]['address'], ADDRESS.lower())
        self.assertEqual(exported[0].get('direct_source_message_ids'), ['e2'])
        self.assertEqual(exported[0]['context_source_message_ids'], ['e2'])

    def test_reference_display_cap_keeps_an_existing_direct_ca_citation(self):
        payload = briefing_payload()
        project = payload['briefing']['projects'][0]
        project['addresses'][0]['source_message_ids'] = ['e1','e2','e3','e4','e5','e6']
        original = copy.deepcopy(payload)
        messages = [message('e'+str(i), 'discussion' if i != 6 else 'CA '+ADDRESS, i)
                    for i in range(1, 7)]
        calls = []
        def transport(request, timeout):
            calls.append(request)
            return response(payload)
        failure = None
        try:
            outcome = MiniMaxClient('synthetic-key', transport=transport).analyze_window(
                messages, 'daily', 0, 86400)
        except MiniMaxError as error:
            failure = error.code
        self.assertIsNone(failure, 'valid sixth direct citation was lost by display compaction')
        self.assertEqual(len(calls), 1, 'a valid cited CA must not need model regeneration')
        self.assertEqual(outcome.result['briefing']['projects'][0]['addresses'][0]['source_message_ids'],
                         ['e1','e2','e3','e4','e6'])
        self.assertEqual(payload, original)

    def test_missing_or_unknown_direct_citation_is_never_invented_by_compaction(self):
        for cited in (['e1','e2','e3','e4','e5'], ['e1','e2','e3','e4','e5','e6','invented']):
            payload = briefing_payload()
            payload['briefing']['projects'][0]['addresses'][0]['source_message_ids'] = cited
            messages = [message('e'+str(i), 'discussion' if i != 6 else 'CA '+ADDRESS, i)
                        for i in range(1, 7)]
            with self.subTest(citations=len(cited)), self.assertRaises(MiniMaxError):
                MiniMaxClient('synthetic-key', transport=lambda request, timeout: response(payload)).analyze_window(
                    messages, 'daily', 0, 86400)


if __name__ == '__main__':
    unittest.main()

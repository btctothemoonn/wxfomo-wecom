"""Synthetic-only contract checks; never open runtime stores or credentials."""
import copy
import json
import pathlib
import unittest

from scripts.wxfomo_lan.signal_contract import SyncError, encode_payload, validate_payload


FIXTURES = pathlib.Path(__file__).parent / 'fixtures/signalhub-v2-handoff-8f6df4f'


def fixture(name='report.example.json'):
    return json.loads((FIXTURES / name).read_text(encoding='utf-8'))


class ContractTests(unittest.TestCase):
    def test_all_six_shapes_preserve_exact_canonical_signed_bytes(self):
        for name in ('report.example.json', 'report-business.example.json',
                     'ca-alert.example.json', 'ca-alert-expired.example.json',
                     'ca-alert-catchup.example.json', 'heartbeat.example.json'):
            with self.subTest(name=name):
                value = fixture(name)
                body = encode_payload(value)
                self.assertEqual(json.loads(body), value)
                self.assertIsNone(validate_payload(value))
        for vector in fixture('signature.example.json')['vectors']:
            self.assertEqual(encode_payload(fixture(vector['fixture'])), vector['body'].encode('utf-8'))

    def test_rejects_bad_shape_privacy_citations_and_counts_without_echo(self):
        cases = [
            ('report.example.json', ('schemaVersion',), True),
            ('report.example.json', ('schemaVersion',), 1),
            ('report.example.json', ('report','revision'), 0),
            ('report.example.json', ('report','sources'), [{'content':'PRIVATE-CHAT'}]),
            ('report.example.json', ('report','briefing','quick_read','focus'), 'PRIVATE-CHAT'),
            ('report.example.json', ('report','sourceReferences',0,'content'), 'PRIVATE-CHAT'),
            ('report.example.json', ('report','sourceReferences',2,'sender'), 'PRIVATE-NAME'),
            ('report.example.json', ('report','briefing','gaps',0,'source_message_ids'), ['M9999']),
            ('report.example.json', ('report','sourceReferences',0,'id'), 'M9999'),
            ('report.example.json', ('report','sourceReferences',0,'group'), 'PRIVATE-UNLISTED-GROUP'),
            ('report.example.json', ('report','scope','missingCount'), 0),
            ('report.example.json', ('report','sourceComplete'), True),
            ('report.example.json', ('report','caCoverage','exportedItems'), 0),
            ('report.example.json', ('report','caDiscussions',0,'duplicateCount'), True),
            ('report.example.json', ('report','caDiscussions',0,'duplicateCount'), 9),
            ('report.example.json', ('report','briefing','quick_read','focus','text'), '\ud800'),
            ('report.example.json', ('report','briefing','quick_read','focus','text'), 'x\0y'),
            ('report.example.json', ('report','briefing','quick_read','focus','text'), 'x'*601),
            ('report.example.json', ('report','briefing','quick_read','focus','text'), 'sk-cp-'+'A'*48),
            ('report.example.json', ('report','sourceReferences',0,'sender'), '𐀀'*101),
            ('report.example.json', ('report','generatedAt'), '2026-09-06T00:00:00+08:00'),
            ('ca-alert.example.json', ('alert','network'), 'unknown'),
            ('ca-alert.example.json', ('alert','groups'), ['same','same']),
            ('ca-alert.example.json', ('alert','mentionCount'), 0),
            ('ca-alert.example.json', ('alert','catchup'), True),
            ('ca-alert.example.json', ('alert','notificationVersion'), 2),
            ('ca-alert.example.json', ('alert','firstReceivedAt'), '2026-09-06T00:00:00Z'),
            ('ca-alert.example.json', ('alert','evaluatedAt'), '2026-09-06T02:00:00Z'),
            ('heartbeat.example.json', ('status','pendingAlerts'), True),
            ('heartbeat.example.json', ('status','pendingReports'), 2**53),
            ('heartbeat.example.json', ('status','lastError'), 'PRIVATE: stack trace'),
        ]
        for name,path,replacement in cases:
            with self.subTest(path=path):
                value=fixture(name); target=value
                for key in path[:-1]: target=target[key]
                target[path[-1]]=replacement
                with self.assertRaises(SyncError) as caught: encode_payload(value)
                self.assertRegex(str(caught.exception), r'^[a-z_]+$')
                self.assertNotIn('PRIVATE', repr(caught.exception))

    def test_false_inputs_and_cycles_fail_closed(self):
        cycle={}; cycle['loop']=cycle
        for value in (None, [], 'PRIVATE', {'type':[]}, cycle):
            with self.subTest(kind=type(value).__name__), self.assertRaises(SyncError):
                encode_payload(value)

    def test_original_case_unicode_and_early_expiry_preserved(self):
        value=fixture()
        address=value['report']['briefing']['projects'][0]['addresses'][0]['address']
        value['report']['briefing']['quick_read']['focus']['text']='𐀀'*600
        self.assertEqual(json.loads(encode_payload(value))['report']['briefing']['projects'][0]['addresses'][0]['address'],address)
        expired=fixture('ca-alert-expired.example.json')
        expired['alert']['evaluatedAt']='2026-09-06T00:40:00Z'
        self.assertEqual(json.loads(encode_payload(expired))['alert']['status'],'expired')

    def test_extraneous_identity_and_unknown_chain_multi_group_are_rejected(self):
        value=fixture(); extra=copy.deepcopy(value['report']['sourceReferences'][0]); extra['id']='M0004'
        value['report']['sourceCount']=4
        value['report']['scope'].update(frozenCount=4,analyzedCount=4,readableCount=3)
        value['report']['sourceReferences'].append(extra)
        with self.assertRaises(SyncError): encode_payload(value)
        value=fixture(); value['report']['caDiscussions'][0]['network']='unknown'
        with self.assertRaises(SyncError): encode_payload(value)

    def test_body_budget_rejects_whole_report_without_trimming(self):
        value=fixture(); report=value['report']
        report['sourceCount']=1000
        report['scope'].update(frozenCount=1000,analyzedCount=1000,readableCount=999)
        report['scope']['groupNames'] += ['群'+str(i)+'示'*190 for i in range(48)]
        ca=report['caDiscussions'][0]
        ca.update(groups=report['scope']['groupNames'][:],mentionCount=50,uniqueStatementCount=50,duplicateCount=0,summary='文'*2000)
        report['caDiscussions']=[copy.deepcopy(ca) for _ in range(50)]
        report['caCoverage'].update(totalItems=50,exportedItems=50)
        original=copy.deepcopy(value)
        with self.assertRaises(SyncError) as caught: encode_payload(value)
        self.assertEqual(caught.exception.code,'payload_too_large')
        self.assertEqual(value,original)


if __name__ == '__main__': unittest.main()

"""Synthetic-only report export checks; never invoke a provider or production."""
import copy
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from scripts.test_wxfomo_briefing import briefing_payload, ADDRESS
from scripts.wxfomo_lan.signal_contract import SyncError, encode_payload
from scripts.wxfomo_lan.signal_export import build_report, completed_after, prepare_reports


STORE = '00000000-0000-4000-8000-000000000001'


def row(index=1):
    return dict(analysis_id=index, job_id='fixture-job-' + str(index), cadence='two_hour',
                window_start=1000, window_end=8200, created_at=8300,
                source_event_ids_json=json.dumps(['e1', 'e2']), model='fixture-model',
                result_json=json.dumps(briefing_payload()))


def sources():
    return [dict(eventId='e1', group='合成甲群', sender='甲', observedAt='1970-01-01T00:20:00Z',
                 content='Base CA: ' + ADDRESS),
            dict(eventId='e2', group='合成乙群', sender='乙', observedAt='1970-01-01T00:21:00Z',
                 content='Base CA: ' + ADDRESS)]


class ExportTests(unittest.TestCase):
    def test_complete_briefing_and_verbatim_ca_without_raw_sources(self):
        original = row()
        before = copy.deepcopy(original)
        report = build_report(original, sources(), 'fixture-device', STORE)['report']
        self.assertEqual(original, before)
        self.assertEqual(report['sources'], [])
        self.assertEqual(report['briefing']['projects'][0]['source_message_ids'], ['M0001', 'M0002'])
        self.assertEqual(report['briefing']['projects'][0]['addresses'][0]['address'], ADDRESS)
        self.assertEqual(report['caDiscussions'][0]['address'], ADDRESS)
        self.assertEqual(report['caDiscussions'][0]['groups'], ['合成乙群', '合成甲群'])
        self.assertEqual(report['scope']['readableCount'], 2)
        self.assertEqual(report['generatedAt'], '1970-01-01T02:18:20Z')
        self.assertNotIn('content', json.dumps(report))
        encode_payload(dict(schemaVersion=2, type='report', report=report))

    def test_missing_source_keeps_citation_and_reports_gap(self):
        report = build_report(row(), sources()[:1], 'fixture-device', STORE)['report']
        self.assertFalse(report['sourceComplete'])
        self.assertEqual(report['scope']['missingCount'], 1)
        self.assertEqual(report['sourceReferences'][1],
                         dict(id='M0002', group=None, sender=None, observedAt=None, available=False))
        self.assertFalse(report['caCoverage']['sourcesComplete'])

    def test_readable_address_mismatch_is_not_exported(self):
        items = sources()
        items[0]['content'] = '没有该地址'
        with self.assertRaises(SyncError):
            build_report(row(), items, 'fixture-device', STORE)

    def test_missing_address_source_does_not_destroy_previously_valid_report(self):
        report = build_report(row(), sources()[1:], 'fixture-device', STORE)['report']
        self.assertEqual(report['briefing']['projects'][0]['addresses'][0]['address'], ADDRESS)
        self.assertFalse(report['sourceComplete'])

    def test_citation_remap_does_not_rewrite_literal_text_or_unicode(self):
        value = row()
        document = json.loads(value['result_json'])
        document['briefing']['projects'][0]['name'] = 'e1 ' + '😀' * 597
        value['result_json'] = json.dumps(document)
        result = build_report(value, sources(), 'fixture-device', STORE)
        self.assertEqual(result['report']['briefing']['projects'][0]['name'], document['briefing']['projects'][0]['name'])

    def test_unknown_chains_stay_group_scoped_and_ca_total_is_not_capped(self):
        items = sources()
        items[0]['content'] = 'CA: ' + ADDRESS + ' ' + ' '.join('0x{:040x}'.format(n) for n in range(60))
        items[1]['content'] = 'CA: ' + ADDRESS
        report = build_report(row(), items, 'fixture-device', STORE)['report']
        self.assertGreater(report['caCoverage']['totalItems'], 50)
        self.assertEqual(report['caCoverage']['exportedItems'], 50)
        self.assertTrue(report['caCoverage']['truncated'])
        self.assertTrue(all(len(item['groups']) == 1 for item in report['caDiscussions']))

    def test_old_completed_rows_are_paged_without_ui_retention_filter(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / 'analysis.sqlite3')
            db = sqlite3.connect(path)
            db.executescript('CREATE TABLE analysis_results(analysis_id INTEGER,job_id TEXT,result_json TEXT,model TEXT,created_at REAL);'
                             'CREATE TABLE analysis_jobs(job_id TEXT,state TEXT,cadence TEXT,window_start REAL,window_end REAL,source_event_ids_json TEXT);')
            for index in range(1, 42):
                item = row(index)
                db.execute('INSERT INTO analysis_results VALUES(?,?,?,?,?)',
                           (index, item['job_id'], item['result_json'], item['model'], item['created_at']))
                db.execute('INSERT INTO analysis_jobs VALUES(?,?,?,?,?,?)',
                           (item['job_id'], 'succeeded' if index <= 40 else 'failed', 'two_hour', 1000, 8200, '["e1","e2"]'))
            db.commit()
            db.close()
            found = []
            cursor = 0
            for unused in range(5):
                page = completed_after(path, cursor)
                found.extend(item['analysis_id'] for item in page)
                if page:
                    cursor = page[-1]['analysis_id']
            self.assertEqual(found, list(range(1, 41)))

    def test_source_unavailable_is_not_a_missing_or_successful_export(self):
        with mock.patch('scripts.wxfomo_lan.signal_export.completed_after', return_value=[row()]):
            with self.assertRaises(SyncError):
                prepare_reports('/synthetic/analysis', '/synthetic/missing', 0, 'fixture-device', STORE)

    def test_prepare_resolves_alias_and_marks_quarantined_alias_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = str(Path(directory) / 'messages.sqlite3')
            db = sqlite3.connect(path)
            db.executescript('CREATE TABLE messages(id INTEGER PRIMARY KEY,event_id TEXT,group_name TEXT,sender_display_name TEXT,content TEXT,message_type TEXT,observed_at REAL,source_sequence INTEGER);'
                             'CREATE TABLE message_event_aliases(alias_event_id TEXT,message_id INTEGER);'
                             'CREATE TABLE message_event_alias_quarantine(alias_event_id TEXT);')
            db.execute('INSERT INTO messages VALUES(1,?,?,?,?,?,?,?)',
                       ('canonical-event', '合成甲群', '甲', 'Base CA: ' + ADDRESS, 'text', 1200, 1))
            db.execute('INSERT INTO message_event_aliases VALUES(?,1)', ('e1',))
            db.execute('INSERT INTO message_event_aliases VALUES(?,1)', ('e2',))
            db.execute('INSERT INTO message_event_alias_quarantine VALUES(?)', ('e2',))
            db.commit()
            with mock.patch('scripts.wxfomo_lan.signal_export.completed_after', return_value=[row()]):
                exported = prepare_reports('synthetic', path, 0, 'fixture-device', STORE)
            self.assertIsNone(exported[0]['error_code'])
            report = json.loads(exported[0]['payload'])['report']
            self.assertTrue(report['sourceReferences'][0]['available'])
            self.assertFalse(report['sourceReferences'][1]['available'])
            self.assertEqual(report['scope']['missingCount'], 1)
            db.execute('BEGIN EXCLUSIVE')
            with mock.patch('scripts.wxfomo_lan.signal_export.completed_after', return_value=[row()]):
                with self.assertRaisesRegex(SyncError, 'source_unavailable'):
                    prepare_reports('synthetic', path, 0, 'fixture-device', STORE)
            db.rollback()
            db.close()

    def test_aliases_of_one_event_count_once_without_losing_frozen_references(self):
        from scripts.wxfomo_lan.messages import MessageRepository
        for canonical_id in ('canonical-event', 'e1'):
            with self.subTest(canonical_id=canonical_id), tempfile.TemporaryDirectory() as directory:
                messages_path = str(Path(directory) / 'messages.sqlite3')
                db = sqlite3.connect(messages_path)
                db.executescript('CREATE TABLE messages(id INTEGER PRIMARY KEY,event_id TEXT,group_name TEXT,sender_display_name TEXT,content TEXT,message_type TEXT,observed_at REAL,source_sequence INTEGER);'
                                 'CREATE TABLE message_event_aliases(alias_event_id TEXT,message_id INTEGER);')
                db.execute('INSERT INTO messages VALUES(1,?,?,?,?,?,?,?)',
                           (canonical_id, '合成甲群', '', 'Base CA: ' + ADDRESS, 'text', 1200, 1))
                db.executemany('INSERT INTO message_event_aliases VALUES(?,1)', [('e1',), ('e2',)])
                db.commit()
                db.close()

                value = row()
                document = json.loads(value['result_json'])
                document['briefing']['projects'][0]['addresses'][0]['source_message_ids'] = ['e2']
                value['result_json'] = json.dumps(document)
                analysis_path = str(Path(directory) / 'analysis.sqlite3')
                db = sqlite3.connect(analysis_path)
                db.executescript('CREATE TABLE analysis_results(analysis_id INTEGER,job_id TEXT,result_json TEXT,model TEXT,created_at REAL);'
                                 'CREATE TABLE analysis_jobs(job_id TEXT,state TEXT,cadence TEXT,window_start REAL,window_end REAL,source_event_ids_json TEXT);')
                db.execute('INSERT INTO analysis_results VALUES(?,?,?,?,?)',
                           (1, value['job_id'], value['result_json'], value['model'], value['created_at']))
                db.execute('INSERT INTO analysis_jobs VALUES(?,?,?,?,?,?)',
                           (value['job_id'], 'succeeded', value['cadence'], value['window_start'],
                            value['window_end'], value['source_event_ids_json']))
                db.commit()
                db.close()

                prepared = prepare_reports(analysis_path, messages_path, 0, 'fixture-device', STORE)
                self.assertIsNone(prepared[0]['error_code'])
                report = json.loads(prepared[0]['payload'])['report']
                card = report['caDiscussions'][0]
                self.assertEqual((card['mentionCount'], card['uniqueStatementCount'], card['duplicateCount']),
                                 (1, 1, 0))
                self.assertEqual(card['sourceMessageIDs'], ['M0001'])
                self.assertEqual(card['summary'], document['briefing']['projects'][0]['summary'])
                self.assertEqual(report['sourceCount'], 2)
                self.assertTrue(report['sourceComplete'])
                self.assertEqual((report['scope']['frozenCount'], report['scope']['readableCount'],
                                  report['scope']['missingCount']), (2, 2, 0))
                self.assertEqual([item['id'] for item in report['sourceReferences']], ['M0001', 'M0002'])
                self.assertTrue(all(item['available'] for item in report['sourceReferences']))
                self.assertEqual(report['briefing']['projects'][0]['addresses'][0]['source_message_ids'], ['M0002'])
                self.assertNotIn('canonicalEventId', prepared[0]['payload'].decode('utf-8'))
                ordinary = MessageRepository(messages_path, None).by_event_ids(['e1', 'e2'])
                self.assertEqual([item['eventId'] for item in ordinary], ['e1', 'e2'])
                self.assertTrue(all('canonicalEventId' not in item for item in ordinary))

    def test_core_payload_overflow_is_not_silently_trimmed(self):
        value = row()
        document = briefing_payload()
        project = document['briefing']['projects'][0]
        for key in ('name', 'summary', 'catalysts', 'latest', 'risks'):
            project[key] = '😀' * 600
        for key in ('value', 'unit', 'source', 'recorded_at'):
            project['data'][0][key] = '😀' * 600
        project['data'] *= 4
        document['briefing']['projects'] = [copy.deepcopy(project) for unused in range(8)]
        value['result_json'] = json.dumps(document)
        with self.assertRaisesRegex(SyncError, 'payload_too_large'):
            build_report(value, sources(), 'fixture-device', STORE)

    def test_invalid_row_has_explicit_error_and_cursor(self):
        bad = row()
        bad['result_json'] = '{}'
        with mock.patch('scripts.wxfomo_lan.signal_export.completed_after', return_value=[bad]), \
             mock.patch('scripts.wxfomo_lan.signal_export.MessageRepository') as repository:
            repository.return_value.by_event_ids.return_value = sources()
            items = prepare_reports('synthetic', 'synthetic', 0, 'fixture-device', STORE)
        self.assertEqual(items[0]['cursor'], 1)
        self.assertIsNone(items[0]['payload'])
        self.assertTrue(items[0]['error_code'])

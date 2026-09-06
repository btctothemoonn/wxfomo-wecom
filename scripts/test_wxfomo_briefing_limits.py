import copy
import unittest

from scripts.wxfomo_lan import briefing


ADDRESS = '0x' + 'aB' * 20
KNOWN_IDS = frozenset(('e1',))
EVIDENCE = {ADDRESS.lower(): {'verbatim_sources': {ADDRESS: ['e1']}}}


def provider_briefing(project_count):
    return {
        'version': 2, 'kind': 'market',
        'quick_read': {
            'focus': {'text': '合成项目进展', 'source_message_ids': ['e1']},
            'news': {'text': '未提供', 'source_message_ids': []},
            'risk': {'text': '未提供', 'source_message_ids': []},
        },
        'projects': [{
            'name': '项目{}'.format(index + 1), 'chain': '未确认',
            'summary': '据原文报告进展', 'catalysts': '未提供',
            'latest': '未提供', 'risks': '未提供', 'data': [],
            'addresses': [{'address': ADDRESS, 'chain': '未确认',
                           'source_message_ids': ['e1']}],
            'source_message_ids': ['e1'],
        } for index in range(project_count)],
        'events': [], 'gaps': [],
        'business': {'progress': [], 'notices': [], 'blockers': [], 'tasks': []},
    }


class ProviderProjectLimitsTests(unittest.TestCase):
    def test_nine_valid_projects_keep_first_eight_without_rewriting_content(self):
        # Truncating before validation, reordering, or rewriting retained facts breaks this contract.
        value = provider_briefing(9)
        original = copy.deepcopy(value)
        try:
            actual = briefing.compact_provider_projects(value, KNOWN_IDS, EVIDENCE)
        except briefing.BriefingError as error:
            self.fail('valid provider projects were not compacted: {}'.format(error.detail))
        self.assertEqual([row['name'] for row in actual['projects']],
                         ['项目1', '项目2', '项目3', '项目4', '项目5', '项目6', '项目7', '项目8'])
        expected = copy.deepcopy(original)
        expected['projects'] = expected['projects'][:8]
        self.assertEqual(actual, expected)
        self.assertEqual(value, original)
        actual['projects'][0]['addresses'][0]['source_message_ids'].append('changed')
        self.assertEqual(value, original)

    def test_invalid_ninth_project_is_checked_before_it_can_be_removed(self):
        # Dropping the ninth item first would hide invented evidence or unknown fields.
        cases = (
            ('address', 'invalid_address_reference', 'briefing.projects[8].addresses[0]'),
            ('citation', 'invalid_source_reference', 'briefing.projects[8].source_message_ids'),
            ('unknown_field', 'invalid_response', 'briefing.projects[8]'),
        )
        for mutation, code, path in cases:
            value = provider_briefing(9)
            if mutation == 'address':
                value['projects'][8]['addresses'][0]['address'] = '0x' + 'cD' * 20
            elif mutation == 'citation':
                value['projects'][8]['source_message_ids'] = ['fabricated']
            else:
                value['projects'][8]['unexpected'] = 'untrusted'
            original = copy.deepcopy(value)
            with self.subTest(mutation=mutation), self.assertRaises(briefing.BriefingError) as caught:
                briefing.compact_provider_projects(value, KNOWN_IDS, EVIDENCE)
            self.assertEqual(caught.exception.code, code)
            self.assertEqual(caught.exception.detail['path'], path)
            self.assertEqual(value, original)

    def test_later_groups_are_validated_up_to_the_allowed_provider_bound(self):
        # Checking only the first overflow group would silently discard bad later projects.
        value = provider_briefing(32)
        actual = briefing.compact_provider_projects(value, KNOWN_IDS, EVIDENCE)
        self.assertEqual(len(actual['projects']), 8)
        value['projects'][31]['source_message_ids'] = ['fabricated']
        with self.assertRaises(briefing.BriefingError) as caught:
            briefing.compact_provider_projects(value, KNOWN_IDS, EVIDENCE)
        self.assertEqual(caught.exception.code, 'invalid_source_reference')
        self.assertEqual(caught.exception.detail['path'], 'briefing.projects[31].source_message_ids')

    def test_excessive_or_non_list_projects_are_rejected(self):
        # Treating arbitrary values as iterable projects or accepting unbounded output is invalid.
        for projects in (provider_briefing(33)['projects'], None, {}, (), 'projects'):
            value = provider_briefing(0)
            value['projects'] = projects
            with self.subTest(kind=type(projects).__name__), self.assertRaises(briefing.BriefingError):
                briefing.compact_provider_projects(value, KNOWN_IDS, EVIDENCE)

    def test_business_and_market_sections_remain_mutually_exclusive(self):
        # Validating sliced projects without the surrounding document would miss kind conflicts.
        for kind in ('business', 'market'):
            value = provider_briefing(9)
            value['kind'] = kind
            if kind == 'market':
                value['business']['progress'] = [{'text': '合成进展', 'source_message_ids': ['e1']}]
            with self.subTest(kind=kind), self.assertRaises(briefing.BriefingError):
                briefing.compact_provider_projects(value, KNOWN_IDS, EVIDENCE)

    def test_other_list_limits_and_top_level_fields_are_not_compacted(self):
        # Project compaction must not forgive unrelated malformed or overlong sections.
        for mutation in ('events', 'gaps', 'unknown_field'):
            value = provider_briefing(9)
            if mutation == 'events':
                value['events'] = [{
                    'event': '合成事件', 'asset': '未提供', 'nature': '自述',
                    'impact': '未提供', 'pending': '未提供', 'source_message_ids': ['e1'],
                } for _ in range(11)]
            elif mutation == 'gaps':
                value['gaps'] = [{'text': '原文缺少时间', 'source_message_ids': ['e1']} for _ in range(9)]
            else:
                value['unexpected'] = 'untrusted'
            with self.subTest(mutation=mutation), self.assertRaises(briefing.BriefingError):
                briefing.compact_provider_projects(value, KNOWN_IDS, EVIDENCE)

    def test_at_most_eight_projects_still_use_strict_validation(self):
        # Bypassing validation for the ordinary path would let fabricated sources persist.
        value = provider_briefing(8)
        self.assertEqual(briefing.compact_provider_projects(value, KNOWN_IDS, EVIDENCE), value)
        value['projects'][7]['source_message_ids'] = ['fabricated']
        with self.assertRaises(briefing.BriefingError) as caught:
            briefing.compact_provider_projects(value, KNOWN_IDS, EVIDENCE)
        self.assertEqual(caught.exception.code, 'invalid_source_reference')

    def test_persisted_validator_still_rejects_nine_projects(self):
        # Relaxing the shared validator would admit overlong persisted or Signal reports.
        with self.assertRaises(briefing.BriefingError) as caught:
            briefing.validate_briefing(provider_briefing(9), KNOWN_IDS, EVIDENCE)
        self.assertEqual(caught.exception.detail['path'], 'briefing.projects')
        self.assertEqual(caught.exception.detail['rule'], 'array_limit')
        self.assertEqual(caught.exception.detail['maximum'], 8)


if __name__ == '__main__':
    unittest.main()

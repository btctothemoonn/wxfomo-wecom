import unittest

from scripts.wxfomo_lan.cross_ca import cross_ca_cards


CA = "0x" + "a" * 40


def msg(event, group, author, content):
    return dict(eventId=event, group=group, sender=author, content=content,
                observedAt="2026-09-05T01:00:00Z")


class CrossCATests(unittest.TestCase):
    def test_neighbor_discussion_is_cited_without_inflating_mentions(self):
        messages = [msg('a', '甲群', '猫', 'Base CA: ' + CA),
                    msg('b', '甲群', '狗', '上面那个有风险')]
        summary = dict(normalizedAddress=CA, contextSummary='狗提示风险', sourceMessageIDs=['a', 'b'])
        card = cross_ca_cards(messages, [summary])['items'][0]
        self.assertEqual(card['summary'], '狗提示风险')
        self.assertEqual(card['mentionCount'], 1)
        self.assertEqual(set(card['sourceMessageIDs']), {'a', 'b'})

    def test_neighbor_context_cannot_cross_groups_time_or_ambiguous_chains(self):
        summary = dict(normalizedAddress=CA, contextSummary='风险', sourceMessageIDs=['a', 'b'])
        for other in [msg('b', '乙群', '狗', '风险'),
                      dict(msg('b', '甲群', '狗', '风险'), observedAt='2026-09-05T01:05:00Z')]:
            cards = cross_ca_cards([msg('a', '甲群', '猫', 'Base: ' + CA), other], [summary])['items']
            self.assertIsNone(cards[0]['summary'])
        messages = [msg('a', '甲群', '猫', 'Base: ' + CA), msg('b', '甲群', '狗', '风险'),
                    msg('c', '甲群', '猫', 'BSC: ' + CA)]
        self.assertTrue(all(c['summary'] is None for c in cross_ca_cards(messages, [summary])['items']))

    def test_one_message_with_two_chains_cannot_assign_the_same_summary_to_both(self):
        summary = dict(normalizedAddress=CA, contextSummary='混合', sourceMessageIDs=['a'])
        cards = cross_ca_cards([msg('a', '甲群', '猫', 'Base: ' + CA + ' BSC: ' + CA)], [summary])['items']
        self.assertEqual(len(cards), 2)
        self.assertTrue(all(c['summary'] is None for c in cards))
        self.assertTrue(all(c['summaryUnavailableReason'] == 'unresolved_sources' for c in cards))

    def test_relay_duplicates_are_not_independent_views(self):
        messages = [msg("a", "甲群", "猫", "Base CA: " + CA + " 看好"),
                    msg("b", "乙群", "猫", "Base CA: " + CA + " 看好"),
                    msg("c", "乙群", "狗", "Base CA: " + CA + " 有风险")]
        result = cross_ca_cards(messages, [])
        self.assertEqual(result["total"], 1)
        card = result["items"][0]
        self.assertEqual((card["groupCount"], card["mentionCount"], card["uniqueStatementCount"],
                          card["duplicateCount"]), (2, 3, 2, 1))
        self.assertEqual(card["speakers"], ["狗", "猫"])
        self.assertEqual(set(card["sourceMessageIDs"]), {"a", "b", "c"})

    def test_known_chains_and_unconfirmed_groups_do_not_merge(self):
        result = cross_ca_cards([
            msg("a", "甲群", "猫", "Base CA: " + CA),
            msg("b", "乙群", "猫", "Ethereum: " + CA),
            msg("c", "甲群", "猫", CA), msg("d", "乙群", "猫", CA)], [])
        self.assertEqual(result["total"], 4)
        self.assertEqual(sorted(c["network"] for c in result["items"]),
                         ["base", "ethereum", "unknown", "unknown"])

    def test_summary_cannot_be_reused_across_conflicting_chains(self):
        messages = [msg("a", "甲群", "猫", "Base: " + CA),
                    msg("b", "乙群", "狗", "BSC: " + CA)]
        mixed = dict(address=CA, normalizedAddress=CA, contextSummary="混合结论",
                     sourceMessageIDs=["a", "b"])
        self.assertTrue(all(c["summary"] is None for c in cross_ca_cards(messages, [mixed])["items"]))
        mixed.update(sourceMessageIDs=["a"], contextSummary="猫提及地址")
        cards = cross_ca_cards(messages, [mixed])["items"]
        self.assertEqual(next(c for c in cards if c["network"]=="base")["summary"], "猫提及地址")
        self.assertIsNone(next(c for c in cards if c["network"]=="bsc")["summary"])

    def test_display_caps_do_not_change_full_window_counts(self):
        messages = [msg(str(i), "甲群" if i%2 else "乙群", "猫", "Base: " + CA)
                    for i in range(1500)]
        card = cross_ca_cards(messages, [])["items"][0]
        self.assertEqual(card["mentionCount"], 1500)
        self.assertEqual(card["uniqueStatementCount"], 1)
        self.assertLessEqual(len(card["sourceMessageIDs"]), 5)

    def test_url_chain_and_solana_candidate_and_false_address(self):
        sol = "So11111111111111111111111111111111111111112"
        cards = cross_ca_cards([msg("a", "甲群", "猫", "https://basescan.org/address/"+CA),
                               msg("b", "乙群", "狗", "SOL CA: "+sol),
                               msg("c", "甲群", "狗", "not-a-CA")], [])["items"]
        self.assertEqual({c["network"] for c in cards}, {"base", "solana"})


if __name__ == "__main__":
    unittest.main()

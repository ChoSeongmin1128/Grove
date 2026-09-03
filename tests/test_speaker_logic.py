import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('speaker_logic', Path(__file__).parents[1] / 'scripts/research_speaker_logic.py')
logic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(logic)


class SpeakerLogicTests(unittest.TestCase):
    def test_bad_unit_does_not_poison_following_valid_unit(self):
        u = dict(index=0, text='네 시작', start=0, end=3)
        words = [dict(text='네', start=100, end=101), dict(text='시작', start=1, end=2)]
        units = logic.project_aligned(u, words, [dict(start=0, end=3, speaker='a')], 3)
        self.assertIsNone(units[0]['speaker'])
        self.assertTrue(units[0]['timeIsParentContext'])
        self.assertEqual(units[1]['speaker'], 'a')
        self.assertTrue(logic.reconstruct(units)[0]['timeIsParentContext'])

    def test_guarded_abstains_only_for_flagged_unit(self):
        u = dict(index=0, text='네 시작', start=0, end=3)
        words = [dict(text='네', start=.1, end=.5, flags=['upstreamTimestampRepair']),
                 dict(text='시작', start=1, end=2)]
        units = logic.project_aligned(u, words, [dict(start=0, end=3, speaker='a')], 3, guarded=True)
        self.assertEqual([u['speaker'] for u in units], [None, 'a'])
        self.assertEqual(''.join(u['text'] for u in units), '네 시작')

    def test_activity_union_keeps_cross_speaker_overlap(self):
        turns = [dict(start=0, end=1, speaker='a'), dict(start=0, end=1, speaker='a'),
                 dict(start=.5, end=2, speaker='a'), dict(start=.5, end=1, speaker='b')]
        self.assertEqual(logic.union_turns(turns), [dict(start=0, end=2, speaker='a'),
                                                  dict(start=.5, end=1, speaker='b')])
    def test_moss_format_prefix_matches_app_decoder(self):
        self.assertEqual(logic.moss_body(dict(text='[S01]  네', speaker_id='S01')), ' 네')
        for segment in [dict(text='[S01] 네'), dict(text='[S01] 네', speaker_id='S02'),
                        dict(text='[S01]\t네', speaker_id='S01')]:
            self.assertEqual(logic.moss_body(segment), segment['text'])

    def test_same_cluster_union(self):
        turns = [dict(start=0, end=1, speaker='a'), dict(start=0, end=1, speaker='a'),
                 dict(start=0, end=1.5, speaker='b')]
        self.assertEqual(logic.project(0, 2, turns), ('b', {'a': 1, 'b': 1.5}))

    def test_tie_and_missing_are_unassigned(self):
        turns = [dict(start=0, end=1, speaker='a'), dict(start=1, end=2, speaker='b')]
        self.assertIsNone(logic.project(0, 2, turns)[0])
        self.assertIsNone(logic.project(3, 4, turns)[0])
        self.assertEqual(logic.project(1, 1, turns)[0], 'b')

    def test_original_punctuation_spaces_and_number_preserved(self):
        text = '  네? 폭은 520, HTML입니다. '
        words = [{'text': t} for t in ['네', '폭은', '520', 'HTML입니다']]
        spans = logic.source_spans(text, words)
        self.assertEqual(''.join(text[a:b] for a, b in spans), text)
        self.assertEqual(text[slice(*spans[0])], '  네? ')

    def test_normalization_expansion_cannot_split_source_character(self):
        with self.assertRaises(ValueError):
            logic.source_spans('ﬃ', [{'text': 'f'}, {'text': 'fi'}])

    def test_text_mismatch_fails_closed_without_deletion(self):
        u = dict(index=0, text='그럼 합니다.', start=0, end=2)
        result = logic.project_aligned(u, [dict(text='합니다', start=1, end=2)], [], 3)
        self.assertEqual(result[0]['text'], u['text'])
        self.assertIsNone(result[0]['speaker'])
        self.assertEqual(result[0]['status'], 'alignment_text_mismatch')

    def test_repeated_words_map_in_order(self):
        text = '네, 네. 네?'
        spans = logic.source_spans(text, [dict(text='네')]*3)
        self.assertEqual([text[a:b] for a,b in spans], ['네, ', '네. ', '네?'])

    def test_change_inside_utterance_is_reconstructed(self):
        u = dict(index=0, text='네. 시작합니다.', start=0, end=3)
        turns = [dict(start=0, end=1, speaker='a'), dict(start=1, end=3, speaker='b')]
        units = logic.project_aligned(u, [dict(text='네', start=.1, end=.3),
            dict(text='시작합니다', start=1.1, end=2)], turns, 3)
        groups = logic.reconstruct(units)
        self.assertEqual([g['speaker'] for g in groups], ['a', 'b'])
        self.assertEqual(''.join(g['text'] for g in groups), u['text'])

    def test_no_nearest_speaker_fill(self):
        u = dict(index=0, text='네', start=0, end=1)
        units = logic.project_aligned(u, [dict(text='네', start=.1, end=.3)],
            [dict(start=.4, end=1, speaker='a')], 1)
        self.assertIsNone(units[0]['speaker'])

    def test_invalid_time_keeps_original_unassigned(self):
        u = dict(index=0, text='네', start=0, end=1)
        for start,end in [(0,0),(-1,.2),(.2,2),(float('nan'),.5)]:
            result = logic.project_aligned(u, [dict(text='네', start=start,end=end)], [], 1)
            self.assertEqual(result[0]['text'], '네')
            self.assertEqual(result[0]['status'], 'invalid_alignment_time')

    def test_reconstruction_does_not_merge_parents(self):
        units = [dict(index=i, text='네', start=i, end=i+1, sourceStart=0, sourceEnd=1, speaker='a') for i in range(2)]
        self.assertEqual(len(logic.reconstruct(units)), 2)


if __name__ == '__main__':
    unittest.main()

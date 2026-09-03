"""Synthetic-only metric contracts; optional scientific dependencies may be absent."""

import argparse
from collections import defaultdict
import contextlib
from copy import deepcopy
import hashlib
import importlib
import importlib.util
import io
import itertools
import json
from pathlib import Path
import random
from types import SimpleNamespace
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    'speaker_logic_metrics', Path(__file__).parents[1] / 'scripts/research_speaker_logic.py')
logic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(logic)


def item(speaker, text='', start=0, end=1):
    return dict(speaker=speaker, text=text, start=start, end=end)


def json_bytes(value):
    return json.dumps(value, ensure_ascii=False).encode('utf-8')


def sha(data):
    return hashlib.sha256(data).hexdigest()


class MemoryOutput:
    """Exercise the CLI serializer without creating files or touching app data."""

    def __init__(self, exists=False):
        self.already_exists = exists
        self.parent = self
        self.writes = []

    def exists(self):
        return self.already_exists

    def mkdir(self, **kwargs):
        pass

    def open(self, mode):
        if mode != 'x':
            raise AssertionError('Research output must use exclusive creation')
        return self

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def write(self, value):
        self.writes.append(value)


class SpeakerLogicMetricTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        for dependency in ('numpy', 'scipy.optimize', 'pyannote.core', 'pyannote.metrics.diarization'):
            try:
                importlib.import_module(dependency)
            except ImportError as error:
                raise unittest.SkipTest(f'Optional metric dependency unavailable: {error}') from error

    def test_unknown_text_is_not_a_permutable_speaker(self):
        ref = [item('1', 'abc')]
        unknown = logic.text_scores(ref, [item(None, 'abc')])
        self.assertEqual(unknown['CER'], 0)
        self.assertEqual(unknown['cpCER'], 2)
        self.assertEqual(unknown['cpEdits'], 6)
        self.assertEqual(unknown['unassignedCharacters'], 3)
        self.assertEqual(unknown['cpMapping'], {})
        partial = logic.text_scores(ref, [item('a', 'ab'), item(None, 'c')])
        self.assertEqual(partial['cpEdits'], 2)
        self.assertAlmostEqual(partial['cpCER'], 2 / 3)

    def test_text_permutation_extra_speaker_and_empty_hypothesis(self):
        ref = [item('1', 'abc'), item('2', 'de')]
        permuted = logic.text_scores(ref, [item('b', 'abc'), item('a', 'de')])
        self.assertEqual(permuted['cpCER'], 0)
        self.assertEqual(permuted['cpMapping'], {'b': '1', 'a': '2'})
        extra = logic.text_scores([item('1', 'abc')], [item('a', 'abc'), item('b', 'xyz')])
        self.assertEqual(extra['cpEdits'], 3)
        self.assertIsNone(extra['cpMapping']['b'])
        missing = logic.text_scores(ref, [])
        self.assertEqual(missing['CER'], 1)
        self.assertEqual(missing['cpCER'], 1)
        self.assertEqual(missing['referenceCharacters'], 5)

    def test_hungarian_cost_matches_exhaustive_small_permutations(self):
        rng = random.Random(731)
        for trial in range(100):
            ref = [item(str(i), ''.join(rng.choice('abc') for _ in range(rng.randint(1, 4))))
                   for i in range(rng.randint(1, 3))]
            hyp = [item(None if rng.randrange(4) == 0 else str(rng.randrange(4)),
                        ''.join(rng.choice('abc') for _ in range(rng.randint(0, 4))))
                   for _ in range(rng.randint(0, 4))]
            refs, hyps, unknown = defaultdict(str), defaultdict(str), ''
            for row in ref:
                refs[row['speaker']] += logic.normalized(row['text'])
            for row in hyp:
                if row['speaker'] is None:
                    unknown += logic.normalized(row['text'])
                else:
                    hyps[row['speaker']] += logic.normalized(row['text'])
            left, right = list(refs.values()), list(hyps.values())
            size = max(len(left), len(right))
            left += [''] * (size - len(left))
            right += [''] * (size - len(right))
            expected = min(sum(logic.edit_distance(left[i], right[j])
                               for i, j in enumerate(permutation))
                           for permutation in itertools.permutations(range(size))) + len(unknown)
            with self.subTest(trial=trial):
                self.assertEqual(logic.text_scores(ref, hyp)['cpEdits'], expected)

    def test_der_components_include_silence_and_permutation(self):
        ref = [item('1', start=0, end=1), item('2', start=1, end=2)]
        cases = [
            ('permuted', [item('b', start=0, end=1), item('a', start=1, end=2)], 0, 0, 0, 0),
            ('merged', [item('a', start=0, end=2)], .5, 0, 0, 1),
            ('missing', [], 1, 2, 0, 0),
            ('silence-false-alarm', [item('a', start=0, end=1), item('b', start=1, end=2),
                                     item('a', start=2, end=3)], .5, 0, 1, 0),
        ]
        for name, hyp, der, missed, false, confusion in cases:
            with self.subTest(name=name):
                score = logic.diarization_scores(ref, hyp, [(0, 3)])
                self.assertEqual(score['DER'], der)
                self.assertEqual(score['missedSeconds'], missed)
                self.assertEqual(score['falseAlarmSeconds'], false)
                self.assertEqual(score['confusionSeconds'], confusion)
                self.assertEqual(score['referenceSpeakerSeconds'], 2)
                self.assertTrue(score['independentlyVerified'])

    def test_der_unions_same_label_but_retains_cross_speaker_overlap(self):
        ref = [item('1', start=0, end=1), item('2', start=0, end=1)]
        hyp = [item('a', start=0, end=1), item('a', start=0, end=1)]
        before = deepcopy(hyp)
        score = logic.diarization_scores(ref, hyp, [(0, 1)])
        self.assertEqual(score['DER'], .5)
        self.assertEqual(score['missedSeconds'], 1)
        self.assertEqual(score['falseAlarmSeconds'], 0)
        self.assertEqual(hyp, before)
        with self.assertRaisesRegex(ValueError, 'no_reference_speech_in_uem'):
            logic.diarization_scores(ref, hyp, [(2, 3)])

    def test_projection_changes_cpcer_not_raw_der_or_text(self):
        ref = [item('1', '가', 0, 1), item('2', '나', 1, 2)]
        turns = [item('a', start=0, end=1), item('b', start=1, end=2)]
        original = deepcopy(turns)
        utterance = dict(index=0, text=' 가, 나. ', start=0, end=2)
        baseline = [dict(utterance, speaker=logic.project(0, 2, turns)[0])]
        before = logic.diarization_scores(ref, turns, [(0, 2)])
        aligned = logic.project_aligned(utterance, [item(None, '가', .1, .9),
                                                   item(None, '나', 1.1, 1.9)], turns, 2)
        self.assertEqual(logic.text_scores(ref, baseline)['cpCER'], 2)
        self.assertEqual(logic.text_scores(ref, aligned)['cpCER'], 0)
        self.assertEqual(logic.text_scores(ref, aligned)['CER'], 0)
        self.assertEqual(''.join(unit['text'] for unit in aligned), utterance['text'])
        self.assertEqual(logic.diarization_scores(ref, turns, [(0, 2)]), before)
        self.assertEqual(turns, original)

    def synthetic_sources(self):
        moss = dict(audioDurationSeconds=2, hitTokenLimit=False, hasUnparsedText=False,
                    segments=[dict(start=0, end=2, text='[S1] 가 나', speaker_id='S1')])
        sources = {
            'moss.json': json_bytes(moss),
            'turns.json': json_bytes(dict(segments=[item('a', start=0, end=1), item('b', start=1, end=2)])),
            'reference.tsv': 'start\tend\tspeaker\ttext\n00:00\t00:01\t1\t가\n00:01\t00:02\t2\t나\n'.encode(),
            'uem.txt': b'synthetic 1 0 2\n',
            'audio.wav': b'synthetic audio identity, never decoded or inferred',
        }
        aligned = dict(schemaVersion=1, sourceMossSha256=sha(sources['moss.json']),
                       sourceAudioSha256=sha(sources['audio.wav']), referenceUsed=False,
                       utterances=[dict(index=0, start=0, end=2, text='가 나',
                                        words=[dict(text='가', start=.1, end=.9, flags=[]),
                                               dict(text='나', start=1.1, end=1.9, flags=[])])])
        sources['alignment.json'] = json_bytes(aligned)
        return sources

    def run_memory_cli(self, sources, output=None):
        output = output or MemoryOutput()
        args = SimpleNamespace(moss=Path('moss.json'), turns=Path('turns.json'),
                               reference=Path('reference.tsv'), uem=Path('uem.txt'),
                               alignment=Path('alignment.json'), audio=Path('audio.wav'),
                               condition=[], combine=False, output=output)
        reads = []

        def read_source(path):
            key = str(path)
            reads.append(key)
            data = sources[key]
            return data, sha(data)

        actual_digest = logic.digest

        def hash_source(path):
            data = sources.get(str(path))
            return sha(data) if data is not None else actual_digest(path)

        with patch.object(argparse.ArgumentParser, 'parse_args', return_value=args), \
             patch.object(logic, 'snapshot', side_effect=read_source), \
             patch.object(logic, 'digest', side_effect=hash_source), \
             contextlib.redirect_stdout(io.StringIO()):
            logic.main()
        return json.loads(''.join(output.writes)), reads

    def test_cli_source_snapshots_and_separate_schema_one_sidecar(self):
        sources = self.synthetic_sources()
        before = deepcopy(sources)
        result, reads = self.run_memory_cli(sources)
        self.assertEqual(result['schemaVersion'], 1)
        self.assertFalse(result['appIntegrated'])
        self.assertFalse(result['referenceUsedForInference'])
        self.assertEqual(result['sourceMossSha256'], sha(sources['moss.json']))
        self.assertEqual(result['referenceSHA256'], sha(sources['reference.tsv']))
        self.assertEqual(result['uemSHA256'], sha(sources['uem.txt']))
        self.assertEqual(result['alignment']['alignmentSHA256'], sha(sources['alignment.json']))
        self.assertEqual(sorted(reads), sorted(['moss.json', 'reference.tsv', 'uem.txt',
                                              'turns.json', 'alignment.json']))
        conditions = result['conditions']
        self.assertEqual(conditions['A-baseline']['text']['cpCER'], 2)
        self.assertEqual(conditions['B-generated']['text']['cpCER'], 0)
        self.assertEqual(conditions['B-generated']['activity'], conditions['A-baseline']['activity'])
        self.assertTrue(conditions['B-generated']['textExactlyPreserved'])
        self.assertEqual(sources, before)

    def test_cli_refuses_mismatched_source_hashes_without_output(self):
        for key in ('sourceMossSha256', 'sourceAudioSha256'):
            with self.subTest(key=key):
                sources = self.synthetic_sources()
                aligned = json.loads(sources['alignment.json'])
                aligned[key] = '0' * 64
                sources['alignment.json'] = json_bytes(aligned)
                output = MemoryOutput()
                with self.assertRaises(ValueError):
                    self.run_memory_cli(sources, output)
                self.assertEqual(output.writes, [])

    def test_cli_refuses_reference_leakage_and_invalid_alignment_identity(self):
        mutations = [
            lambda aligned: aligned.update(referenceUsed=True),
            lambda aligned: aligned.pop('referenceUsed'),
            lambda aligned: aligned.update(schemaVersion=2),
            lambda aligned: aligned.update(schemaVersion=True),
            lambda aligned: aligned['utterances'][0].update(index=False),
            lambda aligned: aligned['utterances'].append(deepcopy(aligned['utterances'][0])),
            lambda aligned: aligned['utterances'][0].update(text='다른 합성 텍스트'),
            lambda aligned: aligned['utterances'][0].update(start=.2),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                sources = self.synthetic_sources()
                aligned = json.loads(sources['alignment.json'])
                mutate(aligned)
                sources['alignment.json'] = json_bytes(aligned)
                output = MemoryOutput()
                with self.assertRaises(ValueError):
                    self.run_memory_cli(sources, output)
                self.assertEqual(output.writes, [])

    def test_moss_duration_is_finite_positive_and_requires_native_envelope(self):
        template = json.loads(self.synthetic_sources()['moss.json'])
        for duration in (0, -1, True, float('nan'), float('inf'), None):
            with self.subTest(duration=duration):
                raw = dict(template, audioDurationSeconds=duration)
                with self.assertRaisesRegex(ValueError, 'invalid_moss_duration'):
                    logic.validate_moss(raw)
        legacy_without_duration = deepcopy(template)
        del legacy_without_duration['audioDurationSeconds']
        with self.assertRaisesRegex(ValueError, 'native envelope required'):
            logic.validate_moss(legacy_without_duration)

    def test_zero_reference_characters_is_not_reported_as_zero_error(self):
        with self.assertRaises(ValueError):
            logic.text_scores([item('1', '... ?!')], [])

    def test_cli_refuses_invalid_moss_times_and_unknown_raw_labels(self):
        for start, end in [(-1, 1), (1, 0), (float('nan'), 1), (False, 1), (0, 3)]:
            with self.subTest(start=start, end=end):
                sources = self.synthetic_sources()
                moss = json.loads(sources['moss.json'])
                moss['segments'][0].update(start=start, end=end)
                sources['moss.json'] = json_bytes(moss)
                with self.assertRaisesRegex(ValueError, 'invalid_moss_segment'):
                    self.run_memory_cli(sources)
        for label in (None, '', ' ', True, {'speaker': 'a'}):
            with self.subTest(label=label):
                sources = self.synthetic_sources()
                turns = json.loads(sources['turns.json'])
                turns['segments'][0]['speaker'] = label
                sources['turns.json'] = json_bytes(turns)
                with self.assertRaisesRegex(ValueError, 'invalid_diarization_turn'):
                    self.run_memory_cli(sources)

    def test_cli_refuses_existing_output(self):
        output = MemoryOutput(exists=True)
        with self.assertRaisesRegex(SystemExit, 'Refusing to overwrite'):
            self.run_memory_cli(self.synthetic_sources(), output)
        self.assertEqual(output.writes, [])


if __name__ == '__main__':
    unittest.main()

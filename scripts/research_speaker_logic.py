#!/usr/bin/env python3
"""Offline-only speaker projection ablation. Never edits Grove documents or raw runs.

Inference does not receive reference labels. Scoring consumes a frozen reference only
after hypotheses are built. Output is a separate, non-overwriting research sidecar.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import importlib.metadata
import json
import math
import re
import unicodedata
from collections import defaultdict
from pathlib import Path


def normalized(text):
    return ''.join(c for c in unicodedata.normalize('NFKC', text).lower() if c.isalnum())


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def snapshot(path):
    data = Path(path).read_bytes()
    return data, hashlib.sha256(data).hexdigest()


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def validate_moss(raw):
    duration = raw.get('audioDurationSeconds')
    if not finite(duration) or duration <= 0:
        raise ValueError('invalid_moss_duration; native envelope required')
    if raw.get('hitTokenLimit') or raw.get('hasUnparsedText'):
        raise ValueError('incomplete_moss_output')
    if not isinstance(raw.get('segments'), list) or not raw['segments']:
        raise ValueError('missing_moss_segments')
    for segment in raw['segments']:
        a, b = segment.get('start'), segment.get('end')
        if not (finite(a) and finite(b) and 0 <= a <= b <= duration
                and isinstance(segment.get('text'), str)):
            raise ValueError('invalid_moss_segment')
    return duration


def moss_body(segment):
    text, cluster = segment['text'], segment.get('speaker_id')
    if isinstance(cluster, str) and re.fullmatch(r'S[0-9]+', cluster):
        prefix = '[' + cluster + '] '
        if text.startswith(prefix):
            return text[len(prefix):]
    return text


def edit_distance(left, right):
    previous = list(range(len(right) + 1))
    for i, a in enumerate(left, 1):
        row = [i]
        for j, b in enumerate(right, 1):
            row.append(min(row[-1] + 1, previous[j] + 1, previous[j-1] + (a != b)))
        previous = row
    return previous[-1]


def overlap_seconds(start, end, turns):
    grouped = defaultdict(list)
    for turn in turns:
        a, b = max(start, turn['start']), min(end, turn['end'])
        if b > a:
            grouped[str(turn['speaker'])].append((a, b))
    totals = {}
    for speaker, intervals in grouped.items():
        merged = []
        for a, b in sorted(intervals):
            if merged and a <= merged[-1][1]:
                merged[-1] = (merged[-1][0], max(b, merged[-1][1]))
            else:
                merged.append((a, b))
        totals[speaker] = sum(b-a for a, b in merged)
    return totals


def union_turns(turns):
    grouped = defaultdict(list)
    for turn in turns:
        grouped[str(turn['speaker'])].append((turn['start'], turn['end']))
    result = []
    for speaker, intervals in grouped.items():
        merged = []
        for a, b in sorted(intervals):
            if merged and a <= merged[-1][1]:
                merged[-1] = (merged[-1][0], max(b, merged[-1][1]))
            else:
                merged.append((a, b))
        result.extend(dict(start=a, end=b, speaker=speaker) for a, b in merged)
    return result


def project(start, end, turns):
    """Match production projection-v1: union within cluster, abstain on silence/ties."""
    if start == end:
        active = {str(t['speaker']) for t in turns if t['start'] <= start < t['end']}
        return (next(iter(active)), {}) if len(active) == 1 else (None, {})
    overlaps = overlap_seconds(start, end, turns)
    ranked = sorted(overlaps, key=lambda key: (-overlaps[key], key))
    if not ranked or (len(ranked) > 1 and abs(overlaps[ranked[0]]-overlaps[ranked[1]]) < .001):
        return None, overlaps
    return ranked[0], overlaps


def source_spans(text, words):
    """Exact normalized correspondence only; no fuzzy matching or proportional timing.

    Keep every original character, space and punctuation exactly once. Unsupported
    cross-character normalization fails closed rather than guessing original offsets.
    """
    indices, chars = [], []
    for index, char in enumerate(text):
        for unit in normalized(char):
            indices.append(index)
            chars.append(unit)
    cleaned = ''.join(chars)
    tokens = [normalized(w['text']) for w in words]
    if not cleaned or cleaned != normalized(text) or not tokens or any(not t for t in tokens):
        raise ValueError('unsupported_or_empty_normalization')
    if ''.join(tokens) != cleaned:
        raise ValueError('alignment_text_mismatch')
    token_starts, offset = [], 0
    for token in tokens:
        token_starts.append(indices[offset])
        offset += len(token)
    if any(a >= b for a, b in zip(token_starts, token_starts[1:])):
        raise ValueError('alignment_splits_one_source_character')
    boundaries = [0] + token_starts[1:] + [len(text)]
    return [(a, b) for a, b in zip(boundaries, boundaries[1:])]


def project_aligned(utterance, words, turns, duration, guarded=False):
    try:
        spans = source_spans(utterance['text'], words)
    except (ValueError, KeyError, TypeError) as error:
        return [dict(utterance, speaker=None, sourceStart=0,
                     sourceEnd=len(utterance['text']), status=str(error), timeIsParentContext=True)]
    projected = []
    last_start = last_end = -1.
    for word, (left, right) in zip(words, spans):
        a, b = word.get('start'), word.get('end')
        flags = word.get('flags', [])
        invalid = (any(f in flags for f in ('outsideCropOrInvalid',
            'crossesSourceUtteranceBoundary', 'sourceMappingFailed')) or not (
            finite(a) and finite(b) and 0 <= a < b <= duration
            and a >= last_start and b >= last_end))
        if invalid:
            speaker, evidence, status = None, {}, 'invalid_alignment_time'
        elif guarded and flags:
            speaker, evidence, status = None, {}, 'flagged_alignment_time'
        else:
            speaker, evidence = project(a, b, turns)
            status = 'assigned' if speaker is not None else 'unassigned'
        if not invalid:
            last_start, last_end = max(last_start, a), max(last_end, b)
        projected.append(dict(utterance, start=utterance['start'] if invalid else a,
            end=utterance['end'] if invalid else b, timeIsParentContext=invalid,
            text=utterance['text'][left:right], speaker=speaker,
            sourceStart=left, sourceEnd=right, alignmentText=word['text'],
            alignmentFlags=flags, overlapSeconds=evidence, status=status))
    assert ''.join(w['text'] for w in projected) == utterance['text']
    return projected


def reconstruct(units):
    groups = []
    for unit in units:
        if (groups and groups[-1]['index'] == unit['index']
                and groups[-1]['speaker'] == unit['speaker']
                and groups[-1]['sourceEnd'] == unit['sourceStart']):
            groups[-1]['text'] += unit['text']
            groups[-1]['start'] = min(groups[-1]['start'], unit['start'])
            groups[-1]['end'] = max(groups[-1]['end'], unit['end'])
            groups[-1]['sourceEnd'] = unit['sourceEnd']
            groups[-1]['timeIsParentContext'] |= unit.get('timeIsParentContext', False)
            groups[-1]['statuses'] = sorted(set(groups[-1]['statuses'] + [unit.get('status', 'unknown')]))
            groups[-1]['alignmentFlags'] = sorted(set(groups[-1]['alignmentFlags'] + unit.get('alignmentFlags', [])))
        else:
            groups.append(dict({k: unit[k] for k in ('index', 'text', 'speaker', 'start', 'end', 'sourceStart', 'sourceEnd')},
                timeIsParentContext=unit.get('timeIsParentContext', False),
                statuses=[unit.get('status', 'unknown')], alignmentFlags=unit.get('alignmentFlags', [])))
    return groups


def text_scores(reference, hypothesis):
    from scipy.optimize import linear_sum_assignment
    import numpy as np
    refs, hyps = defaultdict(str), defaultdict(str)
    unknown = ''
    for item in reference:
        refs[str(item['speaker'])] += normalized(item['text'])
    for item in hypothesis:
        if item['speaker'] is None:
            unknown += normalized(item['text'])
        else:
            hyps[str(item['speaker'])] += normalized(item['text'])
    ref_labels, hyp_labels = sorted(refs), sorted(hyps)
    size = max(len(ref_labels), len(hyp_labels))
    cost = np.array([[edit_distance(refs[ref_labels[i]] if i < len(ref_labels) else '',
        hyps[hyp_labels[j]] if j < len(hyp_labels) else '') for j in range(size)] for i in range(size)])
    rows, columns = linear_sum_assignment(cost)
    denominator = sum(map(len, refs.values()))
    if not denominator:
        raise ValueError('reference_has_no_scored_characters')
    cp_edits = sum(int(cost[i, j]) for i, j in zip(rows, columns)) + len(unknown)
    plain_ref = normalized(''.join(i['text'] for i in reference))
    plain_hyp = normalized(''.join(i['text'] for i in hypothesis))
    edits = edit_distance(plain_ref, plain_hyp)
    return dict(CER=edits/denominator, textEdits=edits, referenceCharacters=denominator,
        cpCER=cp_edits/denominator, cpEdits=cp_edits, unassignedCharacters=len(unknown),
        unknownPolicy='unmapped-insertions; never assign unknown text to a reference speaker',
        cpMapping={hyp_labels[j]: ref_labels[i] if i < len(ref_labels) else None
                   for i, j in zip(rows, columns) if j < len(hyp_labels)})


def diarization_scores(reference, turns, uem):
    import numpy as np
    from scipy.optimize import linear_sum_assignment
    from pyannote.core import Annotation, Segment, Timeline
    from pyannote.metrics.diarization import DiarizationErrorRate
    ref = [t for t in reference if t['end'] is not None]
    labels_r = sorted({str(t['speaker']) for t in ref})
    labels_h = sorted({str(t['speaker']) for t in turns})
    points = sorted({t[k] for t in ref + turns for k in ('start', 'end')} | {p for pair in uem for p in pair})
    atoms, intersections = [], np.zeros((len(labels_r), len(labels_h)))
    for a, b in zip(points, points[1:]):
        mid = (a+b)/2
        if not any(left <= mid < right for left, right in uem):
            continue
        r = {str(t['speaker']) for t in ref if t['start'] <= mid < t['end']}
        h = {str(t['speaker']) for t in turns if t['start'] <= mid < t['end']}
        atoms.append((b-a, r, h))
        for rr in r:
            for hh in h:
                intersections[labels_r.index(rr), labels_h.index(hh)] += b-a
    rows, cols = linear_sum_assignment(-intersections)
    mapping = {labels_h[j]: labels_r[i] for i, j in zip(rows, cols)}
    total = miss = false = confusion = 0.
    for span, r, h in atoms:
        total += span*len(r)
        miss += span*max(len(r)-len(h), 0)
        false += span*max(len(h)-len(r), 0)
        confusion += span*(min(len(r), len(h))-sum(mapping.get(hh) in r for hh in h))
    if total <= 0:
        raise ValueError('no_reference_speech_in_uem')
    def annotation(items):
        result = Annotation()
        # The event sweep uses active speaker sets, not duplicate same-cluster tracks.
        for index, item in enumerate(union_turns(items)):
            result[Segment(item['start'], item['end']), index] = str(item['speaker'])
        return result
    checked = DiarizationErrorRate(collar=0, skip_overlap=False)(annotation(ref), annotation(turns),
        uem=Timeline([Segment(a, b) for a, b in uem]), detailed=True)
    for key, value in [('total', total), ('missed detection', miss), ('false alarm', false), ('confusion', confusion)]:
        assert abs(checked[key]-value) < .0001, (key, checked[key], value)
    short = [t for t in ref if t['end']-t['start'] <= 1.0 and
             any(a <= t['start'] and t['end'] <= b for a, b in uem)]
    short_coverage = []
    for t in short:
        matching = [h for h in turns if mapping.get(str(h['speaker'])) == str(t['speaker'])]
        coverage = sum(overlap_seconds(t['start'], t['end'], matching).values())
        short_coverage.append(dict(t, coveredFraction=coverage/(t['end']-t['start'])))
    return dict(DER=(miss+false+confusion)/total, confusionRate=confusion/total,
        missedSeconds=miss, falseAlarmSeconds=false, confusionSeconds=confusion,
        referenceSpeakerSeconds=total, mapping=mapping, independentlyVerified=True,
        shortTurns=short_coverage)


def read_reference(data):
    def seconds(value):
        if not value:
            return None
        pieces = value.split(':')
        return sum(float(p) * 60**i for i, p in enumerate(reversed(pieces)))
    with io.StringIO(data.decode('utf-8')) as handle:
        return [dict(start=seconds(r['start']), end=seconds(r['end']), speaker=r['speaker'], text=r['text'])
                for r in csv.DictReader(handle, delimiter='\t')]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--moss', type=Path, required=True)
    parser.add_argument('--turns', type=Path, required=True)
    parser.add_argument('--alignment', type=Path)
    parser.add_argument('--audio', type=Path, help='Required with alignment for input identity verification')
    parser.add_argument('--combine', action='store_true', help='Exploratory combination after isolated comparisons')
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--uem', type=Path, required=True)
    parser.add_argument('--condition', action='append', default=[], help='name=turns.json')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise SystemExit('Refusing to overwrite an existing research result')
    moss_bytes, moss_sha = snapshot(args.moss)
    raw = json.loads(moss_bytes)
    duration = validate_moss(raw)
    utterances = [dict(index=i, start=s['start'], end=s['end'], rawText=s['text'],
        text=moss_body(s)) for i, s in enumerate(raw['segments'])]
    reference_bytes, reference_sha = snapshot(args.reference)
    uem_bytes, uem_sha = snapshot(args.uem)
    reference = read_reference(reference_bytes)
    for r in reference:
        if not (finite(r['start']) and 0 <= r['start'] < duration and r['speaker']
                and (r['end'] is None or finite(r['end']) and r['start'] < r['end'] <= duration)):
            raise ValueError('invalid_reference_turn')
    uem = [(float(p[2]), float(p[3])) for l in uem_bytes.decode('utf-8').splitlines()
           if (p := l.split()) and not p[0].startswith('#')]
    if not uem or any(not (finite(a) and finite(b) and 0 <= a < b <= duration) for a,b in uem):
        raise ValueError('invalid_uem')
    if any(a[1] > b[0] for a,b in zip(sorted(uem), sorted(uem)[1:])):
        raise ValueError('overlapping_uem_windows')
    paths = {'A-baseline': args.turns}
    for condition in args.condition:
        name, path = condition.split('=', 1)
        if not name or name in paths or name.startswith(('B-', 'D-')):
            raise ValueError('duplicate_or_reserved_condition_name')
        paths[name] = Path(path)
    results, turn_snapshots = {}, {}
    for name, path in paths.items():
        data, turns_sha = snapshot(path)
        turns = json.loads(data)['segments']
        for t in turns:
            if not (finite(t['start']) and finite(t['end']) and 0 <= t['start'] < t['end'] <= duration
                    and isinstance(t.get('speaker'), str) and t['speaker'].strip()):
                raise ValueError('invalid_diarization_turn')
        turn_snapshots[name] = turns
        hypothesis = [dict(u, speaker=project(u['start'], u['end'], turns)[0]) for u in utterances]
        results[name] = dict(turnsSHA256=turns_sha, text=text_scores(reference, hypothesis),
            activity=diarization_scores(reference, turns, uem), segments=hypothesis)
    alignment_metadata = None
    if args.alignment:
        alignment_bytes, alignment_sha = snapshot(args.alignment)
        aligned = json.loads(alignment_bytes)
        if type(aligned.get('schemaVersion')) is not int or aligned['schemaVersion'] != 1 or aligned.get('referenceUsed') is not False:
            raise ValueError('unsupported_or_reference_contaminated_alignment')
        if aligned['sourceMossSha256'] != moss_sha:
            raise ValueError('alignment_source_mismatch')
        if args.audio is None or aligned['sourceAudioSha256'] != digest(args.audio):
            raise ValueError('alignment_audio_identity_not_verified')
        alignment_metadata = {k: v for k, v in aligned.items() if k != 'utterances'}
        alignment_metadata['alignmentSHA256'] = alignment_sha
        if any(type(u.get('index')) is not int for u in aligned['utterances']):
            raise ValueError('invalid_alignment_index_type')
        indexed = {u['index']: u for u in aligned['utterances']}
        if (len(aligned['utterances']) != len(utterances) or len(indexed) != len(utterances)
                or set(indexed) != set(range(len(utterances)))):
            raise ValueError('alignment_utterance_indices_mismatch')
        for name, turns in turn_snapshots.items():
            if name != 'A-baseline' and not args.combine:
                continue
            for guarded in (False, True):
                units = []
                for u in utterances:
                    item = indexed[u['index']]
                    if item['text'] != u['text'] or item['start'] != u['start'] or item['end'] != u['end']:
                        raise ValueError('alignment_original_utterance_mismatch')
                    units.extend(project_aligned(u, item['words'], turns, duration, guarded=guarded))
                assert ''.join(u['text'] for u in units) == ''.join(u['text'] for u in utterances)
                policy = 'guarded' if guarded else 'generated'
                label = 'B-'+policy if name == 'A-baseline' else 'D-'+policy+'+'+name
                results[label] = dict(turnsSHA256=results[name]['turnsSHA256'], text=text_scores(reference, units),
                    activity=results[name]['activity'], units=units, segments=reconstruct(units),
                    textExactlyPreserved=True, rawActivityUnchanged=True,
                    failedUtteranceIndices=sorted({u['index'] for u in units if u['status'] not in ('assigned', 'unassigned')}))
    inspection = []
    for utterance in utterances:
        related = [r for r in reference if
            (r['end'] is not None and min(r['end'], utterance['end']) > max(r['start'], utterance['start']))
            or (r['end'] is None and utterance['start'] <= r['start'] <= utterance['end'])]
        inspection.append(dict(utterance, referenceForInspectionOnly=related,
            conditions={name: [dict(s, mappedSpeaker=None if s['speaker'] is None else value['activity']['mapping'].get(str(s['speaker'])))
                              for s in value['segments'] if s['index'] == utterance['index']]
                        for name, value in results.items()}))
    result = dict(schemaVersion=1, protocol='offline-speaker-ablation-v1',
        appIntegrated=False, referenceUsedForInference=False,
        evaluatorSHA256=digest(Path(__file__)),
        evaluatorDependencies={name: importlib.metadata.version(name) for name in ('numpy', 'scipy', 'pyannote.metrics')},
        sourceMossSha256=moss_sha, referenceSHA256=reference_sha,
        uemSHA256=uem_sha, uem=uem, alignment=alignment_metadata,
        conditions=results, inspection=inspection)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as handle:
        json.dump(result, handle, ensure_ascii=False, indent=2, allow_nan=False)
        handle.write('\n')
    print(json.dumps({k: {'text': v['text'], 'DER': v['activity']['DER']} for k, v in results.items()}, indent=2))


if __name__ == '__main__':
    main()

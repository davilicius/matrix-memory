"""Offline shadow ranking; never an authenticated or production search service.

The caller must supply trusted, freshly fetched source metadata for its owner.
No similarity score here proves that a question has an answer. Replacements and
source evidence still need review after retrieval. No text/model network calls.
"""
import hashlib
import json
from pathlib import Path

import numpy as np


class ProfileMismatch(ValueError):
    pass


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True,
                                    separators=(',', ':')).encode()).hexdigest()


def source_digest(memory):
    return digest({k: memory.get(k) or ''
                   for k in ('title', 'summary', 'content', 'place_text')})


def profile_digest(model_spec):
    return digest({'model': model_spec, 'window': 384, 'overlap': 64,
                   'pooling': 'attention-mask-mean', 'normalization': 'l2',
                   'aggregation': 'max-per-memory', 'special_tokens': 2})


def verify_artifacts(directory, model_spec):
    for name, expected in model_spec['sha256'].items():
        h = hashlib.sha256()
        with (Path(directory) / name).open('rb') as f:
            for block in iter(lambda: f.read(1024 * 1024), b''):
                h.update(block)
        if h.hexdigest() != expected:
            raise ProfileMismatch('Model or tokenizer artifact changed')


def source_manifest(corpus, owner_id):
    if not owner_id:
        raise ValueError('Owner scope required')
    records = {}
    for memory in corpus:
        mid = memory['id']
        if mid in records:
            raise ValueError('Duplicate memory ID')
        if memory.get('owner_id', owner_id) != owner_id:
            raise ValueError('Foreign memory in owner snapshot')
        records[mid] = {'owner_id': owner_id, 'hash': source_digest(memory),
                        'lifecycle_status': memory['lifecycle_status']}
    return records


def permitted(mid, current, owner_id):
    m = current.get(mid)
    return bool(m and m['owner_id'] == owner_id and
                m['lifecycle_status'] == 'active')


def fresh(mid, indexed, current, owner_id):
    old = indexed.get(mid)
    return bool(permitted(mid, current, owner_id) and old and
                old['owner_id'] == owner_id and
                old['hash'] == current[mid]['hash'])


def rrf(baseline, experimental, limit=6, k=60):
    """Equal fixed weights. Spanish priority is an acceptance gate, not a bias."""
    if k < 1 or limit < 1:
        raise ValueError('Invalid fusion parameters')
    scores = {}
    for ranking in (baseline, experimental):
        if len(set(ranking)) != len(ranking):
            raise ValueError('Duplicate memory in ranking')
        for rank, mid in enumerate(ranking, 1):
            scores[mid] = scores.get(mid, 0.) + 1. / (k + rank)
    return sorted(scores, key=lambda mid: (-scores[mid], mid))[:limit]


class ShadowIndex:
    def __init__(self, ids, chunks, owners, manifest, profile_id):
        self.ids = list(ids)
        self.chunks = np.asarray(chunks, dtype=np.float32)
        self.owners = np.asarray(owners)
        self.manifest = manifest
        self.profile_id = profile_id
        if (not self.ids or len(set(self.ids)) != len(self.ids)
                or set(self.ids) != set(manifest)):
            raise ValueError('Index/manifest IDs mismatch')
        if (self.chunks.ndim != 2 or not len(self.chunks)
                or self.owners.shape != (len(self.chunks),)
                or not np.issubdtype(self.owners.dtype, np.integer)
                or np.any(self.owners < 0) or np.any(self.owners >= len(self.ids))
                or not np.all(np.isfinite(self.chunks))):
            raise ValueError('Invalid chunk index')
        if set(self.owners.tolist()) != set(range(len(self.ids))):
            raise ValueError('Every memory must have at least one chunk')
        if not np.allclose(np.linalg.norm(self.chunks, axis=1), 1., atol=1e-4):
            raise ValueError('Index vectors must be normalized')

    def rank(self, query_vector, query_profile, current, owner_id, depth=18):
        if query_profile != self.profile_id:
            raise ProfileMismatch('Never mix embedding profiles')
        q = np.asarray(query_vector, dtype=np.float32)
        if (q.shape != (self.chunks.shape[1],) or not np.all(np.isfinite(q))
                or not np.isclose(np.linalg.norm(q), 1., atol=1e-4)):
            raise ValueError('Invalid query vector')
        if depth < 1:
            raise ValueError('Invalid candidate depth')
        scores = np.full(len(self.ids), -np.inf, dtype=np.float32)
        np.maximum.at(scores, self.owners, self.chunks @ q)
        # Filter before the cutoff, so stale/foreign chunks cannot consume slots.
        available = [i for i, mid in enumerate(self.ids)
                     if fresh(mid, self.manifest, current, owner_id)]
        available.sort(key=lambda i: (-float(scores[i]), self.ids[i]))
        return [self.ids[i] for i in available[:depth]]


def combine(baseline, experimental, current, owner_id, *, failure=None):
    """Replay an already-authorized live baseline and an optional shadow result.

    `failure` is supplied by a serving adapter; this offline function does not
    implement HTTP authentication, hard inference timeouts or client grants.
    Never hide a failed baseline behind an experimental-only response.
    """
    if baseline is None:
        raise ValueError('Successful baseline is required')
    b = list(dict.fromkeys(mid for mid in baseline if permitted(mid, current, owner_id)))[:6]
    if failure or experimental is None:
        return {'mode': 'baseline_fallback', 'ids': b,
                'reason': failure or 'experimental_unavailable'}
    e = list(dict.fromkeys(mid for mid in experimental if permitted(mid, current, owner_id)))[:18]
    return {'mode': 'shadow_rrf60', 'ids': rrf(b, e)}

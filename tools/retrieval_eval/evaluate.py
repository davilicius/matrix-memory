"""Offline retrieval experiment. No database writes, API calls, or remote model code.

Inputs are private JSON files; outputs MUST remain outside the public repository.
Model artifacts must be downloaded separately from a pinned upstream revision.
"""
import argparse
import hashlib
import json
import time
from pathlib import Path

import numpy as np


def windows(length, size=384, overlap=64):
    if size <= 0 or overlap < 0 or overlap >= size:
        raise ValueError("Require size > overlap >= 0")
    start = 0
    while start < length:
        end = min(start + size, length)
        yield start, end
        if end == length:
            break
        start = end - overlap


def metrics(cases, rankings):
    """Known-target hit rate, not exhaustive recall or answer accuracy."""
    if not cases:
        raise ValueError("Empty evaluation")
    found = []
    for case in cases:
        ids = rankings[case['case_id']]
        if len(set(ids)) != len(ids):
            raise ValueError("Rankings must contain unique memory IDs")
        relevant = set(case['relevant_ids'])
        rank = next((i + 1 for i, mid in enumerate(ids[:6]) if mid in relevant), 0)
        found.append(rank)
    return {
        'n': len(found),
        'hits_at_1': sum(r == 1 for r in found),
        'hits_at_3': sum(0 < r <= 3 for r in found),
        'hits_at_6': sum(r > 0 for r in found),
        'hit_rate_at_6': sum(r > 0 for r in found) / len(found),
        'mrr_at_6': sum(1 / r if r else 0 for r in found) / len(found),
    }


def aggregate_chunks(scores, owners, count):
    """Maximum passage similarity, returning each parent once."""
    result = np.full((len(scores), count), -np.inf, dtype=np.float32)
    for col, parent in enumerate(owners):
        result[:, parent] = np.maximum(result[:, parent], scores[:, col])
    return result


class Encoder:
    def __init__(self, directory, threads):
        import onnxruntime as ort
        from tokenizers import Tokenizer
        directory = Path(directory)
        self.tokenizer = Tokenizer.from_file(str(directory / 'tokenizer.json'))
        self.tokenizer.no_truncation()
        self.tokenizer.no_padding()
        options = ort.SessionOptions()
        options.intra_op_num_threads = threads
        options.inter_op_num_threads = 1
        self.session = ort.InferenceSession(str(directory / 'model.onnx'), options,
                                           providers=['CPUExecutionProvider'])
        self.inputs = {x.name for x in self.session.get_inputs()}
        vocab = self.tokenizer.get_vocab()
        self.pad = vocab.get('[PAD]', vocab.get('<pad>'))
        self.cls = vocab.get('[CLS]', vocab.get('<s>'))
        self.sep = vocab.get('[SEP]', vocab.get('</s>'))
        if any(x is None for x in (self.pad, self.cls, self.sep)):
            raise ValueError('Unsupported tokenizer special tokens')

    def ids(self, text):
        return self.tokenizer.encode(text, add_special_tokens=False).ids

    def encode(self, items, batch_size=8):
        if not items:
            raise ValueError('No inputs')
        result = []
        started = time.perf_counter()
        for start in range(0, len(items), batch_size):
            batch = items[start:start + batch_size]
            if any(len(x) > 510 for x in batch):
                raise ValueError('Token budget exceeded (silent truncation forbidden)')
            width = max(map(len, batch)) + 2
            ids = np.full((len(batch), width), self.pad, dtype=np.int64)
            mask = np.zeros_like(ids)
            for row, tokens in enumerate(batch):
                seq = [self.cls, *tokens, self.sep]
                ids[row, :len(seq)] = seq
                mask[row, :len(seq)] = 1
            args = {'input_ids': ids, 'attention_mask': mask}
            if 'token_type_ids' in self.inputs:
                args['token_type_ids'] = np.zeros_like(ids)
            hidden = self.session.run(None, args)[0]
            pooled = (hidden * mask[..., None]).sum(axis=1) / mask.sum(axis=1)[:, None]
            norm = np.linalg.norm(pooled, axis=1, keepdims=True)
            if not np.all(np.isfinite(pooled)) or np.any(norm == 0):
                raise ValueError('Invalid model output')
            result.append((pooled / norm).astype(np.float32))
            if start % 128 == 0:
                print(f'encoded {min(start + batch_size, len(items))}/{len(items)}', flush=True)
        return np.concatenate(result), time.perf_counter() - started


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--corpus', required=True)
    p.add_argument('--cases', required=True)
    p.add_argument('--baseline', required=True)
    p.add_argument('--model-dir', required=True)
    p.add_argument('--model-name', choices=['gte', 'e5'], required=True)
    p.add_argument('--output', required=True)
    p.add_argument('--fts', help='Private case_id/ids array of PostgreSQL text results')
    p.add_argument('--threads', type=int, default=4)
    args = p.parse_args()
    repository = Path(__file__).resolve().parents[2]
    for filename in (args.corpus,args.cases,args.baseline,args.output,*([args.fts] if args.fts else [])):
        if Path(filename).resolve().is_relative_to(repository):
            raise ValueError('Private inputs and outputs must be outside the repository')
    corpus = json.loads(Path(args.corpus).read_text())
    cases = json.loads(Path(args.cases).read_text())
    baseline = json.loads(Path(args.baseline).read_text())
    ids = [m['id'] for m in corpus]
    if len(ids) != len(set(ids)) or not all(m['lifecycle_status'] == 'active' for m in corpus):
        raise ValueError('Corpus requires unique active memories')
    if len({c['case_id'] for c in cases}) != len(cases):
        raise ValueError('Duplicate case ID')
    if any(not set(c['relevant_ids']) <= set(ids) for c in cases):
        raise ValueError('Target missing from snapshot')
    if len(baseline) != len(cases) or any(x.get('error') for x in baseline):
        raise ValueError('Incomplete or failed live baseline')
    baseline_map = {r['case_id']: r['ids'] for r in baseline}
    if set(baseline_map) != {c['case_id'] for c in cases}:
        raise ValueError('Baseline/case mismatch')
    model_spec = json.loads(Path(__file__).with_name('models.json').read_text())[args.model_name]
    artifact_hashes = {name:hashlib.sha256((Path(args.model_dir)/name).read_bytes()).hexdigest()
                       for name in ['model.onnx','tokenizer.json']}
    if artifact_hashes != model_spec['sha256']:
        raise ValueError('Model artifact does not match the pinned evaluation profile')
    model = Encoder(args.model_dir, args.threads)
    # SentencePiece tokenizes a trailing space as a standalone token. Encoding
    # 'query: ' separately would insert an extra token and differ from upstream.
    doc_prefix = model.ids('passage:') if args.model_name == 'e5' else []
    query_prefix_text = 'query: ' if args.model_name == 'e5' else ''
    texts = ['\n\n'.join(m.get(k) or '' for k in ('title', 'summary', 'content', 'place_text')) for m in corpus]
    tokenized = [model.ids(t) for t in texts]
    query_tokens = [model.ids(query_prefix_text + c['query']) for c in cases]
    if args.model_name == 'e5':
        for tokens,text in zip(tokenized,texts):
            if doc_prefix + tokens != model.ids('passage: ' + text):
                raise ValueError('Passage prefix tokenization differs from upstream')
    queries, query_seconds = model.encode(query_tokens)
    whole_inputs = [doc_prefix + tokens[:510 - len(doc_prefix)] for tokens in tokenized]
    whole, whole_seconds = model.encode(whole_inputs)
    chunk_inputs, owners = [], []
    for parent, tokens in enumerate(tokenized):
        for start, end in windows(len(tokens)):
            chunk_inputs.append(doc_prefix + tokens[start:end])
            owners.append(parent)
    chunks, chunk_seconds = model.encode(chunk_inputs)
    # Private expensive checkpoint, so later ranking experiments need not rerun
    # inference. Never load an untrusted pickle; this is arrays-only NPZ.
    cache = Path(args.output).with_suffix('.npz')
    cache.parent.mkdir(parents=True,exist_ok=True)
    np.savez_compressed(cache,queries=queries,whole=whole,chunks=chunks,owners=owners)
    cache.chmod(0o600)
    score_sets = {'whole': queries @ whole.T,
                  'chunks': aggregate_chunks(queries @ chunks.T, owners, len(corpus))}
    out = {'model': args.model_name, 'corpus_count': len(corpus), 'cases_count': len(cases),
           'chunk_count': len(chunks), 'truncated_whole_count': sum(len(t) > 510 - len(doc_prefix) for t in tokenized),
           'seconds': {'queries': query_seconds, 'whole': whole_seconds, 'chunks': chunk_seconds},
           'input_sha256': {k: hashlib.sha256(Path(v).read_bytes()).hexdigest() for k,v in
                            [('corpus',args.corpus),('cases',args.cases),('baseline',args.baseline)]},
           'artifact_sha256': artifact_hashes,
           'baseline': metrics(cases, baseline_map), 'variants': {}}
    for variant, scores in score_sets.items():
        rankings = {c['case_id']: [ids[i] for i in np.argsort(-row, kind='stable')[:6]]
                    for c,row in zip(cases,scores)}
        out['variants'][variant] = {'metrics': metrics(cases, rankings),
            'by_category': {cat: metrics([c for c in cases if c['category'] == cat], rankings)
                            for cat in sorted({c['category'] for c in cases})},
            'rankings': rankings}
        if args.fts:
            text_ranks = {r['case_id']:r['ids'] for r in json.loads(Path(args.fts).read_text())}
            if set(text_ranks) != {c['case_id'] for c in cases}:
                raise ValueError('FTS/cases mismatch')
            fused = {}
            for case,row in zip(cases,scores):
                semantic = [ids[i] for i in np.argsort(-row,kind='stable')[:18]]
                fts = text_ranks[case['case_id']][:18]
                candidates = set(semantic) | set(fts)
                by_id = {m['id']:m for m in corpus}
                def score(mid):
                    m=by_id[mid]
                    return ((.45/(2+semantic.index(mid)) if mid in semantic else 0)
                            +(.30/(2+fts.index(mid)) if mid in fts else 0)
                            +m['importance']/100*.10+m['confidence']/100*.05
                            +m['emotional_intensity']/100*.05
                            +(.05 if case['query'].strip().lower() in m['title'].lower() else 0))
                fused[case['case_id']] = sorted(candidates,key=lambda mid:(-score(mid),mid))[:6]
            out['variants'][variant+'_hybrid'] = {
                'metrics':metrics(cases,fused),
                'by_category':{cat:metrics([c for c in cases if c['category']==cat],fused)
                               for cat in sorted({c['category'] for c in cases})},
                'rankings':fused}
    output = Path(args.output)
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(out,ensure_ascii=False,indent=2))
    output.chmod(0o600)
    print(json.dumps({k:v['metrics'] for k,v in out['variants'].items()}), flush=True)


if __name__ == '__main__':
    main()

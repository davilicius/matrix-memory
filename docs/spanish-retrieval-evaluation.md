# Spanish retrieval: initial private evaluation

Evaluation date: 2026-11-12 (America/Mexico_City). Production remains MCP 1.6.0.
No schema, embedding worker, index, permissions or deployment configuration was changed.

## Outcome

A multilingual model with passages is promising, but is **not approved for a
production cutover by this experiment**. It improves known-target retrieval
overall while losing three targets that the current system retrieves, including
one decision. The pre-result screening criterion permits no decision losses.

| Retrieval pipeline | Target at rank 1 | Target within 6 | MRR@6 |
| --- | ---: | ---: | ---: |
| Current live MCP hybrid | 16/48 | 31/48 | 0.4740 |
| Local GTE, first 512 tokens, semantic only | 16/48 | 29/48 | 0.4427 |
| Local GTE, passages, semantic only | 16/48 | 27/48 | 0.4191 |
| Multilingual E5, first 512 tokens, semantic only | 21/48 | 35/48 | 0.5326 |
| Multilingual E5, first 512 tokens, existing hybrid formula | 22/48 | 36/48 | 0.5632 |
| Multilingual E5, passages, semantic only | 28/48 | 41/48 | 0.6927 |
| Multilingual E5, passages, existing hybrid formula | 28/48 | 40/48 | 0.6892 |

E5 passages versus live baseline: 13 newly recovered targets and 3 lost targets,
a net gain of 10/48 (20.8 percentage points). With the existing hybrid formula,
there are 12 gains and 3 losses. The lost targets span technical, decision and
long-note questions. Splitting GTE text alone reduced its semantic result from
29 to 27: chunking is not automatically an improvement.

The topic-cluster bootstrap interval for E5 semantic passages minus live
baseline is +6.25 to +35.42 percentage points (10,000 resamples, seed 20261112,
24 whole topics). This measures sampling variability inside this selected set,
not generalization to future questions, annotation uncertainty or model choice.

## Method and limits

- Snapshot: 727 active memories under one owner. Of all 739 stored memories,
  33 have content longer than 8,000 characters. E5 tokenization finds 325 active
  inputs exceeding its single-window budget; character length is not token length.
- 48 reconstructed questions, two paraphrases for each of 24 verified target
  memories: 10 personal, 12 decision, 10 technical and 16 long-note questions.
  These are not 48 verbatim user messages and not independent observations.
- Labels identify one known relevant memory per question. Other memories can
  also answer it. The metric is known-target hit rate, **not** general accuracy,
  exhaustive recall or factual answer quality. Two formulations are especially
  ambiguous (time/age and team/equipment); preserve that limitation.
- All 48 live MCP calls succeeded in hybrid mode with `limit=6,hops=0`. They
  update the normal retrieval history/counters, but not memory content.
- Only 15 questions had Spanish full-text matches. The existing conjunctive
  query often misses conversational formulations; this needs separate study.
- Local GTE uses the pinned upstream FP32 ONNX model; live Supabase inference
  is not bitwise validated against it. Compare local GTE/E5 to inspect model
  effects, and compare whole/passages within each model for the window effect.
- E5 uses the pinned upstream int8 ONNX artifact, 384 dimensions, upstream
  query/passage prefixes, attention-mask mean pooling and L2 normalization.
  Final run validates prefix tokenization on every corpus entry. A preliminary
  run with an extra standalone whitespace token was discarded, not reported.
- Passages contain 384 content tokens with 64-token overlap; the final tail is
  preserved. E5 yields 1,879 passages, GTE 2,330. Maximum passage similarity is
  collapsed to unique parent memories before the six-result cutoff. Maximum
  scoring can favor longer documents and should be checked on held-out data.
- The optional hybrid variant uses the same text candidates and existing rank
  weights/metadata boosts. Local tie-breaking is deterministic by ID; production
  SQL does not guarantee tie order. Source snapshots may evolve independently.
- The public repository contains only generic code, synthetic tests, model
  pins and aggregate results. Corpus, questions, target IDs, rankings, vectors
  and source hashes stay private. No private text was sent to a model API.

## Next experiment and rollout prerequisites

1. Review alternative relevant results and the three losses, especially the
   decision case. Freeze any proposed lexical/fusion adjustment before scoring
   a new topic-disjoint holdout; do not keep tuning against these 48 questions.
2. Add negative/unanswerable queries, stale/partially replaced decisions,
   identifiers and misspellings. Score currentness separately from topicality.
3. Validate a serving runtime for the multilingual model, query p95 latency,
   memory/cold-start limits, failures and operating cost. The local experiment
   is not a deployed endpoint and batch durations are not production latency.
4. Keep the old index intact. Store a new versioned profile with model revision,
   tokenizer, pooling, normalization, chunk parameters and source-content hash.
   Same vector dimension does not make two models compatible. Query/document
   embeddings and caches must match the same profile.
5. Enforce owner/app permissions and active lifecycle during retrieval; discard
   stale chunks after source changes. Check permissions, retry idempotency,
   bounded backfill, query fallback and immediate profile rollback before any
   manual promotion. Keep automatic deployment disabled.

## Reproduction

See `tools/retrieval_eval/README.md` and the pinned `models.json`. Five synthetic
tests cover token-window coverage/tail, invalid overlap, parent aggregation,
missing/rank-six targets and duplicate result rejection. No benchmark-derived
production migration is included in this change.

Primary references:

- https://supabase.com/docs/guides/functions/ai-models
- https://supabase.com/docs/guides/ai/semantic-search
- https://huggingface.co/intfloat/multilingual-e5-small
- https://huggingface.co/Supabase/gte-small

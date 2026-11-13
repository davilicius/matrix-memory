# Private Spanish retrieval evaluation

This is an offline experiment, not a production retriever. It never writes to
Supabase or changes MCP, access grants, lifecycle states, or embedding queues.
Download model bytes separately from the revisions in `models.json`; name each
local pair `model.onnx` and `tokenizer.json`. No private text goes to a model API.

Create a Python 3.11+ virtual environment and install `requirements.txt` there.
Run `python tests/retrieval_eval_test.py` for synthetic evaluation tests.

The three input JSON arrays must live outside this repository:

- Corpus: `id`, `title`, `summary`, `content`, `place_text`, `lifecycle_status`;
  snapshot active memories under one owner, with unique IDs. Preserve snapshot
  timestamp, ownership filter and hashes separately in private evidence.
- Cases: unique `case_id`, `topic_id`, `category`, `query`, `relevant_ids`.
  State whether questions are verbatim, reconstructed or synthetic. A selected
  known target is not an exhaustive relevance judgment for all other memories.
- Baseline: `case_id`, `ids`, `mode`, `elapsed_ms`, `error`, from real MCP searches
  with six hits and zero graph hops. Preserve failed cases, never silently drop
  them. The harness rejects missing cases, failures and targets absent from the
  snapshot. Live calls still update ordinary retrieval history and recall counts.

Example with private paths:

```sh
python tools/retrieval_eval/evaluate.py \
  --corpus /private/evaluation/corpus.json \
  --cases /private/evaluation/cases.json \
  --baseline /private/evaluation/baseline.json \
  --fts /private/evaluation/fts.json \
  --model-dir /private/models/e5 --model-name e5 \
  --output /private/evaluation/e5-results.json
```

The harness reproduces the worker's title/summary/content/place concatenation.
It compares first-512-token inference with windows of 384 content tokens and
64-token overlap, average pooling, L2 normalization and maximum cosine score
per parent memory. Query and passage prefixes are applied for E5, even in Spanish.
Passage hits are collapsed before ranking, so one long memory cannot occupy
multiple result slots. It never compares vectors from different models.

Results include known-target Hit@1/3/6 and MRR@6, category breakdowns, model
artifact hashes, input hashes and batch inference durations. These durations are
not production query latency or a throughput SLA. CPU runs may contend with
other processes. The live hybrid baseline and offline semantic-only variants
have different ranking pipelines; the contrast is exploratory, not proof that
the model alone caused the entire difference. Whole-versus-chunk comparisons
also change the number of content tokens available to each model.

Do not publish the corpus, cases, rankings, embeddings or query logs. Public
documentation may contain aggregate metrics and anonymous failure categories.
For correlated paraphrases, group any split or resampling by `topic_id`.

Before production cutover: evaluate a fresh held-out set, judge alternative
relevant results, include unanswerable queries and stale decisions, compare
under the same hybrid fusion, test owner/access isolation and source-hash
invalidation, measure latency/error/cost in the proposed runtime, keep a separate
versioned index, and verify an immediate fallback to the old profile. A good
score here does not provide a hosting endpoint or authorize deleting an index.

The optional FTS input contains `case_id` and up to 18 ordered memory `ids`,
computed with the production Spanish `websearch_to_tsquery` and `ts_rank_cd`.
It adds whole/chunk hybrid variants using the existing 0.30/0.45 reciprocal-rank
weights and the same importance/confidence/emotion/title boosts. Ties are resolved
by ID locally; production tie order is not guaranteed. Private NPZ files preserve
query/document vectors for further experiments without repeating inference.

## Offline shadow validation

`shadow.py` contains the fixed fusion, profile/source fingerprints and freshness
checks used in the later Spanish experiment. It is a library for local replay,
not a network service. Run `python tests/retrieval_shadow_test.py` from the repo
root. See `docs/spanish-priority-validation.md` for measured results, limitations
and the remaining deployment gates. Keep all private inputs and outputs outside
the repository, including manifests and model vectors.

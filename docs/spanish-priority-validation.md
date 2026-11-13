# Spanish priority: shadow validation

Experiment date: 2026-11-12, America/Mexico_City. This extends the initial
[evaluation](spanish-retrieval-evaluation.md). Production stays on MCP 1.6.0.
English evaluation is deliberately deferred until the owner participates.

## What was implemented

`tools/retrieval_eval/shadow.py` provides an **offline** core for fixed RRF60
fusion of six authorized baseline candidates and eighteen multilingual
candidates, returning six unique memories. The weights were frozen before
scoring. Spanish priority means accepting changes against Spanish evidence,
not arbitrarily increasing scores for Spanish-looking text.

The core fingerprints model/tokenizer revisions, pooling, normalization and
window settings; rejects incompatible or invalid vectors; collapses passage
scores by source; and filters changed, non-active, deleted or foreign sources
before the candidate cutoff. Source text hashes are separate from timestamps,
so a relationship-only metadata change does not force re-embedding. Fresh
lifecycle metadata is still required on every replay.

An already successful baseline is mandatory. A reported experimental failure
returns the permitted baseline in its original order. Eight synthetic tests
cover these invariants; the five initial evaluation tests remain in CI.

This is not an HTTP service, authentication boundary, automatic rewriter,
answer-sufficiency classifier, hard timeout implementation or replacement
resolver. The caller must obtain fresh owner-scoped metadata and authorization
from the existing service. Partial replacements and source evidence still
require review; the offline manifest is not an exhaustive validity check.

## New Spanish replay

The private snapshot was refreshed from 727 to 734 active sources. All 727
unchanged source embeddings were reused after checking source and model
provenance; seven new sources required fifteen new passages. The resulting
experimental index has 1,894 passages and remains separate from production.

Eight actual user utterances/excerpts were frozen before retrieval, preserving
misspellings. Four additional short utterances require conversation context
and are not standalone questions. Topics overlap earlier experiments. A later
diagnostic arm prepared focused queries from the utterance and visible context;
this is **not** an independent holdout or an automatic query-rewriter test.

Post-ranking source review identified seven answerable intents and one request
whose later event was not supported in the consulted snapshot. Annotation is
non-exhaustive and was not blind or preregistered. For two current-state intents,
an older topical source was insufficient even if it described the same project.

| Evidence within first six | Live baseline | E5 passages | Fixed combination |
| --- | ---: | ---: | ---: |
| Raw natural utterances, seven known intents | 5/7 | 4/7 | 5/7 |
| Focused diagnostic queries, same seven intents | 5/7 | 5/7 | 6/7 |

The combination preserved the baseline's five supported raw-query cases. E5
alone missed a personal recipe; focused preparation restored it to first place.
A latest project checkpoint remained outside the first six even after focused
query preparation. `resolve_current` alone did not retrieve it because its
coverage is bounded. Reviewing recent records and fetching the relevant source
recovered that checkpoint and the latest state of another project. Filtering
recent records to type `project` would have missed a relevant `episode`.

This demonstrates a workflow gap, not an automatic backend fix. Short ambiguous
requests need existing conversation context. A result about an earlier payment
destination does not substantiate a later change. No answer-accuracy percentage
or global absence claim follows from these counts.

Earlier follow-up evidence also corrected the interpretation of one initial
lost target: an alternative memory did contain the decision. A fixed combination
recovered 21/22 known references on a later reconstructed set and 12/12 on a
deliberate temporal stress set. Those tests are not representative accuracy.

## Runtime measurements

Local CPU, four inference threads, pinned upstream int8 ONNX model:

| Measurement | Observed |
| --- | ---: |
| Model file | 112.9 MiB |
| Model load in evaluation process | 1.67 s |
| Warm single-query replay median, 36 samples | 8.0 ms |
| Warm single-query replay p95 | 22.2 ms |
| Isolated model load / one-query peak RSS, no corpus | 538.4 MiB |
| Evaluation-process peak RSS including data and arrays | 633.1 MiB |
| Live MCP round-trip median / p95, twelve calls | 2.27 / 2.72 s |

The MCP and local measurements cover different work and are **not** a speedup
ratio. MCP calls ran in groups of three; local requests were serial and the
filesystem cache was warm. The first measured query followed document encoding,
so it is not a cold inference measurement. Single versus padded-batch encoding
of one reference query had cosine 0.995825; repeating the original eight-query
batch reproduced its stored embeddings to floating-point tolerance. Batch mode
must be recorded in further quality comparisons.

The measured Python/ONNX process exceeds the documented hosted Edge Function
memory limit of 256 MB. It cannot simply be placed inside the existing Edge
function. This does not prove another runtime cannot fit; it requires separate
validation. No new server, paid endpoint or recurring cost was provisioned.

Primary runtime limit reference:
https://supabase.com/docs/guides/functions/limits

## Remaining gates

1. Integrate and test the current-state workflow end to end: focused contextual
   search, bounded recent-source supplementation across memory types, source
   dates, replacements and evidence sufficiency. Preserve historical intent.
2. Choose and validate a serving runtime with adequate memory, owner/application
   authorization, bounded inference failure and source invalidation. Keep the
   existing index and immediately usable baseline fallback.
3. Measure concurrent requests, deployed latency and actual resource costs.
   Do not infer a monthly bill from local model execution time.
4. Invite the owner to ask fresh English questions only after the Spanish
   workflow is ready for that pilot. No English test has been performed here.

All private questions, source IDs, source text, rankings and vectors remain
outside the public repository. Only generic code, synthetic tests and aggregate
observations are public. No production model, index, worker, schema or automatic
deployment changed.

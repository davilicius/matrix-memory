# Spanish spelling evidence — MCP 1.8.0

`search` and `resolve_current` now include `spelling_candidates` alongside the existing results. These candidates carry `spelling_match` with the input term, matched word and edit count. The original query, ranked hits, history ID, retrieval mode and memory text remain unchanged. Consumers must review the evidence and source, not treat an approximate match as an authoritative correction.

The existing PostgreSQL `pg_trgm` extension supplies a trigram shortlist. TypeScript then checks bounded edit distance, including adjacent transposition. No new model, Python runtime, dictionary table, schema migration, persistent index or multilingual feature is introduced.

## Deliberate limits

- Spanish lowercase normalization folds acute accents and ü but preserves ñ.
- Plain queries up to 160 characters, with one to four meaningful words of 5–32 letters. Common Spanish question/function words are omitted only in the supplemental match.
- Queries containing numbers, codes, URLs, email, quotes, operators/negation, unsupported punctuation or uppercase identifier runs skip the supplement entirely. The normal search still receives the original query.
- Match against titles and the first 1,000 summary characters of at most the 2,000 newest active, currently valid owner records. The normal search retains its full-content behavior. No body-only spelling guarantee.
- PostgreSQL evaluates whole-word trigram similarity with a fixed 0.45 minimum; at most 64 documents and three words per input term pass to the edit check. All meaningful terms must match in the same memory. Exactly one term may differ: at most one edit for 5–8 letters, two for longer words, and at most 20% of the longer word's length.
- Up to six supplemental candidates, bounded further by the requested result limit. Limits and truncation are returned in `spelling_context`; no exhaustive-recall claim.
- Approximate matches can be different valid words. We preserve exact/baseline results separately and never silently rewrite a query, account, IP, record or identifier.

## Access, failure and observability

The lookup runs inside the same authenticated owner/RLS transaction as other backend reads and honors `memory_types` and occurrence-date filters before selecting candidates. Its SQL statement timeout is one second. A successful baseline is preserved if the supplement fails; `spelling_context.status` becomes `unavailable`. Baseline failures still propagate.

Selected candidates go through the existing source, date, replacement and conflict enrichment. A dedicated retrieval-history entry records the original query and matched IDs; supplemental recalls update only the normal recall counters/timestamp. Operational logs contain an allowlisted spelling status and bounded count, never queries, corrections or memory content. `result_count` retains its existing meaning; `spelling_result_count` is separate.

## Validation and deployment

Synthetic unit/HTTP tests cover missing/extra letters, transposition distance, accent handling, protected input, bounded ranking, baseline preservation, failure and privacy. The SQL permission CI runs the exact application SELECT against disposable PostgreSQL records to exercise owner isolation, lifecycle/validity and date/type filters in both strict and legacy ACL modes.

Private read-only probes recovered expected source records for several Spanish misspellings, including a multiword query. A negative control produced no spelling candidate. The measured PostgreSQL execution for one single-word probe was about 95 ms with cached pages; it is neither end-to-end latency nor a general performance/RAM benchmark. A broader full-content prototype exceeded the one-second guard and was not released.

Deploy the complete function bundle, preserving the existing private owner binding, server name, OAuth and application authorization. Verify live MCP results and compare baseline IDs before/after. Rollback is redeployment of the previous complete bundle; no database migration reversal is needed. The multilingual experiment remains deferred.

# MCP 1.2.0 — temporal evidence and save quality

Adds `resolve_current(query, limit=6)`, built on the existing tracked semantic search and labelled textual fallback. It follows explicit successor links (maximum eight hops), preserves history, separates partial/unreviewed replacements, and returns contradiction references. Results are bounded evidence candidates, not a complete project inventory or a guarantee of external currentness. Unknown event dates remain unknown; creation dates are labelled separately.

Search, fetch and related responses now expose lifecycle, created/updated/event dates, validity interval, source and scoped replacement references. Existing six tool input contracts remain compatible. New tool discovery may require refreshing the connector.

Edge metadata `supersession_scope` accepts reviewed `full` or `partial`; missing scope is unreviewed and does not automatically invalidate a memory. Full replacements are maintained using owner-scoped transactions with an optimistic updated_at check. Old content is preserved. Partial replacements retain the old record and its unaffected evidence. No generic update/delete tool is exposed.

Remember returns nonblocking quality_warnings for missing summaries, unknown event dates, absent entities, long notes and very high importance. These warnings do not invent facts, rewrite text or break retry idempotency. Authors should keep notes atomic, include known dates, identify project/topic, and reserve 90–100 importance for critical evidence.

Validation: Deno type check; seven tests covering existing HTTP/OAuth boundaries, temporal classification, partial replacement, history, conflicts, deduplication and non-mutating quality warnings. The enrichment SQL was checked under the owner's authenticated role. A reviewed data correction was rehearsed in a rolled-back transaction before committing. Private reviewed records and identifiers are deliberately not in this public repository.

Deployment remains manual. Preserve the existing owner's binding and OAuth verifier. The reusable entrypoint requires MATRIX_OWNER_ID; a private deployment may bind the previously configured owner in its entrypoint without publishing that identity. The deployed sources are checked against this release, allowing only that explicit binding and the existing server display name. Preserve the previous edge-function bundle for rollback; data review metadata records prior lifecycle and updated_at for controlled reversal.

Pending separately: dedicated transactional replacement tool, complete project inventory/as-of queries, multilingual benchmark/index, operation-wide telemetry and application/resource-bound OAuth permissions. This release does not claim to implement them.

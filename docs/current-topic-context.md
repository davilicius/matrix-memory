# Recent topic context in resolve_current (MCP 1.7.0)

Broad project-status questions can omit recent checkpoints when only the ranked search hits are considered. `resolve_current` retains the existing search and adds `recent_topic_candidates`, annotated with sources, dates, replacements and contradictions through the existing temporal enrichment.

The optional `topic` parameter accepts 2–160 characters. Without it, topics come from registered entity names, aliases or uppercase acronyms in registered project names, matched without case or accent sensitivity. Project matches take precedence. More than three distinct topics require refinement; an unnamed query does not invent a project.

The owner-scoped authenticated query examines at most 500 entities and 200 active, currently valid memories across all memory types, ordered by event date with creation date as fallback. Matching uses linked entity IDs or whole phrases in titles. It returns at most the requested limit (default six). Coverage and truncation flags describe these bounds. Recent evidence is supplementary: creation date is not proof of current truth, conflicting sources still require review, and this is not a complete project inventory.

The baseline must succeed. A failure in supplemental retrieval or enrichment preserves its result and returns `recent_context.status = unavailable`, without leaking database exceptions. The supplement uses the same authenticated owner/RLS boundary and existing retrieval-history table; no schema migration is required. It does not change search ranking, embeddings, application roles, or write operations.

Validation: 42 synthetic MCP, authorization, temporal, protocol, telemetry and topic tests; TypeScript checks; production migration-history check. A read-only authenticated replay against the private corpus recovered the recent project checkpoint and a second project's episode and decision through registered topics. Private queries, source records and owner identity are excluded from this repository. This small diagnostic is not an accuracy benchmark.

Deployment remains manual. Preserve the existing deployment's owner configuration and OAuth/application authorization, upload the new `current-topic.ts` dependency together with the function, and verify `status` and real `resolve_current` calls after deployment. Rollback uses the complete previous function bundle.

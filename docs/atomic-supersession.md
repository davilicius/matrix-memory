# Atomic memory replacement — MCP 1.3.0

`supersede` creates the new memory, its source/entities, a scoped `supersedes` edge and the old memory's lifecycle change in one database transaction. A failure rolls back all these effects, including embedding jobs and version rows in that transaction. It never rewrites old title, content, summary or validity dates.

Fetch and review the old memory first. Copy `memory.updated_at` exactly, including microseconds. Supply:

```json
{
  "target_id": "11111111-1111-4111-8111-111111111111",
  "expected_updated_at": "2026-11-12T18:00:00.123456+00:00",
  "scope": "partial",
  "reason": "Only the delivery date changes; the agreed scope remains valid.",
  "replacement": {
    "event_key": "example:decision:delivery-date:2026-11-12",
    "memory_type": "decision",
    "title": "Revised delivery date",
    "content": "The newly agreed date and its supporting evidence.",
    "summary": "Delivery date revised.",
    "source": {"type": "conversation", "title": "Agreement to revise the date"},
    "entities": [{"kind": "project", "name": "Example"}]
  }
}
```

Use `full` only when the entire old memory is replaced. It becomes `superseded`. `partial` leaves the old memory active and exposes the changed scope through existing temporal evidence. Both preserve the old content and store prior state/hash on the edge. A monotonic timestamp trigger refreshes the old memory's conflict token for partial changes too, even within one transaction. The existing version trigger records full lifecycle changes; partial replacements retain their audit evidence on the edge.

One call replaces one target. Several independently reviewable facts require separate operations. The replacement may have other ordinary relationships, but additional `supersedes` relations and internal receipt metadata are rejected. Future/expired replacement validity is rejected: scheduled or as-of transitions are outside this API.

## Retry and concurrency

- A new `replacement.event_key` identifies the operation. Retry the identical payload after uncertain network failure. The canonical JSON request hash is checked under the same advisory lock used by `matrix_remember`.
- A matching retry returns `existing`, `same_operation: true`, the original memory and relation IDs, with no repeated effects. This confirms the original operation, not that its resulting decision remains current forever.
- Reusing a key for different fields, scope, reason or target returns `P4091`. An ordinary `remember` key cannot be retroactively converted to a replacement.
- A changed timestamp, inactive target or unresolved full/unreviewed incoming replacement returns `P4090`. Re-fetch and review before deciding whether any new operation is appropriate. Never generate a different key simply to bypass a conflict.
- Target row locks serialize competing replacements. OAuth, owner RLS, statement timeout and lock timeout remain in force. Database details and memory content are not exposed in error messages.

The SQL RPC is `public.matrix_supersede(jsonb)`, security invoker, requiring `auth.uid()` and executable by `authenticated` only. Its input is the same as above; there is no owner override or privileged server shortcut. Existing `remember` remains compatible: legacy relationship evidence does not perform lifecycle transitions. New reviewed substitutions should use this tool.

## Validation and deployment

Tests cover full/partial transitions, content preservation, exact retries, conflicts, owner isolation, missing identity, forbidden overrides, late-failure rollback and simultaneous sessions. `tests/run-permissions.sh` runs the new suite on disposable Supabase databases with strict and legacy default grants after the preexisting regressions. MCP tests exercise schema, routing, secret rejection and safe errors. Local lightweight PostgreSQL tests supplement real Supabase CI.

Deployment is manual: apply the additive `atomic_memory_supersession` migration, then deploy the MCP bundle. Preserve the private owner binding and OAuth configuration. Verify deployed files, status, read paths and a rollback-only SQL exercise. Keep the migration filename aligned to the applied version. Automatic GitHub/Supabase integration stays disabled.

For code rollback restore the previous Edge Function bundle; old tools do not depend on the added RPC. The RPC/trigger can remain dormant. Do not automatically undo completed replacements: their history and later decisions need review. No historical bulk correction is part of this deployment.

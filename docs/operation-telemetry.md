# Operation telemetry — MCP 1.4.0

Every completed request reaching the Matrix handler emits a structured JSON
`matrix_operation` event to the Edge Function console. This includes successful
tools, empty retrieval, retries, conflicts, input rejection and HTTP guards.
SDK validation errors with HTTP 200 and `isError` are failures, not successes.
For supported JSON-RPC batches, each item has its own event with `batch_index`;
all share the server-generated request ID. A rejected batch has one envelope event.

## Fields and privacy

| Field | Meaning |
|---|---|
| `schema_version`, `server_version` | Event format (1) and MCP release |
| `request_id` | Random server-generated UUID, also `X-Matrix-Request-Id` response header |
| `timestamp` | Request arrival time in UTC |
| `method`, `operation` | Allowlisted MCP method and tool name; unknown names are normalized |
| `duration_ms` | Handler wall time through cleanup; includes authentication and SDK work |
| `tool_duration_ms` | Tool callback wall time, including database and semantic wait, when invoked |
| `http_status`, `rpc_code` | HTTP status and allowlisted JSON-RPC error code |
| `outcome` | `success`, `empty`, `existing`, `conflict`, `error`, `rejected`, or `accepted` notification |
| `error_code` | Fixed boundary classification or explicitly allowlisted database code |
| `result_count`, `retrieval_mode` | Retrieval count and hybrid/text fallback, when applicable |

No prompts, queries, memory content, titles, event keys, memory IDs, owner IDs,
client-supplied request IDs, OAuth claims, tokens, URLs, headers, exception messages,
SQL text or database error details are copied into these events. Unknown exceptions
become `BACKEND_ERROR` or `REQUEST_FAILED`. Existing backend retrieval-history
behavior is unchanged; this privacy statement concerns the new telemetry only.

`AUTH_INVALID` means the request was not authenticated. `AUTH_UNAVAILABLE` means
the Auth request failed, timed out or returned 429/5xx; both retain the existing
401 response and fail closed. `P4090`/`P4091` identify replacement conflicts;
`57014` is query cancellation, `55P03` lock unavailability. An existing event key
with different content is a conflict even though the tool returns a structured
result. `result_count` for resolve_current counts current, review and historical
candidates; empty current candidates alone does not mean an empty retrieval.

## Reading the events

Use the Supabase dashboard, Edge Functions → matrix-mcp → Logs, and filter
`matrix_operation`. With the Supabase unified-log query tool, inspect recent events:

```sql
select timestamp, event_message
from logs
where source = 'function_logs'
  and event_message like '%"event":"matrix_operation"%'
order by timestamp desc
limit 100
```

Supply the desired time window to the log tool. Group parsed events by operation,
outcome and error_code; compare duration percentiles per operation. Do not equate
HTTP 200 with tool success. Use `(request_id, batch_index)` to correlate batch
items; batch duration is shared request duration and must not be summed per item.

## Limits and rollout

Console delivery is best effort and subject to the project's log retention,
ingestion and rate limits. There is no new database table or indefinite archive.
Gateway rejections before the handler, runtime termination and startup/configuration
failures remain in platform logs; they cannot emit a handler completion event.
Logging failure never changes the response or rolls back/duplicates a completed
write. Historical HTTP 400 events cannot be retroactively classified.

Deploy manually after CI using the existing owner configuration, server name,
database connection and OAuth verification. No new secret, grant, migration or
automatic deployment is required. Verify status returns 1.4.0, perform read-only
search/fetch checks and controlled invalid input, and inspect the corresponding
events. To roll back, redeploy the previously verified function bundle; database
and MCP tool schemas are unchanged.

Validation: synthetic tests cover successes, empty/fallback retrieval, writes and
retries, conflicts, database error classification, SDK validation, unknown names,
malformed JSON, HTTP guards, body limits, rate limits, secret rejection,
concurrency, batches, Auth failures and a throwing log sink. No credentials or
production data are required for these tests.

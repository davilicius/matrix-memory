# MCP protocol compatibility — application 1.5.0

Application versions (1.5.0), SDK package versions (2.4.0), protocol revisions
(2026-07-28) and the database schema (1.2) identify different components.

The 1.4.1 diagnostic release confirmed an initial `server/discover` request with
protocol 2026-07-28 rejected by the previous 1.32.2 SDK, followed by a successful
2025-11-25 initialization and tool call. This explains the observed extra request;
it does not retroactively explain every historical HTTP 400.

## Implementation

- Replace the v1 SDK with the official `@modelcontextprotocol/server` 2.4.0,
  pinned in npm and Deno configuration.
- Use its `isLegacyRequest` classifier, not a handcrafted protocol-header rewrite.
- Keep stateless legacy JSON responses through `WebStandardStreamableHTTPServerTransport`.
- Route modern requests through `createMcpHandler` with `legacy: 'reject'`.
  The SDK provides discovery, envelope validation and method/name header checks.
- Preserve the existing OAuth, owner binding, origin, body-size and rate controls
  before either protocol route. Metadata never grants access.
- Keep the same tool definitions and SQL backend. No migration, new permission or
  automatic deployment is required. Map callback request IDs using the SDK v2 context.
- Log only a bounded date-shaped `protocol_version`, or `absent` / `invalid`,
  alongside existing safe telemetry. Unknown raw headers are never logged.

Unknown future versions and mismatched headers must still be rejected. Do not
remove version validation to make counters look clean.

## Validation and manual rollout

Tests exercise modern discovery without initialization, all eight tools, matching
tool catalogs in both eras, unchanged structured results, replays, auth and origin
rejection, owner override, private-key rejection, header/envelope mismatches and
unknown future revisions. Existing legacy, telemetry, concurrency and batch tests
remain enabled. GitHub also runs its SQL permission regressions.

After deploying the tested bundle with existing private configuration and server
name, invoke status/search/fetch/remember through the connected client. Inspect
the bounded log window: `server/discover` should succeed with 2026-07-28 and tool
calls should proceed without the former protocol-version rejection. Keep the
1.4.1 bundle available for rollback; it supports working legacy fallback and
requires no database reversal.

References:

- https://ts.sdk.modelcontextprotocol.io/v2/migration/upgrade-to-v2
- https://ts.sdk.modelcontextprotocol.io/v2/serving/legacy-clients
- https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning

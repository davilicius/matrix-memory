# Matrix contract

- Schema version: `1.1`
- Write RPC: `public.matrix_remember(jsonb)`
- Retrieval RPCs: `public.recall_memories(...)`, `public.memory_context(...)`
- Idempotency: `event_key`, unique per owner

Allowed memory types:

`episode`, `fact`, `decision`, `intention`, `project`, `reflection`,
`preference`, `procedure`, `identity`, `hypothesis`.

Allowed truth states:

`reported`, `verified`, `inferred`, `disputed`, `unknown`.

The deployment-specific project ID and owner ID belong in runtime configuration, never in this skill.

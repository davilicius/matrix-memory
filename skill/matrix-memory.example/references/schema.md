# Matrix contract

- Schema version: `1.2`
- Write RPC: `public.matrix_remember(jsonb)`
- Semantic retrieval RPC: `public.matrix_semantic_recall(jsonb)`
- Canonical retrieval RPC: `public.matrix_recall(jsonb)`
- Diagnostic primitives: `public.recall_memories(...)`, `public.memory_context(...)`
- Embedding model: `Supabase/gte-small`, 384 dimensions
- Embedding mode: asynchronous queue
- Idempotency: `event_key`, unique per owner

Required write fields:

`event_key`, `memory_type`, `title`, `content` and either `source` or `source_id`.

Allowed memory types:

`episode`, `fact`, `decision`, `intention`, `project`, `reflection`,
`preference`, `procedure`, `identity`, `hypothesis`.

Allowed truth states:

`reported`, `verified`, `inferred`, `disputed`, `unknown`.

The deployment-specific project ID, owner ID, URLs and secrets belong in runtime configuration, never in this skill.

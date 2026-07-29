---
name: matrix-memory
description: Store, retrieve, and connect long-term memories in a Matrix-compatible Supabase project.
---

# Matrix Memory

Read `references/schema.md` before the first Matrix operation in a turn.

## Store

1. Split unrelated ideas into atomic memories.
2. Never store passwords, tokens, private keys, recovery codes or complete payment-card data.
3. Choose an allowed `memory_type` and honest `truth_status`.
4. Generate a deterministic lowercase `event_key`:
   `scope:type:short-slug[:yyyy-mm-dd]`.
5. Include provenance through `source` or `source_id`.
6. Call `public.matrix_remember(jsonb)` once.
7. Treat `created` and `existing` as successful outcomes.

## Retrieve

Start with `recall_memories()` using text and a typed null embedding. Use `memory_context()` only after identifying seed IDs and only when neighboring memories improve the answer.

Always operate as the authenticated owner so RLS applies. Distinguish stored information from new inference.

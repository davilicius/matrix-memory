---
name: matrix-memory
description: Store, retrieve, and connect long-term memories in a Matrix 1.2 compatible Supabase project.
---

# Matrix Memory

Read `references/schema.md` before the first Matrix operation in a turn.

## Store

1. Split unrelated ideas into atomic memories.
2. Never store passwords, tokens, private keys, recovery codes or complete payment-card data.
3. Choose an allowed `memory_type` and an honest `truth_status`.
4. Generate a deterministic lowercase `event_key`:
   `scope:type:short-slug[:yyyy-mm-dd]`.
5. Include provenance through `source` or `source_id`.
6. Call `public.matrix_remember(jsonb)` once.
7. Treat `created` and `existing` as successful outcomes.

## Retrieve

Use `public.matrix_semantic_recall(jsonb)` for normal retrieval. If it returns `pending`, repeat the same payload after the indicated delay, up to three times.

When semantic generation is unavailable, call `public.matrix_recall(jsonb)` without `query_embedding` as a tracked text fallback.

Do not call `recall_memories()` directly for normal use because it does not record retrieval history or update recall counters.

Always operate as the authenticated owner so RLS applies. Distinguish stored information from new inference.

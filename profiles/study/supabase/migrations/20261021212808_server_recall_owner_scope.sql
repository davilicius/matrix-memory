-- Repair deployed definitions as well as clean installations. Keep the existing
-- public signatures, SECURITY INVOKER, empty search_path and RLS policies.
-- matrix_recall already validates owner_id against auth.uid(), or requires a
-- trusted server role and explicit owner_id when no user identity is present.
-- Scope ranking, graph, counters and history to that SAME resolved owner.
-- Do not synthesize JWT claims or change session settings to select an owner.

create or replace function public.recall_memories(
  p_query_text text,
  p_query_embedding extensions.vector(384),
  p_match_count integer default 12,
  p_memory_types text[] default null,
  p_occurred_after timestamptz default null,
  p_occurred_before timestamptz default null
)
returns table (
  id uuid,
  memory_type text,
  title text,
  content text,
  summary text,
  occurred_at timestamptz,
  importance smallint,
  emotional_intensity smallint,
  confidence smallint,
  truth_status text,
  source_id uuid,
  score double precision
)
language sql
stable
security invoker
set search_path = ''
as $matrix_function$
with filtered as (
  select n.*
  from public.memory_nodes n
  where n.owner_id = auth.uid()
    and n.lifecycle_status = 'active'
    and (p_memory_types is null or n.memory_type = any(p_memory_types))
    and (p_occurred_after is null or n.occurred_at >= p_occurred_after)
    and (p_occurred_before is null or n.occurred_at <= p_occurred_before)
),
full_text as (
  select
    n.id,
    row_number() over (
      order by ts_rank_cd(
        n.fts,
        websearch_to_tsquery('spanish', p_query_text)
      ) desc
    ) as rank_ix
  from filtered n
  where coalesce(trim(p_query_text), '') <> ''
    and n.fts @@ websearch_to_tsquery('spanish', p_query_text)
  limit least(greatest(p_match_count, 1), 30) * 3
),
semantic as (
  select
    n.id,
    row_number() over (order by n.embedding operator(extensions.<=>) p_query_embedding) as rank_ix
  from filtered n
  where p_query_embedding is not null
    and n.embedding is not null
  limit least(greatest(p_match_count, 1), 30) * 3
),
candidates as (
  select
    coalesce(f.id, s.id) as id,
    f.rank_ix as text_rank,
    s.rank_ix as semantic_rank
  from full_text f
  full outer join semantic s on s.id = f.id
)
select
  n.id,
  n.memory_type,
  n.title,
  n.content,
  n.summary,
  n.occurred_at,
  n.importance,
  n.emotional_intensity,
  n.confidence,
  n.truth_status,
  n.source_id,
  (
    coalesce(0.30 / (1 + c.text_rank), 0)
    + coalesce(0.45 / (1 + c.semantic_rank), 0)
    + (n.importance::double precision / 100.0) * 0.10
    + (n.confidence::double precision / 100.0) * 0.05
    + (n.emotional_intensity::double precision / 100.0) * 0.05
    + case
        when coalesce(trim(p_query_text), '') <> ''
          and lower(n.title) like '%' || lower(trim(p_query_text)) || '%'
        then 0.05
        else 0
      end
  )::double precision as score
from candidates c
join filtered n on n.id = c.id
order by score desc
limit least(greatest(p_match_count, 1), 30);
$matrix_function$;

create or replace function public.matrix_recall(p_payload jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $matrix_function$
declare
  v_auth_id uuid := auth.uid();
  v_owner_id uuid;
  v_payload_owner uuid;
  v_query text;
  v_embedding extensions.vector(384);
  v_match_count integer;
  v_memory_types text[];
  v_after timestamptz;
  v_before timestamptz;
  v_hops integer;
  v_hits jsonb := '[]'::jsonb;
  v_hit_ids uuid[] := '{}'::uuid[];
  v_seed_ids uuid[] := '{}'::uuid[];
  v_associations jsonb := '[]'::jsonb;
  v_history_id uuid;
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'payload must be a JSON object';
  end if;

  v_payload_owner := nullif(btrim(p_payload->>'owner_id'), '')::uuid;

  if v_auth_id is not null then
    if v_payload_owner is not null and v_payload_owner <> v_auth_id then
      raise exception 'owner_id does not match the authenticated user';
    end if;
    v_owner_id := v_auth_id;
  else
    if current_user not in ('postgres', 'service_role', 'supabase_admin') then
      raise exception 'an authenticated user or privileged server role is required';
    end if;
    v_owner_id := v_payload_owner;
  end if;

  if v_owner_id is null then
    raise exception 'owner_id is required for server-side calls';
  end if;

  v_query := nullif(btrim(p_payload->>'query'), '');
  if v_query is null then
    raise exception 'query is required';
  end if;

  v_match_count := least(
    greatest(coalesce((p_payload->>'limit')::integer, 12), 1),
    30
  );
  v_hops := least(
    greatest(coalesce((p_payload->>'hops')::integer, 1), 0),
    2
  );
  v_after := nullif(btrim(p_payload->>'occurred_after'), '')::timestamptz;
  v_before := nullif(btrim(p_payload->>'occurred_before'), '')::timestamptz;

  if p_payload ? 'memory_types'
     and p_payload->'memory_types' <> 'null'::jsonb
     and jsonb_typeof(p_payload->'memory_types') <> 'array' then
    raise exception 'memory_types must be a JSON array';
  end if;

  if p_payload ? 'memory_types'
     and p_payload->'memory_types' <> 'null'::jsonb then
    select array_agg(value)
      into v_memory_types
    from jsonb_array_elements_text(p_payload->'memory_types') as value;
  end if;

  if p_payload ? 'query_embedding'
     and p_payload->'query_embedding' <> 'null'::jsonb then
    v_embedding := ((p_payload->'query_embedding')::text)::extensions.vector;
  end if;

  with ranked as (
    with filtered as (
      select n.*
      from public.memory_nodes n
      where n.owner_id = v_owner_id
        and n.lifecycle_status = 'active'
        and (v_memory_types is null or n.memory_type = any(v_memory_types))
        and (v_after is null or n.occurred_at >= v_after)
        and (v_before is null or n.occurred_at <= v_before)
    ),
    full_text as (
      select
        n.id,
        row_number() over (
          order by ts_rank_cd(
            n.fts,
            websearch_to_tsquery('spanish', v_query)
          ) desc
        ) as rank_ix
      from filtered n
      where coalesce(trim(v_query), '') <> ''
        and n.fts @@ websearch_to_tsquery('spanish', v_query)
      limit least(greatest(v_match_count, 1), 30) * 3
    ),
    semantic as (
      select
        n.id,
        row_number() over (order by n.embedding operator(extensions.<=>) v_embedding) as rank_ix
      from filtered n
      where v_embedding is not null
        and n.embedding is not null
      limit least(greatest(v_match_count, 1), 30) * 3
    ),
    candidates as (
      select
        coalesce(f.id, s.id) as id,
        f.rank_ix as text_rank,
        s.rank_ix as semantic_rank
      from full_text f
      full outer join semantic s on s.id = f.id
    )
    select
      n.id,
      n.memory_type,
      n.title,
      n.content,
      n.summary,
      n.occurred_at,
      n.importance,
      n.emotional_intensity,
      n.confidence,
      n.truth_status,
      n.source_id,
      (
        coalesce(0.30 / (1 + c.text_rank), 0)
        + coalesce(0.45 / (1 + c.semantic_rank), 0)
        + (n.importance::double precision / 100.0) * 0.10
        + (n.confidence::double precision / 100.0) * 0.05
        + (n.emotional_intensity::double precision / 100.0) * 0.05
        + case
            when coalesce(trim(v_query), '') <> ''
              and lower(n.title) like '%' || lower(trim(v_query)) || '%'
            then 0.05
            else 0
          end
      )::double precision as score
    from candidates c
    join filtered n on n.id = c.id
    order by score desc
    limit least(greatest(v_match_count, 1), 30)
  )
  select
    coalesce(
      jsonb_agg(to_jsonb(ranked) order by ranked.score desc),
      '[]'::jsonb
    ),
    coalesce(
      array_agg(ranked.id order by ranked.score desc),
      '{}'::uuid[]
    )
  into v_hits, v_hit_ids
  from ranked;

  if cardinality(v_hit_ids) > 0 then
    update public.memory_nodes n
      set recall_count = n.recall_count + 1,
          last_recalled_at = now()
    where n.owner_id = v_owner_id
      and n.id = any(v_hit_ids);

    v_seed_ids := v_hit_ids[1:least(cardinality(v_hit_ids), 5)];

    if v_hops > 0 then
      select coalesce(
        jsonb_agg(to_jsonb(c) order by c.depth, c.activation desc),
        '[]'::jsonb
      )
      into v_associations
      from (
        with recursive walk(node_id, depth, activation, path) as (
          select n.id, 0, 1.0::double precision, array[n.id]
          from public.memory_nodes n
          where n.owner_id = v_owner_id
            and n.id = any(v_seed_ids)
            and n.lifecycle_status = 'active'
          union all
          select
            case when e.source_node_id = w.node_id then e.target_node_id else e.source_node_id end,
            w.depth + 1,
            w.activation * e.weight::double precision * 0.75,
            w.path || case when e.source_node_id = w.node_id then e.target_node_id else e.source_node_id end
          from walk w
          join public.memory_edges e
            on e.owner_id = v_owner_id
           and (e.source_node_id = w.node_id or e.target_node_id = w.node_id)
          where w.depth < least(greatest(v_hops, 0), 2)
            and not (
              case when e.source_node_id = w.node_id then e.target_node_id else e.source_node_id end
              = any(w.path)
            )
        ),
        ranked as (
          select w.node_id, min(w.depth) depth, max(w.activation) activation
          from walk w group by w.node_id
        )
        select n.id as node_id, r.depth, r.activation, n.memory_type, n.title, n.summary,
          n.occurred_at, n.truth_status
        from ranked r join public.memory_nodes n on n.id = r.node_id
        where n.owner_id = v_owner_id
        order by r.depth, r.activation desc, n.importance desc
      ) c;
    end if;
  end if;

  insert into public.retrieval_history (
    owner_id,
    query_text,
    result_node_ids,
    metadata
  ) values (
    v_owner_id,
    v_query,
    v_hit_ids,
    jsonb_build_object(
      'channel', coalesce(p_payload->>'channel', 'rpc'),
      'embedding_model', case
        when v_embedding is null then null
        else 'Supabase/gte-small'
      end,
      'semantic', v_embedding is not null,
      'memory_types', to_jsonb(v_memory_types),
      'occurred_after', v_after,
      'occurred_before', v_before,
      'hops', v_hops,
      'hit_count', cardinality(v_hit_ids)
    )
  ) returning id into v_history_id;

  return jsonb_build_object(
    'query', v_query,
    'history_id', v_history_id,
    'semantic', v_embedding is not null,
    'hits', v_hits,
    'associations', v_associations
  );
end
$matrix_function$;

-- CREATE OR REPLACE preserves ACLs; restate the intended public API explicitly.
revoke all on function public.matrix_recall(jsonb) from public, anon;
grant execute on function public.matrix_recall(jsonb) to authenticated, service_role;
revoke all on function public.recall_memories(text, extensions.vector, integer, text[], timestamptz, timestamptz) from public, anon;
grant execute on function public.recall_memories(text, extensions.vector, integer, text[], timestamptz, timestamptz) to authenticated, service_role;

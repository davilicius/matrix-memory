
create or replace function public.matrix_recall(p_payload jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $m$
declare
  v_auth_id uuid:=auth.uid(); v_owner_id uuid; v_payload_owner uuid;
  v_query text; v_embedding extensions.vector(384); v_match_count integer;
  v_memory_types text[]; v_after timestamptz; v_before timestamptz; v_hops integer;
  v_hits jsonb:='[]'::jsonb; v_hit_ids uuid[]:='{}'::uuid[];
  v_seed_ids uuid[]:='{}'::uuid[]; v_associations jsonb:='[]'::jsonb; v_history_id uuid;
begin
  if p_payload is null or jsonb_typeof(p_payload)<>'object' then
    raise exception 'payload must be a JSON object'; end if;
  v_payload_owner:=nullif(btrim(p_payload->>'owner_id'),'')::uuid;
  if v_auth_id is not null then
    if v_payload_owner is not null and v_payload_owner<>v_auth_id then
      raise exception 'owner_id does not match the authenticated user'; end if;
    v_owner_id:=v_auth_id;
  else
    if current_user not in ('postgres','service_role','supabase_admin') then
      raise exception 'an authenticated user or privileged server role is required'; end if;
    v_owner_id:=v_payload_owner;
  end if;
  if v_owner_id is null then raise exception 'owner_id is required for server-side calls'; end if;
  v_query:=nullif(btrim(p_payload->>'query'),'');
  if v_query is null then raise exception 'query is required'; end if;
  v_match_count:=least(greatest(coalesce((p_payload->>'limit')::integer,12),1),30);
  v_hops:=least(greatest(coalesce((p_payload->>'hops')::integer,1),0),2);
  v_after:=nullif(btrim(p_payload->>'occurred_after'),'')::timestamptz;
  v_before:=nullif(btrim(p_payload->>'occurred_before'),'')::timestamptz;
  if p_payload?'memory_types' and p_payload->'memory_types'<>'null'::jsonb
     and jsonb_typeof(p_payload->'memory_types')<>'array' then
    raise exception 'memory_types must be a JSON array'; end if;
  if p_payload?'memory_types' and p_payload->'memory_types'<>'null'::jsonb then
    select array_agg(value) into v_memory_types
    from jsonb_array_elements_text(p_payload->'memory_types') as value;
  end if;
  if p_payload?'query_embedding' and p_payload->'query_embedding'<>'null'::jsonb then
    v_embedding:=((p_payload->'query_embedding')::text)::extensions.vector;
  end if;
  with ranked as (
    select * from public.recall_memories(
      p_query_text:=v_query,p_query_embedding:=v_embedding,p_match_count:=v_match_count,
      p_memory_types:=v_memory_types,p_occurred_after:=v_after,p_occurred_before:=v_before
    )
  )
  select coalesce(jsonb_agg(to_jsonb(ranked) order by ranked.score desc),'[]'::jsonb),
         coalesce(array_agg(ranked.id order by ranked.score desc),'{}'::uuid[])
  into v_hits,v_hit_ids from ranked;
  if cardinality(v_hit_ids)>0 then
    update public.memory_nodes n
      set recall_count=n.recall_count+1,last_recalled_at=now()
      where n.owner_id=v_owner_id and n.id=any(v_hit_ids);
    v_seed_ids:=v_hit_ids[1:least(cardinality(v_hit_ids),5)];
    if v_auth_id is not null and v_hops>0 then
      select coalesce(jsonb_agg(to_jsonb(c) order by c.depth,c.activation desc),'[]'::jsonb)
      into v_associations from public.memory_context(v_seed_ids,v_hops) c;
    end if;
  end if;
  insert into public.retrieval_history(owner_id,query_text,result_node_ids,metadata)
  values(v_owner_id,v_query,v_hit_ids,jsonb_build_object(
    'channel',coalesce(p_payload->>'channel','rpc'),
    'embedding_model',case when v_embedding is null then null else 'Supabase/gte-small' end,
    'semantic',v_embedding is not null,'memory_types',to_jsonb(v_memory_types),
    'occurred_after',v_after,'occurred_before',v_before,'hops',v_hops,
    'hit_count',cardinality(v_hit_ids)
  )) returning id into v_history_id;
  return jsonb_build_object('query',v_query,'history_id',v_history_id,
    'semantic',v_embedding is not null,'hits',v_hits,'associations',v_associations);
end $m$;

create or replace function public.matrix_schema_info()
returns jsonb language sql stable security invoker set search_path='' as $m$
select jsonb_build_object(
  'schema_version','1.2','write_function','matrix_remember',
  'write_signature','matrix_remember(jsonb)','recall_function','matrix_recall',
  'recall_signature','matrix_recall(jsonb)','idempotency_field','event_key',
  'embedding_model','Supabase/gte-small','embedding_dimensions',384,
  'embedding_mode','asynchronous_queue',
  'memory_types',jsonb_build_array('episode','fact','decision','intention','project',
    'reflection','preference','procedure','identity','hypothesis'),
  'truth_statuses',jsonb_build_array('reported','verified','inferred','disputed','unknown'),
  'entity_kinds',jsonb_build_array('person','organization','place','project','device',
    'technology','concept','event','document','other'),
  'relation_types',jsonb_build_array('related_to','caused','resulted_in','part_of','involves',
    'occurred_before','occurred_after','contradicts','supersedes','supports','inspired',
    'depends_on','same_topic_as','located_at'),
  'source_types',jsonb_build_array('conversation','document','email','photo','audio','video',
    'note','database','web','sensor','testimony','other'),
  'required_fields',jsonb_build_array('event_key','memory_type','title','content'),
  'provenance_rule','Provide source_id or a source object',
  'duplicate_behavior','Return the existing memory without creating side effects'
) $m$;

revoke all on function public.matrix_recall(jsonb) from public,anon;
grant execute on function public.matrix_recall(jsonb) to authenticated,service_role;
revoke all on function public.matrix_remember(jsonb) from public,anon;
grant execute on function public.matrix_remember(jsonb) to authenticated,service_role;
revoke all on function public.recall_memories(text,extensions.vector,integer,text[],timestamptz,timestamptz) from public,anon;
grant execute on function public.recall_memories(text,extensions.vector,integer,text[],timestamptz,timestamptz) to authenticated,service_role;
revoke all on function public.memory_context(uuid[],integer) from public,anon;
grant execute on function public.memory_context(uuid[],integer) to authenticated,service_role;
revoke all on function public.matrix_schema_info() from public,anon;
grant execute on function public.matrix_schema_info() to authenticated,service_role;

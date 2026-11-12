
create or replace function private.enqueue_matrix_query_request(p_request_id uuid)
returns void language plpgsql security definer set search_path='' as $m$
declare v_owner_id uuid:=auth.uid();v_request record;v_job_id bigint;
begin
  if v_owner_id is null then raise exception 'authenticated user required';end if;
  select id,owner_id,query_hash,status into v_request
  from public.matrix_recall_requests
  where id=p_request_id and owner_id=v_owner_id for update;
  if not found then raise exception 'recall request not found for owner';end if;
  if v_request.status<>'queued' then return;end if;
  select pgmq.send('matrix_query_embedding_jobs',jsonb_build_object(
    'request_id',v_request.id,'owner_id',v_owner_id,'query_hash',v_request.query_hash))
  into v_job_id;
  perform private.process_matrix_query_embedding_jobs(1,1,120000);
end $m$;

create or replace function public.matrix_semantic_recall(p_payload jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $m$
declare v_owner_id uuid:=auth.uid();v_query text;v_hash text;v_request record;
 v_recall_payload jsonb;
begin
 if v_owner_id is null then raise exception 'authenticated user required';end if;
 if p_payload is null or jsonb_typeof(p_payload)<>'object' then
  raise exception 'payload must be a JSON object';end if;
 if nullif(btrim(p_payload->>'owner_id'),'') is not null
    and(p_payload->>'owner_id')::uuid<>v_owner_id then
  raise exception 'owner_id does not match the authenticated user';end if;
 v_query:=nullif(btrim(p_payload->>'query'),'');
 if v_query is null then raise exception 'query is required';end if;
 if length(v_query)>5000 then raise exception 'query must be 5000 characters or fewer';end if;
 v_hash:=md5(lower(v_query));
 perform pg_advisory_xact_lock(hashtextextended(v_owner_id::text||':'||v_hash,0));
 select * into v_request from public.matrix_recall_requests
 where owner_id=v_owner_id and query_hash=v_hash for update;
 if found and v_request.status='ready' and v_request.embedding is not null
    and v_request.expires_at>now() then
  v_recall_payload:=p_payload||jsonb_build_object('owner_id',v_owner_id,'query',v_query,
   'query_embedding',(v_request.embedding::text)::jsonb,
   'channel',coalesce(p_payload->>'channel','skill-sql'));
  return jsonb_build_object('status','ready','request_id',v_request.id,
   'result',public.matrix_recall(v_recall_payload));
 end if;
 if not found then
  insert into public.matrix_recall_requests(owner_id,query_text,query_hash,status)
  values(v_owner_id,v_query,v_hash,'queued') returning * into v_request;
  perform private.enqueue_matrix_query_request(v_request.id);
 elsif v_request.status in('error','ready') or v_request.expires_at<=now() then
  update public.matrix_recall_requests set query_text=v_query,embedding=null,status='queued',
   error=null,updated_at=now(),expires_at=now()+interval '24 hours'
  where id=v_request.id returning * into v_request;
  perform private.enqueue_matrix_query_request(v_request.id);
 end if;
 return jsonb_build_object('status','pending','request_id',v_request.id,
  'query',v_query,'retry_after_ms',1000);
end $m$;

revoke execute on all functions in schema private from public,anon,authenticated;
grant usage on schema private to authenticated;
grant execute on function private.enqueue_matrix_query_request(uuid) to authenticated;
alter default privileges in schema private revoke execute on functions from public;

revoke all on function public.matrix_semantic_recall(jsonb) from public,anon;
grant execute on function public.matrix_semantic_recall(jsonb) to authenticated;

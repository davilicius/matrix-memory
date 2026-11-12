
create table if not exists public.matrix_recall_requests(
 id uuid primary key default gen_random_uuid(),
 owner_id uuid not null references auth.users(id) on delete cascade,
 query_text text not null,query_hash text not null,embedding extensions.vector(384),
 status text not null default 'queued' check(status in('queued','processing','ready','error')),
 error text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 expires_at timestamptz not null default(now()+interval '24 hours'),unique(owner_id,query_hash)
);
alter table public.matrix_recall_requests enable row level security;
drop policy if exists matrix_recall_requests_own on public.matrix_recall_requests;
create policy matrix_recall_requests_own on public.matrix_recall_requests
for all to authenticated using(owner_id=(select auth.uid()))
with check(owner_id=(select auth.uid()));
create index if not exists matrix_recall_requests_owner_status_idx
on public.matrix_recall_requests(owner_id,status,updated_at desc);
select pgmq.create('matrix_query_embedding_jobs');

create or replace function private.process_matrix_query_embedding_jobs(
 p_batch_size integer default 1,p_max_requests integer default 1,
 p_timeout_milliseconds integer default 120000
) returns void language plpgsql security definer set search_path='' as $m$
declare v_batches jsonb[];v_batch jsonb;v_url text;v_secret text;
begin
 select decrypted_secret into v_url from vault.decrypted_secrets where name='matrix_project_url';
 select decrypted_secret into v_secret from vault.decrypted_secrets
  where name='matrix_embedding_worker_secret';
 with numbered_jobs as(
  select message||jsonb_build_object('job_id',msg_id) job_info,
   (row_number() over(order by msg_id)-1)/greatest(p_batch_size,1) batch_no
  from pgmq.read(queue_name=>'matrix_query_embedding_jobs',
   vt=>greatest(p_timeout_milliseconds/1000,30),
   qty=>greatest(p_max_requests,1)*greatest(p_batch_size,1))
 ),batches as(
  select jsonb_agg(job_info order by(job_info->>'job_id')::bigint) items
  from numbered_jobs group by batch_no
 )
 select coalesce(array_agg(items),array[]::jsonb[]) into v_batches from batches;
 foreach v_batch in array v_batches loop
  perform net.http_post(url=>v_url||'/functions/v1/matrix-query-embedding-worker',
   headers=>jsonb_build_object('Content-Type','application/json',
    'x-matrix-worker-secret',v_secret),
   body=>v_batch,timeout_milliseconds=>p_timeout_milliseconds);
 end loop;
end $m$;
revoke all on function private.process_matrix_query_embedding_jobs(integer,integer,integer)
from public,anon,authenticated;

create or replace function public.matrix_semantic_recall(p_payload jsonb)
returns jsonb language plpgsql security definer set search_path='' as $m$
declare v_owner_id uuid:=auth.uid();v_query text;v_hash text;v_request record;
 v_job_id bigint;v_recall_payload jsonb;
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
  select pgmq.send('matrix_query_embedding_jobs',jsonb_build_object(
   'request_id',v_request.id,'owner_id',v_owner_id,'query_hash',v_hash)) into v_job_id;
  perform private.process_matrix_query_embedding_jobs(1,1,120000);
 elsif v_request.status in('error','ready') or v_request.expires_at<=now() then
  update public.matrix_recall_requests set query_text=v_query,embedding=null,status='queued',
   error=null,updated_at=now(),expires_at=now()+interval '24 hours'
  where id=v_request.id returning * into v_request;
  select pgmq.send('matrix_query_embedding_jobs',jsonb_build_object(
   'request_id',v_request.id,'owner_id',v_owner_id,'query_hash',v_hash)) into v_job_id;
  perform private.process_matrix_query_embedding_jobs(1,1,120000);
 end if;
 return jsonb_build_object('status','pending','request_id',v_request.id,
  'query',v_query,'retry_after_ms',1000);
end $m$;
revoke all on function public.matrix_semantic_recall(jsonb) from public,anon;
grant execute on function public.matrix_semantic_recall(jsonb) to authenticated;

do $m$
declare v_job_id bigint;
begin
 select jobid into v_job_id from cron.job where jobname='matrix-process-query-embeddings' limit 1;
 if v_job_id is not null then perform cron.unschedule(v_job_id);end if;
 perform cron.schedule('matrix-process-query-embeddings','* * * * *',
  'select private.process_matrix_query_embedding_jobs(1,1,120000);');
end $m$;

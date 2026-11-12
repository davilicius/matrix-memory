
do $m$ begin
  if not exists(select 1 from vault.decrypted_secrets where name='matrix_project_url') then
    perform vault.create_secret(current_setting('matrix.project_url'),'matrix_project_url',
      'Matrix project URL used by the embedding cron');
  end if;
  if not exists(select 1 from vault.decrypted_secrets where name='matrix_embedding_worker_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32),'hex'),
      'matrix_embedding_worker_secret','Authentication secret for the Matrix embedding worker');
  end if;
end $m$;

create or replace function private.process_matrix_embedding_jobs(
  p_batch_size integer default 10,p_max_requests integer default 5,
  p_timeout_milliseconds integer default 300000
) returns void language plpgsql security definer set search_path='' as $m$
declare v_batches jsonb[]; v_batch jsonb; v_url text; v_secret text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name='matrix_project_url';
  select decrypted_secret into v_secret from vault.decrypted_secrets
    where name='matrix_embedding_worker_secret';
  with numbered_jobs as (
    select message||jsonb_build_object('job_id',msg_id) as job_info,
      (row_number() over(order by msg_id)-1)/greatest(p_batch_size,1) as batch_no
    from pgmq.read(queue_name=>'matrix_embedding_jobs',
      vt=>greatest(p_timeout_milliseconds/1000,30),
      qty=>greatest(p_max_requests,1)*greatest(p_batch_size,1))
  ), batches as (
    select jsonb_agg(job_info order by (job_info->>'job_id')::bigint) as items
    from numbered_jobs group by batch_no
  )
  select coalesce(array_agg(items),array[]::jsonb[]) into v_batches from batches;
  foreach v_batch in array v_batches loop
    perform net.http_post(
      url=>v_url||'/functions/v1/matrix-embedding-worker',
      headers=>jsonb_build_object('Content-Type','application/json',
        'x-matrix-worker-secret',v_secret),
      body=>v_batch,timeout_milliseconds=>p_timeout_milliseconds);
  end loop;
end $m$;

revoke all on function private.process_matrix_embedding_jobs(integer,integer,integer)
from public,anon,authenticated;

do $m$
declare v_job_id bigint;
begin
  select jobid into v_job_id from cron.job where jobname='matrix-process-embeddings' limit 1;
  if v_job_id is not null then perform cron.unschedule(v_job_id); end if;
  perform cron.schedule('matrix-process-embeddings','* * * * *',
    'select private.process_matrix_embedding_jobs();');
end $m$;

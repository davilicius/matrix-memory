
do $m$
declare v_job_id bigint;
begin
  select jobid into v_job_id from cron.job
  where jobname='matrix-process-embeddings' limit 1;
  if v_job_id is not null then perform cron.unschedule(v_job_id); end if;
  perform cron.schedule(
    'matrix-process-embeddings','* * * * *',
    'select private.process_matrix_embedding_jobs(3,1,120000);'
  );
end $m$;

select pgmq.purge_queue('matrix_embedding_jobs');
update public.memory_nodes
set embedding_status='pending',embedding_error=null
where embedding is null or embedding_status<>'ready';
select pgmq.send(
  queue_name=>'matrix_embedding_jobs',
  msg=>jsonb_build_object(
    'memory_id',id,'owner_id',owner_id,'input_hash',embedding_input_hash
  )
)
from public.memory_nodes
where embedding is null or embedding_status<>'ready';

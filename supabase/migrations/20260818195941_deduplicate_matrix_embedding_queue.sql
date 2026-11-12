
select pgmq.purge_queue('matrix_embedding_jobs');
select pgmq.send(
  queue_name=>'matrix_embedding_jobs',
  msg=>jsonb_build_object(
    'memory_id',id,'owner_id',owner_id,'input_hash',embedding_input_hash
  )
)
from public.memory_nodes
where embedding is null or embedding_status<>'ready';

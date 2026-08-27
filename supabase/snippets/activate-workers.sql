-- NO ejecutes este archivo sin sustituir ambos marcadores.
-- Usa un proyecto educativo y un secreto aleatorio exclusivo.

select vault.create_secret(
  'https://TU_PROJECT_REF.supabase.co',
  'matrix_project_url',
  'URL utilizada por los crones educativos de Matrix'
);

select vault.create_secret(
  'SUSTITUYE_POR_UN_SECRETO_ALEATORIO_LARGO',
  'matrix_embedding_worker_secret',
  'Autenticación interna de los workers de Matrix'
);

do $matrix_cron$
declare
  v_job_id bigint;
begin
  select jobid into v_job_id
  from cron.job
  where jobname = 'matrix-process-embeddings'
  limit 1;

  if v_job_id is not null then
    perform cron.unschedule(v_job_id);
  end if;

  perform cron.schedule(
    'matrix-process-embeddings',
    '* * * * *',
    'select private.process_matrix_embedding_jobs(3, 1, 120000);'
  );

  select jobid into v_job_id
  from cron.job
  where jobname = 'matrix-process-query-embeddings'
  limit 1;

  if v_job_id is not null then
    perform cron.unschedule(v_job_id);
  end if;

  perform cron.schedule(
    'matrix-process-query-embeddings',
    '* * * * *',
    'select private.process_matrix_query_embedding_jobs(1, 1, 120000);'
  );
end
$matrix_cron$;

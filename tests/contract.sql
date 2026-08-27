begin;

select plan(16);

select is(
  public.matrix_schema_info()->>'schema_version',
  '1.2',
  'schema contract is version 1.2'
);

select has_table('public', 'memory_nodes', 'memory_nodes exists');
select has_table('public', 'memory_edges', 'memory_edges exists');
select has_table('public', 'retrieval_history', 'retrieval_history exists');
select has_table('public', 'matrix_recall_requests', 'recall request cache exists');

select has_column('public', 'memory_nodes', 'embedding_status', 'embedding status exists');
select has_column('public', 'memory_nodes', 'embedding_input_hash', 'embedding hash exists');

select has_function('public', 'matrix_remember', array['jsonb'], 'write RPC exists');
select has_function('public', 'matrix_recall', array['jsonb'], 'canonical recall RPC exists');
select has_function('public', 'matrix_semantic_recall', array['jsonb'], 'semantic recall RPC exists');
select has_function('public', 'matrix_schema_info', 'contract RPC exists');

select isnt_definer('public', 'matrix_remember', array['jsonb'], 'write RPC is invoker');
select isnt_definer('public', 'matrix_recall', array['jsonb'], 'recall RPC is invoker');
select isnt_definer('public', 'matrix_semantic_recall', array['jsonb'], 'semantic adapter is invoker');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.retrieval_history'::regclass),
  'retrieval history has RLS'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.matrix_recall_requests'::regclass),
  'request cache has RLS'
);

select * from finish();
rollback;

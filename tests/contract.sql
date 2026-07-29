begin;

select plan(5);

select is(
  public.matrix_schema_info()->>'schema_version',
  '1.1',
  'schema contract is version 1.1'
);

select has_table('public', 'memory_nodes', 'memory_nodes exists');
select has_table('public', 'memory_edges', 'memory_edges exists');
select has_function('public', 'matrix_remember', array['jsonb'], 'write RPC exists');
select has_function('public', 'recall_memories', 'retrieval RPC exists');

select * from finish();
rollback;

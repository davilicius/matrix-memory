// Render the actual application's bound SELECT into a disposable-DB regression.
// Run only through tests/run-permissions.sh, never against a hosted database.
import {loadSpelling} from '../supabase/functions/matrix-mcp/spelling-db.ts';
let captured='';
function literal(value:any):string{
  if(value&&typeof value==='object'&&'sql' in value)return value.sql;
  if(value===null||value===undefined)return 'null';
  if(Array.isArray(value))return 'ARRAY['+value.map(literal).join(',')+']';
  if(typeof value==='number')return String(value);
  return "'"+String(value).replaceAll("'","''")+"'";
}
const q:any=(parts:TemplateStringsArray,...values:any[])=>{
  const sql=parts.map((part,i)=>part+(i<values.length?literal(values[i]):'')).join('');
  if(sql.trim().startsWith('with eligible')){captured=sql;return Promise.resolve([{rows:[],pool_count:0,shortlist_count:0}]);}
  if(sql.includes('set_config'))return Promise.resolve([]);
  return {sql};
};
q.json=(v:any)=>JSON.stringify(v);
const owner='11111111-1111-4111-8111-111111111111';
const other='22222222-2222-4222-8222-222222222222';
console.log(`begin;
insert into auth.users(id) values ('${owner}'),('${other}') on conflict do nothing;
insert into public.memory_nodes(id,owner_id,memory_type,title,content,occurred_at,lifecycle_status,valid_from,valid_to) values
 ('10000000-0000-4000-8000-000000000001','${owner}','procedure','Receta calabaza','Synthetic','2000-01-01','active',null,null),
 ('10000000-0000-4000-8000-000000000002','${other}','procedure','Receta calabaza','Synthetic','2000-01-01','active',null,null),
 ('10000000-0000-4000-8000-000000000003','${owner}','procedure','Receta calabaza','Synthetic','2000-01-01','archived',null,null),
 ('10000000-0000-4000-8000-000000000004','${owner}','procedure','Receta calabaza','Synthetic','2000-01-01','active',null,'2001-01-01'),
 ('10000000-0000-4000-8000-000000000005','${owner}','procedure','Receta calabaza','Synthetic','2000-01-01','active','2999-01-01',null),
 ('10000000-0000-4000-8000-000000000006','${owner}','fact','Calabaza','Synthetic','2010-01-01','active',null,null);
set local role authenticated;
select set_config('request.jwt.claim.sub','${owner}',true),set_config('request.jwt.claims','{"sub":"${owner}","role":"authenticated"}',true);
`);
for(const test of [
 {owner,args:{query:'calabza',limit:6,memory_types:['procedure']},expected:1},
 {owner,args:{query:'calabza',limit:6,memory_types:['procedure'],occurred_after:'2005-01-01T00:00:00Z'},expected:0},
 {owner,args:{query:'calabza',limit:6,occurred_before:'1999-01-01T00:00:00Z'},expected:0},
 {owner:other,args:{query:'calabza',limit:6},expected:0},
]){
  await loadSpelling(q,test.owner,test.args,['calabza']);
  console.log(`do $test$ declare result record; begin
    select * into result from (${captured}) as tested;
    assert jsonb_array_length(result.rows)=${test.expected},'Spelling scope/filter regression';
    ${test.expected?"assert result.rows->0->>'id'='10000000-0000-4000-8000-000000000001','Unexpected memory'; assert result.rows->0->'matches'->0->'words'->0->>'word'='calabaza','Candidate missing';":''}
  end $test$;`);
}
console.log('rollback;');

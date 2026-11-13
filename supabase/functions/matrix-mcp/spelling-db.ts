import {SPELLING_LIMITS,selectSpelling,type SpellingRow} from './spelling.ts';

// Called only inside the backend's authenticated, owner-bound transaction.
// Parameters are always bound by postgres.js, including terms and date/type filters.
export async function loadSpelling(q:any,owner:string,args:any,terms:string[]){
  await q`select set_config('statement_timeout','1000',true)`;
  const [result]=await q`with eligible as materialized (
    select n.id,n.title,n.summary,n.created_at from public.memory_nodes n
    where n.owner_id=${owner}::uuid and n.lifecycle_status='active'
      and (n.valid_from is null or n.valid_from<=now()) and (n.valid_to is null or n.valid_to>now())
      ${args.memory_types?q`and n.memory_type=any(${args.memory_types}::text[])`:q``}
      ${args.occurred_after?q`and n.occurred_at>=${args.occurred_after}::timestamptz`:q``}
      ${args.occurred_before?q`and n.occurred_at<=${args.occurred_before}::timestamptz`:q``}
    order by n.created_at desc,n.id limit 2001
  ), docs as materialized (
    select id,title,created_at,translate(lower(normalize(title||' '||left(coalesce(summary,''),1000),NFC)),'áéíóúü','aeiouu') as body
    from eligible order by created_at desc,id limit 2000
  ), terms as materialized (select unnest(${terms}::text[]) as term),
  shortlist as materialized (
    select d.*,s.score from docs d cross join lateral (
      select min(extensions.strict_word_similarity(t.term,d.body)) as score from terms t
    )s where s.score>=0.45 order by s.score desc,d.created_at desc,d.id limit 65
  ), chosen as materialized (select * from shortlist order by score desc,created_at desc,id limit 64),
  vocabulary as materialized (
    select d.id,w.word from chosen d cross join lateral (
      select distinct word from regexp_split_to_table(d.body,'[^a-zñ]+')word where length(word) between 4 and 34
    )w
  ), candidates as (
    select d.id,d.title,jsonb_agg(jsonb_build_object('term',t.term,'words',coalesce(w.words,'[]'::jsonb)) order by t.term) as matches
    from chosen d cross join terms t cross join lateral (
      select jsonb_agg(jsonb_build_object('word',x.word,'trigram',x.score) order by x.score desc,x.word) as words from (
        select v.word,extensions.similarity(t.term,v.word) as score from vocabulary v
        where v.id=d.id and abs(length(t.term)-length(v.word))<=case when length(t.term)>=9 then 2 else 1 end
          and extensions.similarity(t.term,v.word)>=0.45
        order by score desc,v.word limit 3
      )x
    )w group by d.id,d.title
  ) select coalesce((select jsonb_agg(c) from candidates c),'[]'::jsonb) as rows,
    (select count(*)::int from eligible) as pool_count,(select count(*)::int from shortlist) as shortlist_count`;
  const items=selectSpelling(result.rows as SpellingRow[],terms,args.limit??6);
  let historyId=null;
  if(items.length){
    const ids=items.map(i=>i.id);
    const rows=await q`insert into public.retrieval_history(owner_id,query_text,result_node_ids,metadata)
      values(${owner}::uuid,${args.query},${ids}::uuid[],${q.json({channel:'matrix-mcp',operation:'spelling_supplement',terms,limits:SPELLING_LIMITS})}) returning id`;
    historyId=rows[0].id;
    await q`update public.memory_nodes set recall_count=recall_count+1,last_recalled_at=now() where owner_id=${owner}::uuid and id=any(${ids}::uuid[])`;
  }
  return {items,context:{history_id:historyId,limits:SPELLING_LIMITS,pool_scanned:Math.min(result.pool_count,2000),pool_truncated:result.pool_count>2000,
    documents_considered:Math.min(result.shortlist_count,64),documents_truncated:result.shortlist_count>64}};
}

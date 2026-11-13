import postgres from 'postgres';
import { annotateMemory, qualityWarnings, currentContext } from './temporal.ts';
import { VERSION, type Backend } from './core.ts';
import { topicScopes, selectRecentTopics, resolveWithRecent } from './current-topic.ts';

export function makeBackend(databaseUrl:string, ownerId:string):Backend {
  const OWNER = ownerId;
  const sql=postgres(databaseUrl,{prepare:false,max:1,idle_timeout:10,connect_timeout:10,max_lifetime:60});
  async function tx(fn:(q:any)=>Promise<any>) {
    return await sql.begin(async(q:any)=>{
      await q`set local role authenticated`;
      await q`select set_config('request.jwt.claim.sub',${OWNER},true),set_config('request.jwt.claims',${JSON.stringify({sub:OWNER,role:'authenticated'})},true),set_config('statement_timeout','12000',true),set_config('lock_timeout','3000',true)`;
      return await fn(q);
    });
  }
  async function enrich(result:any) {
    const seed=[...(result.hits||[]),...(result.associations||[])].map((h:any)=>h.id||h.node_id).filter(Boolean);
    if(!seed.length)return {...result,successor_candidates:[],temporal_truncated:false};
    return await tx(async q=>{
      const rows=await q`with recursive chain(id,path,depth) as (
        select n.id,array[n.id],0 from public.memory_nodes n where n.owner_id=${OWNER}::uuid and n.id=any(${seed}::uuid[])
        union all
        select e.source_node_id,c.path||e.source_node_id,c.depth+1 from chain c join public.memory_edges e on e.target_node_id=c.id
        where e.owner_id=${OWNER}::uuid and e.relation_type='supersedes' and c.depth<8 and not e.source_node_id=any(c.path)
          and (e.valid_from is null or e.valid_from<=now()) and (e.valid_to is null or e.valid_to>now())
      ) select n.id,n.title,n.memory_type,n.summary,left(n.content,900) excerpt,n.occurred_at,n.created_at,n.updated_at,n.lifecycle_status,n.valid_from,n.valid_to,n.truth_status,n.source_id,
        (select jsonb_build_object('type',s.source_type,'title',s.title,'uri',s.uri) from public.sources s where s.id=n.source_id and s.owner_id=${OWNER}::uuid) source,
        coalesce((select jsonb_agg(jsonb_build_object('id',e.source_node_id,'scope',coalesce(e.metadata->>'supersession_scope','unreviewed'),'scope_description',e.metadata->>'scope')) from public.memory_edges e where e.owner_id=${OWNER}::uuid and e.target_node_id=n.id and e.relation_type='supersedes' and (e.valid_from is null or e.valid_from<=now()) and (e.valid_to is null or e.valid_to>now())),'[]'::jsonb) replacements,
        coalesce((select jsonb_agg(case when e.source_node_id=n.id then e.target_node_id else e.source_node_id end) from public.memory_edges e where e.owner_id=${OWNER}::uuid and (e.target_node_id=n.id or e.source_node_id=n.id) and e.relation_type='contradicts' and (e.valid_from is null or e.valid_from<=now()) and (e.valid_to is null or e.valid_to>now())),'[]'::jsonb) contradictions
        from public.memory_nodes n where n.owner_id=${OWNER}::uuid and n.id in (select id from chain) order by n.created_at desc,n.id limit 201`;
      const byId=new Map(rows.slice(0,200).map((r:any)=>[r.id,annotateMemory(r)]));
      const attach=(h:any)=>({...h,...(byId.get(h.id||h.node_id)||{currentness:'unknown'}),content:undefined});
      return {...result,hits:(result.hits||[]).map(attach),associations:(result.associations||[]).map(attach),successor_candidates:rows.slice(0,200).filter((r:any)=>!seed.includes(r.id)).map((r:any)=>annotateMemory(r)),temporal_truncated:rows.length>200,temporal_depth_limit:8};
    });
  }
  return {
    async supersede(args){return await tx(async q=>{
      const payload={...args,replacement:{...args.replacement,metadata:{...args.replacement.metadata,channel:'matrix-mcp'}}};
      const result=(await q`select public.matrix_supersede(${q.json(payload)}::jsonb) as result`)[0].result;
      return {...result,quality_warnings:qualityWarnings(args.replacement)};
    });},
    async resolve_current({query,limit,topic}){
      const {baseline,recent}=await resolveWithRecent(
        ()=>this.search({query,limit,hops:1}),
        ()=>tx(async q=>{
          const entities=await q`select id,kind,canonical_name,aliases from public.entities where owner_id=${OWNER}::uuid and kind in ('project','organization','technology','device') order by id limit 501`;
          const scopes=topicScopes(query,entities.slice(0,500),topic);
          if(!scopes.length)return {status:'no_named_topic',items:[],topics:[],catalog_truncated:entities.length>500,coverage:'no_named_topic_no_recent_supplement'};
          const rows=await q`select n.id,n.title,n.lifecycle_status,n.occurred_at,n.created_at,n.valid_from,n.valid_to,
            coalesce((select jsonb_agg(me.entity_id) from public.memory_entities me where me.owner_id=${OWNER}::uuid and me.memory_node_id=n.id),'[]'::jsonb) entity_ids
            from public.memory_nodes n where n.owner_id=${OWNER}::uuid and n.lifecycle_status='active'
              and (n.valid_from is null or n.valid_from<=now()) and (n.valid_to is null or n.valid_to>now())
            order by coalesce(n.occurred_at,n.created_at) desc,n.id desc limit 201`;
          const items=selectRecentTopics(rows.slice(0,200),scopes,limit);
          if(items.length){
            const ids=items.map((m:any)=>m.id);
            await q`insert into public.retrieval_history(owner_id,query_text,result_node_ids,metadata) values(${OWNER}::uuid,${query},${ids}::uuid[],${q.json({channel:'matrix-mcp',operation:'resolve_current_recent',pool_limit:200,topics:scopes.map(s=>s.term)})})`;
          }
          return {status:items.length?'supplemented':'no_match_in_recent_pool',items,topics:scopes.map(s=>({term:s.term,basis:s.basis})),pool_scanned:Math.min(rows.length,200),pool_truncated:rows.length>200,catalog_truncated:entities.length>500,coverage:'bounded_recent_topic_evidence_not_latest_state_guarantee'};
        }),enrich);
      return {...currentContext(baseline),recent_topic_candidates:recent.items,
        recent_successor_candidates:recent.successor_candidates||[],
        recent_context:{...recent,items:undefined,successor_candidates:undefined},
        notice:'Candidatos y evidencia reciente del tema; revisar fuentes, fechas, sustituciones y contradicciones. La fecha de guardado no acredita vigencia y la búsqueda no es exhaustiva.'};
    },
    async search(args){
      const payload={...args,owner_id:OWNER,channel:'matrix-mcp'};
      for(let attempt=0;attempt<4;attempt++){
        const r=await tx(async q=>(await q`select public.matrix_semantic_recall(${q.json(payload)}::jsonb) as result`)[0].result);
        if(r.status==='ready')return await enrich({...r.result,mode:'hybrid'});
        if(attempt<3)await new Promise(r=>setTimeout(r,1000));
      }
      const r=await tx(async q=>(await q`select public.matrix_recall(${q.json({...payload,channel:'matrix-mcp-text-fallback'})}::jsonb) as result`)[0].result);
      return await enrich({...r,mode:'text_fallback',notice:'El índice semántico no estuvo listo; esta consulta usó búsqueda textual.'});
    },
    async fetch({id,offset,length}){const fetched=await tx(async q=>{
      const rows=await q`select (to_jsonb(n)-'embedding'-'fts'-'content'-'embedding_error') || jsonb_build_object('content',substring(n.content from ${offset+1}::integer for ${length}::integer),'content_length',length(n.content),'offset',${offset}::integer,'next_offset',case when length(n.content)>${offset+length} then ${offset+length}::integer else null end) as memory,
        (select to_jsonb(s)-'content_text' from public.sources s where s.id=n.source_id and s.owner_id=${OWNER}::uuid) as source,
        coalesce((select jsonb_agg(jsonb_build_object('id',e.id,'name',e.canonical_name,'kind',e.kind,'role',me.role)) from public.memory_entities me join public.entities e on e.id=me.entity_id and e.owner_id=${OWNER}::uuid where me.memory_node_id=n.id and me.owner_id=${OWNER}::uuid),'[]'::jsonb) as entities
        from public.memory_nodes n where n.owner_id=${OWNER}::uuid and n.id=${id}::uuid`;
      if(!rows.length)throw new Error('Recuerdo no encontrado.');
      if(offset===0){
        await q`update public.memory_nodes set recall_count=recall_count+1,last_recalled_at=now() where owner_id=${OWNER}::uuid and id=${id}::uuid`;
        await q`insert into public.retrieval_history(owner_id,query_text,result_node_ids,metadata) values(${OWNER}::uuid,${'fetch:'+id},array[${id}::uuid],${q.json({channel:'matrix-mcp',operation:'fetch'})})`;
      }
      return rows[0];
    });
      const context=await enrich({hits:[{id}],associations:[]});
      return {...fetched,memory:{...context.hits[0],...fetched.memory},successor_candidates:context.successor_candidates};
    },
    async related({id,hops,limit}){const result=await tx(async q=>{
      const exists=await q`select id from public.memory_nodes where owner_id=${OWNER}::uuid and id=${id}::uuid`;if(!exists.length)throw new Error('Recuerdo no encontrado.');
      const rows=await q`select * from public.memory_context(array[${id}::uuid],${hops}) where node_id<>${id}::uuid limit ${limit+1}`;
      const edges=await q`select id,source_node_id,target_node_id,relation_type,weight,confidence,valid_from,valid_to from public.memory_edges where owner_id=${OWNER}::uuid and (source_node_id=${id}::uuid or target_node_id=${id}::uuid) order by weight desc,id limit 101`;
      return {id,hops,memories:rows.slice(0,limit),has_more:rows.length>limit,direct_relations:edges.slice(0,100),relations_truncated:edges.length>100};
    });
      const context=await enrich({hits:result.memories,associations:[]});
      return {...result,memories:context.hits,successor_candidates:context.successor_candidates};
    },
    async list_recent({limit,cursor,memory_type}){
      let c:{created_at:string,id:string}|null=null;
      if(cursor){try{c=JSON.parse(atob(cursor));if(!c || !/^[0-9a-f-]{36}$/.test(c.id)||!Number.isFinite(Date.parse(c.created_at)))throw 0;}catch{throw new Error('Cursor inválido.');}}
      return await tx(async q=>{
        const rows=await q`select id,event_key,title,memory_type,summary,left(content,600) as excerpt,truth_status,occurred_at,created_at,updated_at,lifecycle_status,valid_from,valid_to,source_id from public.memory_nodes where owner_id=${OWNER}::uuid and lifecycle_status='active' ${memory_type?q`and memory_type=${memory_type}`:q``} ${c?q`and (created_at,id)<(${c.created_at}::timestamptz,${c.id}::uuid)`:q``} order by created_at desc,id desc limit ${limit+1}`;
        const items=rows.slice(0,limit);const last=items.at(-1);
        return {items,next_cursor:rows.length>limit?btoa(JSON.stringify({created_at:last.created_at,id:last.id})):null};
      });
    },
    async remember(args){return await tx(async q=>{
      const payload={...args,owner_id:OWNER,lifecycle_status:'active',metadata:{...args.metadata,channel:'matrix-mcp'}};
      const result=(await q`select public.matrix_remember(${q.json(payload)}::jsonb) as result`)[0].result;
      if(result.status==='existing'){
        const match=(await q`select title=${args.title} and content=${args.content} as same_content from public.memory_nodes where owner_id=${OWNER}::uuid and id=${result.memory_id}::uuid`)[0];
        result.same_content=match?.same_content??false;
        if(!result.same_content)result.notice='La event_key ya existe con otro contenido; no se sobrescribió. Revisar el recuerdo existente.';
      }
      return {...result,quality_warnings:qualityWarnings(args)};
    });},
    async status(){return await tx(async q=>{
      const info=(await q`select public.matrix_schema_info() as contract`)[0].contract;
      const stats=(await q`select count(*)::int as memories,count(*) filter(where lifecycle_status='active')::int as active,count(*) filter(where embedding is not null)::int as indexed,max(created_at) as last_saved_at from public.memory_nodes where owner_id=${OWNER}::uuid`)[0];
      return {status:'ok',server_version:VERSION,schema_version:info.schema_version,identity:'Matrix owner',permissions:['resolve_current','search','fetch','related','list_recent','remember','supersede','status'],...stats};
    });}
  };
}

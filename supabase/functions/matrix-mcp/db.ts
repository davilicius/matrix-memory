import postgres from 'postgres';
import { VERSION, type Backend } from './core.ts';

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
  return {
    async search(args){
      const payload={...args,owner_id:OWNER,channel:'matrix-mcp'};
      for(let attempt=0;attempt<4;attempt++){
        const r=await tx(async q=>(await q`select public.matrix_semantic_recall(${q.json(payload)}::jsonb) as result`)[0].result);
        if(r.status==='ready')return {...r.result,hits:r.result.hits.map((h:any)=>({...h,content:undefined,excerpt:(h.summary||h.content||'').slice(0,900)})),mode:'hybrid'};
        if(attempt<3)await new Promise(r=>setTimeout(r,1000));
      }
      const r=await tx(async q=>(await q`select public.matrix_recall(${q.json({...payload,channel:'matrix-mcp-text-fallback'})}::jsonb) as result`)[0].result);
      return {...r,hits:r.hits.map((h:any)=>({...h,content:undefined,excerpt:(h.summary||h.content||'').slice(0,900)})),mode:'text_fallback',notice:'El índice semántico no estuvo listo; esta consulta usó búsqueda textual.'};
    },
    async fetch({id,offset,length}){return await tx(async q=>{
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
    });},
    async related({id,hops,limit}){return await tx(async q=>{
      const exists=await q`select id from public.memory_nodes where owner_id=${OWNER}::uuid and id=${id}::uuid`;if(!exists.length)throw new Error('Recuerdo no encontrado.');
      const rows=await q`select * from public.memory_context(array[${id}::uuid],${hops}) where node_id<>${id}::uuid limit ${limit+1}`;
      const edges=await q`select id,source_node_id,target_node_id,relation_type,weight,confidence,valid_from,valid_to from public.memory_edges where owner_id=${OWNER}::uuid and (source_node_id=${id}::uuid or target_node_id=${id}::uuid) order by weight desc,id limit 101`;
      return {id,hops,memories:rows.slice(0,limit),has_more:rows.length>limit,direct_relations:edges.slice(0,100),relations_truncated:edges.length>100};
    });},
    async list_recent({limit,cursor,memory_type}){
      let c:{created_at:string,id:string}|null=null;
      if(cursor){try{c=JSON.parse(atob(cursor));if(!c || !/^[0-9a-f-]{36}$/.test(c.id)||!Number.isFinite(Date.parse(c.created_at)))throw 0;}catch{throw new Error('Cursor inválido.');}}
      return await tx(async q=>{
        const rows=await q`select id,event_key,title,memory_type,summary,left(content,600) as excerpt,truth_status,occurred_at,created_at,source_id from public.memory_nodes where owner_id=${OWNER}::uuid and lifecycle_status='active' ${memory_type?q`and memory_type=${memory_type}`:q``} ${c?q`and (created_at,id)<(${c.created_at}::timestamptz,${c.id}::uuid)`:q``} order by created_at desc,id desc limit ${limit+1}`;
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
      return result;
    });},
    async status(){return await tx(async q=>{
      const info=(await q`select public.matrix_schema_info() as contract`)[0].contract;
      const stats=(await q`select count(*)::int as memories,count(*) filter(where lifecycle_status='active')::int as active,count(*) filter(where embedding is not null)::int as indexed,max(created_at) as last_saved_at from public.memory_nodes where owner_id=${OWNER}::uuid`)[0];
      return {status:'ok',server_version:VERSION,schema_version:info.schema_version,identity:'Matrix owner',permissions:['search','fetch','related','list_recent','remember','status'],...stats};
    });}
  };
}

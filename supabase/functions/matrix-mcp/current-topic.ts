// Topic matching selects evidence; it never declares a new record authoritative.
export type TopicEntity = {id:string;kind:string;canonical_name:string;aliases:string[]};
export type TopicScope = {term:string;entity_ids:string[];basis:'explicit'|'entity_name'|'project_acronym'};
export function normalizeTopic(text:string) {
  return text.normalize('NFKD').replace(/\p{M}/gu,'').toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu,' ').trim().replace(/\s+/g,' ');
}
function contains(text:string,term:string){return (` ${normalizeTopic(text)} `).includes(` ${term} `);}
export function topicScopes(query:string,entities:TopicEntity[],topic?:string):TopicScope[] {
  if(topic){
    const term=normalizeTopic(topic);
    if(!term)return [];
    return [{term,basis:'explicit',entity_ids:entities.filter(e=>
      [e.canonical_name,...(e.aliases||[])].some(n=>contains(n,term))).map(e=>e.id)}];
  }
  const found=new Map<string,TopicScope & {project:boolean}>();
  for(const entity of entities){
    if(!['project','organization','technology','device'].includes(entity.kind))continue;
    for(const name of [entity.canonical_name,...(entity.aliases||[])]){
      const full=normalizeTopic(name);
      const terms:{term:string,basis:TopicScope['basis']}[]=[];
      if(full.length>=3 && full.length<=160 && contains(query,full))terms.push({term:full,basis:'entity_name'});
      // Only registered project acronyms, never arbitrary capitalized query text.
      if(entity.kind==='project')for(const token of name.match(/\b[A-Z][A-Z0-9]{2,11}\b/g)||[]){
        const term=normalizeTopic(token);if(contains(query,term))terms.push({term,basis:'project_acronym'});
      }
      for(const t of terms){
        const prior=found.get(t.term)||{...t,entity_ids:[],project:false};
        prior.project ||= entity.kind==='project';
        if(!prior.entity_ids.includes(entity.id))prior.entity_ids.push(entity.id);
        found.set(t.term,prior);
      }
    }
  }
  let scopes=[...found.values()];
  if(scopes.some(s=>s.project))scopes=scopes.filter(s=>s.project);
  scopes=scopes.filter(s=>!scopes.some(t=>t.term!==s.term && contains(t.term,s.term)));
  // Ambiguous broad requests must be refined rather than silently picking topics.
  if(scopes.length>3)return [];
  return scopes.map(({project:_project,...scope})=>scope).sort((a,b)=>a.term.localeCompare(b.term));
}
export function selectRecentTopics(rows:any[],scopes:TopicScope[],limit:number){
  if(!scopes.length)return [];
  return rows.filter(row=>row.lifecycle_status==='active').flatMap(row=>{
    const matches=scopes.flatMap(scope=>{
      const entityMatch=(row.entity_ids||[]).some((id:string)=>scope.entity_ids.includes(id));
      const titleMatch=contains(row.title,scope.term);
      return entityMatch||titleMatch?[{topic:scope.term,basis:entityMatch?'entity':'title'}]:[];
    });
    return matches.length?[{...row,topic_matches:matches}]:[];
  }).slice(0,limit);
}
export async function resolveWithRecent(search:()=>Promise<any>,load:()=>Promise<any>,enrich:(r:any)=>Promise<any>){
  // A baseline failure must never be masked by unrelated recent records.
  const baseline=await search();
  try {
    const recent=await load();
    const expanded=recent.items.length?await enrich({hits:recent.items,associations:[]}):{hits:[],successor_candidates:[],temporal_truncated:false};
    return {baseline,recent:{...recent,items:expanded.hits,successor_candidates:expanded.successor_candidates,
      temporal_truncated:expanded.temporal_truncated}};
  }catch{
    return {baseline,recent:{status:'unavailable',items:[],successor_candidates:[],coverage:'recent_topic_context_unavailable'}};
  }
}

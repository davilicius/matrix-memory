import {normalizeTopic,topicScopes,selectRecentTopics,resolveWithRecent} from '../supabase/functions/matrix-mcp/current-topic.ts';
import {schemas} from '../supabase/functions/matrix-mcp/core.ts';
const eq=(a:any,b:any)=>{if(JSON.stringify(a)!==JSON.stringify(b))throw new Error(JSON.stringify({a,b}));};
const entities=[
 {id:'a',kind:'project',canonical_name:'Atlas',aliases:['Memoria Átlas']},
 {id:'b',kind:'project',canonical_name:'Proyecto ORION Empresa',aliases:[]},
 {id:'c',kind:'organization',canonical_name:'Empresa',aliases:[]},
];
Deno.test('registered project aliases and acronyms work with Spanish accents and casing',()=>{
 eq(normalizeTopic('MEMORIA Átlas: avances'),'memoria atlas avances');
 eq(topicScopes('Que nos falta en Atlas',entities).map(x=>x.term),['atlas']);
 eq(topicScopes('estado de memoria atlas',entities).map(x=>x.term),['memoria atlas']);
 eq(topicScopes('formulario orion de Empresa',entities).map(x=>x.term),['orion']);
});
Deno.test('short ambiguous prompts and unregistered acronyms do not invent a topic',()=>{
 for(const q of ['que falta','siguiente','ABC noticias','atlasiano'])eq(topicScopes(q,entities),[]);
});
Deno.test('explicit topic is bounded and cannot override identity',()=>{
 eq(schemas.resolve_current.parse({query:'estado',topic:' ORION '}).topic,'ORION');
 for(const extra of [{topic:'x'.repeat(161)},{owner_id:'other'},{limit:16}]){
  if(schemas.resolve_current.safeParse({query:'estado',...extra}).success)throw Error('Invalid request accepted');
 }
 eq(topicScopes('estado',entities,'ORION')[0].entity_ids,['b']);
});
Deno.test('duplicate entity aliases merge and nested names prefer specific scope',()=>{
 const rows=[...entities,{id:'d',kind:'project',canonical_name:'Atlas Memory',aliases:['Atlas']}];
 eq(topicScopes('Atlas',rows)[0].entity_ids,['a','d']);
 eq(topicScopes('Atlas Memory',rows).map(x=>x.term),['atlas memory']);
});
Deno.test('supplement spans episodes and facts and does not confuse title substrings',()=>{
 const scopes=topicScopes('Atlas',entities);
 const rows=[{id:'1',title:'Atlas: nuevo cierre',lifecycle_status:'active',memory_type:'episode',entity_ids:[]},
  {id:'2',title:'Estado anterior',lifecycle_status:'active',memory_type:'fact',entity_ids:['a']},
  {id:'3',title:'Atlasiano',lifecycle_status:'active',entity_ids:[]},
  {id:'4',title:'Atlas: histórico',lifecycle_status:'superseded',entity_ids:['a']}];
 eq(selectRecentTopics(rows,scopes,6).map(x=>x.id),['1','2']);
 eq(selectRecentTopics(rows,scopes,1).map(x=>x.id),['1']);
});
Deno.test('recent evidence is enriched without replacing the baseline',async()=>{
 const baseline={hits:[{id:'old',currentness:'active_candidate'}]};
 const out=await resolveWithRecent(async()=>baseline,async()=>({status:'supplemented',items:[{id:'partial'}]}),async r=>({...r,hits:[{...r.hits[0],currentness:'partially_replaced',replacements:[{id:'new',scope:'partial'}]}],successor_candidates:[{id:'new'}]}));
 eq(out.baseline,baseline);eq(out.recent.items[0].currentness,'partially_replaced');eq(out.recent.successor_candidates,[{id:'new'}]);
});
Deno.test('supplement failure is visible while baseline remains available',async()=>{
 const baseline={hits:[{id:'one'}]};
 const out=await resolveWithRecent(async()=>baseline,async()=>{throw Error('private failure');},async r=>r);
 eq(out.baseline,baseline);eq(out.recent.status,'unavailable');
 if(JSON.stringify(out).includes('private failure'))throw Error('Leaked exception');
});
Deno.test('baseline failure cannot be hidden by recent-topic fallback',async()=>{
 let loaded=false;let failed=false;
 try{await resolveWithRecent(async()=>{throw Error('baseline failed');},async()=>{loaded=true;return {};},async r=>r);}catch{failed=true;}
 eq(failed,true);eq(loaded,false);
});
Deno.test('more than three unrelated projects does not silently select a subset',()=>{
 const e=['Atlas','Orion','Pegasus','Lyra'].map((canonical_name,i)=>({id:String(i),canonical_name,kind:'project',aliases:[]}));
 eq(topicScopes('Atlas Orion Pegasus Lyra',e),[]);
});

// Conservative Spanish spelling evidence. Never rewrite the caller's query or memory.
export const SPELLING_LIMITS = {memories:2000,summary_chars:1000,documents:64,words_per_term:3,terms:4} as const;
export function spellingNormalize(text:string):string {
  // Preserve ñ: año and ano must not become the same word.
  return text.normalize('NFC').toLowerCase().replace(/[áéíóúü]/g,c=>({'á':'a','é':'e','í':'i','ó':'o','ú':'u','ü':'u'}[c]!));
}
const stop=new Set('a al algo algun alguna algunas algunos ante con cual cuales cuando de del desde donde el ella ellas ellos en entre era es esa esas ese esos esta estas este estos esto fue ha hay la las le les lo los me mi mis para por que quien se su sus te tiene tu tus un una unas unos y ya recuerdo recuerdas recuerdame recuerda busca buscar buscame dime muestra muestrame informacion sobre'.split(' '));
export function spellingTerms(query:string):{terms:string[];reason?:string} {
  const text=spellingNormalize(query.trim());
  // Quoted/Boolean queries, codes, URLs, email, IPs and mixed identifiers stay literal.
  if(!text || text.length>160 || !/^[a-zñ\s¿?¡!]+$/.test(text))return {terms:[],reason:'protected_or_complex_query'};
  const all=text.match(/[a-zñ]+/g)||[];
  if(all.some(w=>['no','sin','excepto','menos','not','or','o'].includes(w)))return {terms:[],reason:'negation_or_operator'};
  const terms=[...new Set(all.filter(w=>!stop.has(w)))];
  // Short words and abbreviations are too ambiguous to alter safely.
  if(!terms.length || terms.length>SPELLING_LIMITS.terms || terms.some(w=>w.length<5||w.length>32))return {terms:[],reason:'unsupported_term_length_or_count'};
  if((query.match(/[A-ZÁÉÍÓÚÜÑ]{2,}/g)||[]).some(w=>w===w.toUpperCase()))return {terms:[],reason:'uppercase_identifier'};
  return {terms};
}
// Optimal string alignment distance includes a single adjacent transposition.
export function spellingDistance(a:string,b:string):number {
  const d=Array.from({length:a.length+1},()=>Array<number>(b.length+1).fill(0));
  for(let i=0;i<=a.length;i++)d[i][0]=i;
  for(let j=0;j<=b.length;j++)d[0][j]=j;
  for(let i=1;i<=a.length;i++)for(let j=1;j<=b.length;j++){
    d[i][j]=Math.min(d[i-1][j]+1,d[i][j-1]+1,d[i-1][j-1]+Number(a[i-1]!==b[j-1]));
    if(i>1&&j>1&&a[i-1]===b[j-2]&&a[i-2]===b[j-1])d[i][j]=Math.min(d[i][j],d[i-2][j-2]+1);
  }
  return d[a.length][b.length];
}
export type SpellingRow={id:string;title:string;matches:{term:string;words:{word:string;trigram:number}[]}[]};
export function selectSpelling(rows:SpellingRow[],terms:string[],limit:number){
  return rows.flatMap(row=>{
    const matches=terms.map(term=>{
      const words=row.matches.find(m=>m.term===term)?.words||[];
      return words.map(w=>({...w,distance:spellingDistance(term,w.word)}))
        .filter(w=>w.trigram>=0.45&&w.distance<=(term.length>=9?2:1)&&w.distance/Math.max(term.length,w.word.length)<=0.2)
        .sort((a,b)=>a.distance-b.distance||b.trigram-a.trigram||a.word.localeCompare(b.word))[0];
    });
    if(matches.some(m=>!m))return [];
    const changes=matches.flatMap((m,i)=>m!.distance?[{input:terms[i],matched:m!.word,edits:m!.distance}]:[]);
    // Exact documents are already handled by the normal search; do not fabricate corrections.
    if(changes.length!==1)return [];
    const titleWords=new Set(spellingNormalize(row.title).match(/[a-zñ]+/g)||[]);
    const titleHits=matches.filter(m=>titleWords.has(m!.word)).length;
    const evidence={kind:'approximate_spelling',changes,matched_terms:matches.map(m=>m!.word),requires_source_review:true};
    return [{id:row.id,title:row.title,spelling_match:evidence,_title:titleHits,_distance:changes[0].edits,_similarity:Math.min(...matches.map(m=>m!.trigram))}];
  }).sort((a,b)=>a._distance-b._distance||b._title-a._title||b._similarity-a._similarity||a.id.localeCompare(b.id))
    .slice(0,Math.min(limit,6)).map(({_title,_distance,_similarity,...row})=>row);
}
export async function addSpelling(baseline:any,query:string,load:(terms:string[])=>Promise<any>,enrich:(r:any)=>Promise<any>){
  const plan=spellingTerms(query);
  if(!plan.terms.length)return {...baseline,spelling_candidates:[],spelling_context:{status:'skipped',reason:plan.reason}};
  try{
    const loaded=await load(plan.terms);
    const enriched=loaded.items.length?await enrich({hits:loaded.items,associations:[]}):{hits:[],successor_candidates:[],temporal_truncated:false};
    return {...baseline,spelling_candidates:enriched.hits,spelling_successor_candidates:enriched.successor_candidates||[],
      spelling_context:{...loaded.context,status:enriched.hits.length?'supplemented':'no_close_match',temporal_truncated:enriched.temporal_truncated,
        coverage:'bounded_spelling_evidence_not_a_query_rewrite'}};
  }catch{
    return {...baseline,spelling_candidates:[],spelling_context:{status:'unavailable',coverage:'baseline_preserved'}};
  }
}

import {spellingTerms,spellingNormalize,spellingDistance,selectSpelling,addSpelling,type SpellingRow} from '../supabase/functions/matrix-mcp/spelling.ts';
const eq=(a:unknown,b:unknown)=>{if(JSON.stringify(a)!==JSON.stringify(b))throw Error(JSON.stringify({actual:a,expected:b}));};
function row(id:string,title:string,pairs:[string,string,number][]):SpellingRow {
  return {id,title,matches:pairs.map(([term,word,trigram])=>({term,words:[{word,trigram}]}))};
}
Deno.test('Spanish normalization tolerates accents and preserves ñ',()=>{
  eq(spellingNormalize('ÁRBOL, Pingüino, AÑO'),'arbol, pinguino, año');
  eq(spellingNormalize('A\u0301RBOL'),'arbol');
  eq(spellingTerms('¿Recuerdas mi xoconstle?').terms,['xoconstle']);
});
Deno.test('IDs, IPs, accounts, URLs, email, operators and short ambiguous terms stay literal',()=>{
  for(const q of ['10.0.0.21','2001:1248::2','220836290011','R21','UUID ABCDEF','RFC ABC','ABCDEF','persona@example.com','https://example.com','"xoconstle"','-xoconstle','salsa sin pasilla','salsa OR pasilla','no pasilla','salsa/pasilla','IPv6 Alestra','casa','salsa RFC','xoconstle 123']){
    eq(spellingTerms(q).terms,[]);
  }
});
Deno.test('query bounds are enforced before database access',()=>{
  for(const q of ['x'.repeat(161),'x'.repeat(33),'primero segundo tercero cuarto quinto','que me'])eq(spellingTerms(q).terms,[]);
  eq(spellingTerms('receta pasila').terms,['receta','pasila']);
});
Deno.test('adjacent swaps, missing letters and extra letters are supported',()=>{
  eq(spellingDistance('tomtae','tomate'),1);
  eq(spellingDistance('pasila','pasilla'),1);
  eq(spellingDistance('pasillla','pasilla'),1);
  eq(spellingDistance('xoconstle','xoconostle'),1);
  eq(spellingDistance('sal','vehiculo'),7);
});
Deno.test('a typo can recover an old recipe even when a later test note repeats the typo exactly',()=>{
  const result=selectSpelling([
    row('test','Prueba del buscador',[['xoconstle','xoconstle',1]]),
    row('recipe','Receta de xoconostle',[['xoconstle','xoconostle',0.615]])
  ],['xoconstle'],6);
  eq(result.map(r=>r.id),['recipe']);
  eq(result[0].spelling_match.changes,[{input:'xoconstle',matched:'xoconostle',edits:1}]);
});
Deno.test('all meaningful query terms must match and at most one may change',()=>{
  const rows=[row('good','Receta pasilla',[['receta','receta',1],['pasila','pasilla',0.6]]),
    row('missing','Pasilla',[['pasila','pasilla',0.6]]),
    row('both','Recetas pasilla',[['receta','recetas',0.7],['pasila','pasilla',0.6]])];
  eq(selectSpelling(rows,['receta','pasila'],6).map(r=>r.id),['good']);
});
Deno.test('exact words are preferred over similar alternatives in the same document',()=>{
  const r=row('1','Documento',[['pasila','pasilla',0.6]]);
  r.matches[0].words.push({word:'pasila',trigram:1});
  eq(selectSpelling([r],['pasila'],6),[]);
});
Deno.test('weak or excessive edits are rejected even with a high trigram score',()=>{
  eq(selectSpelling([row('1','Texto',[['pasila','pasillo',0.8]])],['pasila'],6),[]);
  eq(selectSpelling([row('1','Texto',[['pasila','pasilla',0.3]])],['pasila'],6),[]);
});
Deno.test('ranking is bounded and deterministic; title matches precede body mentions',()=>{
  const rows=[row('b','Otro título',[['pasila','pasilla',0.7]]),row('a','Pasilla',[['pasila','pasilla',0.7]])];
  eq(selectSpelling(rows,['pasila'],1).map(r=>r.id),['a']);
  eq(selectSpelling(rows,['pasila'],6).map(r=>r.id),['a','b']);
});
Deno.test('baseline and caller query remain intact; source and partial replacement evidence survives',async()=>{
  const baseline={hits:[{id:'exact'}],query:'pasila',history_id:'base',mode:'hybrid'};
  const result=await addSpelling(baseline,'pasila',async()=>({items:[{id:'candidate',spelling_match:{changes:[]}}],context:{pool_truncated:true}}),async r=>({...r,hits:[{...r.hits[0],source:{title:'Original'},currentness:'partially_replaced'}],successor_candidates:[{id:'next'}]}));
  eq(result.hits,baseline.hits);eq(result.query,'pasila');eq(result.history_id,'base');eq(result.mode,'hybrid');
  eq(result.spelling_context.status,'supplemented');eq(result.spelling_candidates[0].currentness,'partially_replaced');
  eq(result.spelling_successor_candidates,[{id:'next'}]);
});
Deno.test('timeout or supplemental failures preserve baseline and expose no raw error',async()=>{
  const baseline={hits:[{id:'a'}]};
  for(const enrichFails of [false,true]){
    const result=await addSpelling(baseline,'pasila',async()=>{if(!enrichFails)throw Error('PRIVATE SQL');return {items:[{id:'a'}],context:{}};},async()=>{throw Error('PRIVATE SQL');});
    eq(result.hits,baseline.hits);eq(result.spelling_context.status,'unavailable');
    if(JSON.stringify(result).includes('PRIVATE'))throw Error('leaked error');
  }
});
Deno.test('protected query never invokes the spelling database loader',async()=>{
  let called=false;
  const r=await addSpelling({hits:[]},'10.0.0.21',async()=>{called=true;return {};},async r=>r);
  eq(called,false);eq(r.spelling_context.status,'skipped');
});

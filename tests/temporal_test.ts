import {annotateMemory,qualityWarnings,currentContext} from '../supabase/functions/matrix-mcp/temporal.ts';
function equal(a:unknown,b:unknown){if(JSON.stringify(a)!==JSON.stringify(b))throw Error(JSON.stringify({a,b}));}
Deno.test('temporal classification preserves partial replacements and unknown dates',()=>{
 const base={id:'old',lifecycle_status:'active',created_at:'2026-01-01',occurred_at:null};
 equal(annotateMemory(base).currentness,'active_candidate');
 equal(annotateMemory(base).event_date_known,false);
 equal(annotateMemory({...base,replacements:[{scope:'partial'}]}).currentness,'partially_replaced');
 equal(annotateMemory({...base,replacements:[{scope:'full'}]}).currentness,'superseded');
 equal(annotateMemory({...base,replacements:[{scope:'unreviewed'}]}).currentness,'replacement_scope_unreviewed');
 equal(annotateMemory({...base,valid_to:'2025-01-01'}).currentness,'expired');
 equal(annotateMemory({...base,valid_from:'2999-01-01'}).currentness,'not_yet_valid');
 equal(annotateMemory({...base,lifecycle_status:'archived'}).currentness,'archived');
});
Deno.test('current context promotes successor, preserves history, partial scope and conflicts',()=>{
 const r=currentContext({hits:[{id:'a',currentness:'superseded'},{id:'p',currentness:'partially_replaced'}],successor_candidates:[{id:'b',currentness:'active_candidate',contradictions:['c']},{id:'b',currentness:'active_candidate'}]});
 equal(r.current_candidates.map((x:any)=>x.id),['b']);equal(r.historical_candidates.map((x:any)=>x.id),['a']);equal(r.needs_review.map((x:any)=>x.id),['p']);equal(r.conflicts.length,1);
});
Deno.test('quality checks do not manufacture event date or rewrite user content',()=>{
 const p={content:'Known fact',importance:50};const before=JSON.stringify(p);
 equal(qualityWarnings(p),['missing_summary','event_date_unknown_do_not_invent','no_entities_check_project_or_topic']);equal(JSON.stringify(p),before);
 equal(qualityWarnings({...p,summary:'Summary',occurred_at:'2026-01-01',entities:[{name:'Project'}]}),[]);
});

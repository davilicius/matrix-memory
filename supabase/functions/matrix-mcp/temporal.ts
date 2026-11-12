// Temporal labels are evidence, not a guarantee that the external world is current.
export function annotateMemory(row:any, now=Date.now()) {
  let currentness = 'active_candidate';
  if (row.lifecycle_status !== 'active') currentness = row.lifecycle_status || 'unknown';
  else if (row.valid_from && Date.parse(row.valid_from)>now) currentness='not_yet_valid';
  else if (row.valid_to && Date.parse(row.valid_to)<=now) currentness='expired';
  else if (row.replacements?.some((r:any)=>r.scope==='full')) currentness='superseded';
  else if (row.replacements?.some((r:any)=>r.scope==='partial')) currentness='partially_replaced';
  else if (row.replacements?.length) currentness='replacement_scope_unreviewed';
  return {...row,currentness,date_basis:row.occurred_at?'occurred_at':'created_at',event_date_known:!!row.occurred_at};
}
export function qualityWarnings(args:any) {
  const warnings:string[]=[];
  if (!args.summary?.trim()) warnings.push('missing_summary');
  if (!args.occurred_at) warnings.push('event_date_unknown_do_not_invent');
  if (!args.entities?.length) warnings.push('no_entities_check_project_or_topic');
  if (args.content.length>8000) warnings.push('long_memory_consider_atomic_notes');
  if (args.importance>=90) warnings.push('high_importance_reserve_for_critical_facts');
  return warnings;
}
export function currentContext(result:any) {
  const rows=[...result.hits,...(result.successor_candidates||[])];
  const seen=new Set<string>();
  const unique=rows.filter((r:any)=>{const id=r.id||r.node_id;if(seen.has(id))return false;seen.add(id);return true;});
  const active=unique.filter((r:any)=>r.currentness==='active_candidate');
  const needsReview=unique.filter((r:any)=>['partially_replaced','replacement_scope_unreviewed','unknown'].includes(r.currentness));
  return {history_id:result.history_id,mode:result.mode,current_candidates:active,needs_review:needsReview,historical_candidates:unique.filter((r:any)=>!active.includes(r)&&!needsReview.includes(r)),conflicts:unique.filter((r:any)=>r.contradictions?.length).map((r:any)=>({id:r.id||r.node_id,contradictions:r.contradictions})),coverage:'bounded_retrieval_not_complete_project_inventory',notice:'Candidatos según la evidencia recuperada. Revisar alcance parcial, fechas y contradicciones; no confundir fecha de guardado con fecha del hecho.',temporal_truncated:result.temporal_truncated};
}

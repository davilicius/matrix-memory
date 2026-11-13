import { operations } from './telemetry.ts';

export type OAuthIdentity = {clientId:string; sessionId:string};
export const appRoles = ['reader','writer','manager'] as const;
export type AppRole = typeof appRoles[number];
export type AppAuthorizer = (identity:OAuthIdentity)=>Promise<AppRole|null>;
export function permittedOperations(role:AppRole):string[] {
  return operations.filter(name=>name==='supersede'?role==='manager':name==='remember'?role!=='reader':true);
}
export function permittedCall(role:AppRole,name:string,args:unknown):boolean {
  if(!permittedOperations(role).includes(name))return false;
  // A writer must not smuggle a replacement edge through ordinary remember.
  if(name==='remember'&&role!=='manager'){
    const relations=(args as any)?.relations;
    if(Array.isArray(relations)&&relations.some(r=>r?.type==='supersedes'))return false;
    if(Object.hasOwn((args as any)?.metadata??{},'_matrix_supersession'))return false;
  }
  return true;
}

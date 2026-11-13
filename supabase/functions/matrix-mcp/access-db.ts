import postgres from 'postgres';
import { appRoles, type AppAuthorizer } from './access.ts';

// Only invoked after Auth has verified the bearer token. No JWT, client ID,
// session ID or private grant label is copied into operation logs.
export function makeAppAuthorizer(databaseUrl:string,ownerId:string):AppAuthorizer {
  const sql=postgres(databaseUrl,{prepare:false,max:1,idle_timeout:10,connect_timeout:10,max_lifetime:60});
  return async(identity)=>{
    const rows=await sql.begin(async(q:any)=>{
      await q`select set_config('statement_timeout','5000',true)`;
      return await q`select matrix_private.application_role(${ownerId}::uuid,${identity.clientId}::uuid,${identity.sessionId}::uuid) app_role`;
    });
    const role=rows[0]?.app_role;
    return appRoles.includes(role)?role:null;
  };
}

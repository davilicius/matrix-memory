import type { AuthFailure } from './telemetry.ts';
// Decode only for constraints; /auth/v1/user verifies signature and session.
export function makeOAuthVerifier(url:string,apiKey:string,ownerId:string,fetcher:typeof fetch=fetch) {
  const OWNER = ownerId;
  return async(token:string,report?:(reason:AuthFailure)=>void):Promise<boolean>=>{
    let claims:any;
    try {
      const parts=token.split('.'); if(parts.length!==3)return false;
      claims=JSON.parse(atob(parts[1].replace(/-/g,'+').replace(/_/g,'/')));
      if(claims.sub!==OWNER || claims.iss!==url+'/auth/v1' || claims.role!=='authenticated' || claims.aud!=='authenticated' || typeof claims.client_id!=='string' || !claims.client_id || typeof claims.session_id!=='string' || typeof claims.exp!=='number' || claims.exp<=Date.now()/1000)return false;
    } catch {report?.('AUTH_INVALID');return false;}
    try {
      const response=await fetcher(url+'/auth/v1/user',{headers:{apikey:apiKey,Authorization:'Bearer '+token},signal:AbortSignal.timeout(8000)});
      if(!response.ok){report?.(response.status>=500||response.status===429?'AUTH_UNAVAILABLE':'AUTH_INVALID');return false;}
      const user=await response.json();
      return user.id===OWNER && !user.is_anonymous;
    } catch {report?.('AUTH_UNAVAILABLE');return false;}
  };
}

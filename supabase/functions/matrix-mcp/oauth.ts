// Decode only for constraints; /auth/v1/user verifies signature and session.
export function makeOAuthVerifier(url:string,apiKey:string,ownerId:string,fetcher:typeof fetch=fetch) {
  const OWNER = ownerId;
  return async(token:string):Promise<boolean>=>{
    try {
      const parts=token.split('.'); if(parts.length!==3)return false;
      const claims=JSON.parse(atob(parts[1].replace(/-/g,'+').replace(/_/g,'/')));
      if(claims.sub!==OWNER || claims.iss!==url+'/auth/v1' || claims.role!=='authenticated' || claims.aud!=='authenticated' || typeof claims.client_id!=='string' || !claims.client_id || typeof claims.session_id!=='string' || typeof claims.exp!=='number' || claims.exp<=Date.now()/1000)return false;
      const response=await fetcher(url+'/auth/v1/user',{headers:{apikey:apiKey,Authorization:'Bearer '+token},signal:AbortSignal.timeout(8000)});
      if(!response.ok)return false;
      const user=await response.json();
      return user.id===OWNER && !user.is_anonymous;
    } catch {return false;}
  };
}

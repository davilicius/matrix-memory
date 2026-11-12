// This deployment serves exactly one owner. Never take an owner from tool input.
export function readConfig(get: (name: string) => string | undefined) {
  function required(name: string): string {
    const value = get(name)?.trim();
    if (!value) throw new Error(name + ' is required');
    return value;
  }
  const ownerId = required('MATRIX_OWNER_ID');
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(ownerId)) {
    throw new Error('MATRIX_OWNER_ID must be a UUID');
  }
  const url = required('SUPABASE_URL').replace(/\/+$/, '');
  const parsed = new URL(url);
  if (!['https:', 'http:'].includes(parsed.protocol) || parsed.pathname !== '/' || parsed.search || parsed.hash || parsed.username || parsed.password) {
    throw new Error('SUPABASE_URL must be an HTTP(S) origin');
  }
  return { ownerId, url, anonKey: required('SUPABASE_ANON_KEY'), databaseUrl: required('SUPABASE_DB_URL') };
}

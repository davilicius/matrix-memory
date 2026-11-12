import { makeHandler } from './core.ts';
import { makeBackend } from './db.ts';
import { makeOAuthVerifier } from './oauth.ts';
import { readConfig } from './config.ts';

const config = readConfig((name) => Deno.env.get(name));
const db = makeBackend(config.databaseUrl, config.ownerId);
// The gateway is disabled only for this function; Auth verifies every OAuth token.
// Ordinary password sessions and raw API keys are rejected.
Deno.serve(makeHandler(
  db,
  makeOAuthVerifier(config.url, config.anonKey, config.ownerId),
  config.url + '/functions/v1/matrix-mcp',
));

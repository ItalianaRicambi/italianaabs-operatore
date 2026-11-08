import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from 'jose';
export type DiscoveryMcpFic = { resource: string; issuer: string; jwks: string };
export type ConfigMcpFic = DiscoveryMcpFic & { clientId: string; users: string[] };
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
export function discoveryMcpFic(env: Record<string,string|undefined> = process.env): DiscoveryMcpFic | null {
  try {
    const resource = new URL(env.FIC_MCP_RESOURCE_URL || '');
    const issuer = new URL(env.FIC_MCP_ISSUER || '');
    const jwks = new URL(env.FIC_MCP_JWKS_URL || '');
    if ([resource,issuer,jwks].some(u=>u.protocol!=='https:' || !!u.username || !!u.password || !!u.search || !!u.hash)
      || resource.pathname!=='/mcp' || issuer.origin!==jwks.origin) return null;
    return {resource:resource.href,issuer:issuer.href,jwks:jwks.href};
  } catch { return null; }
}
export function configMcpFic(env: Record<string,string|undefined> = process.env): ConfigMcpFic | null {
  const discovery=discoveryMcpFic(env);
  const users=(env.FIC_MCP_USER_IDS||'').split(',').map(x=>x.trim()).filter(Boolean);
  const clientId=env.FIC_MCP_CLIENT_ID||'';
  if(!discovery || !clientId || !users.length || !users.every(u=>uuid.test(u))) return null;
  return {...discovery,users,clientId};
}
const keys = new Map<string, ReturnType<typeof createRemoteJWKSet>>();
export async function autorizzaMcpFic(token: string, config: ConfigMcpFic, getKey?: JWTVerifyGetKey) {
  if (!token || token.length>16000) throw new Error('Unauthorized');
  if (!getKey && !keys.has(config.jwks)) keys.set(config.jwks, createRemoteJWKSet(new URL(config.jwks),{timeoutDuration:5000}));
  const {payload} = await jwtVerify(token, getKey || keys.get(config.jwks)!, {
    issuer:config.issuer, audience:config.resource, algorithms:['RS256','ES256'],
    requiredClaims:['exp','iat','sub','client_id'], maxTokenAge:'65m', clockTolerance:5 });
  if (typeof payload.sub!=='string' || !config.users.includes(payload.sub) || payload.client_id!==config.clientId
    || typeof payload.scope!=='string' || !payload.scope.split(' ').includes('email')) throw new Error('Unauthorized');
  return payload.sub;
}
export function metadataMcpFic(c: DiscoveryMcpFic) {
  return { resource:c.resource, authorization_servers:[c.issuer], scopes_supported:['email'],
    bearer_methods_supported:['header'], resource_name:'Italiana Ricambi — Fatture in Cloud (sola lettura)' };
}
export function challengeMcpFic(c: DiscoveryMcpFic) {
  const metadata = new URL('/.well-known/oauth-protected-resource/mcp',c.resource).href;
  return `Bearer resource_metadata="${metadata}", scope="email"`;
}

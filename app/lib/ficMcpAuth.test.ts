import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPair, SignJWT } from 'jose';
import { autorizzaMcpFic, configMcpFic, metadataMcpFic } from './ficMcpAuth.ts';
const user='11111111-1111-4111-8111-111111111111';
const c={resource:'https://example.com/mcp',issuer:'https://auth.example.com/auth/v1',jwks:'https://auth.example.com/auth/v1/.well-known/jwks.json',clientId:'chatgpt-test',users:[user]};
test('OAuth accetta solo firma, destinatario, client, identità e scope autorizzati',async()=>{
  const {privateKey,publicKey}=await generateKeyPair('ES256');
  const claims={iss:c.issuer,aud:c.resource,sub:user,client_id:c.clientId,scope:'email',iat:Math.floor(Date.now()/1000),exp:Math.floor(Date.now()/1000)+3600};
  const sign=(extra:Record<string,unknown>={})=>new SignJWT({...claims,...extra}).setProtectedHeader({alg:'ES256'}).sign(privateKey);
  assert.equal(await autorizzaMcpFic(await sign(),c,async()=>publicKey),user);
  for(const extra of [{aud:'authenticated'},{iss:'https://other.example.com'},{sub:'22222222-2222-4222-8222-222222222222'},
    {client_id:'other-client'},{scope:'profile'},{exp:1},{iat:1},{exp:undefined}]) {
    await assert.rejects(autorizzaMcpFic(await sign(extra),c,async()=>publicKey));
  }
  const wrong=await generateKeyPair('ES256');
  await assert.rejects(autorizzaMcpFic(await sign(),c,async()=>wrong.publicKey));
  await assert.rejects(autorizzaMcpFic('not-a-jwt',c,async()=>publicKey));
});
test('configurazione OAuth incompleta o insicura rimane chiusa',()=>{
  assert.equal(configMcpFic({}),null);
  const env={FIC_MCP_RESOURCE_URL:c.resource,FIC_MCP_ISSUER:c.issuer,FIC_MCP_JWKS_URL:c.jwks,FIC_MCP_CLIENT_ID:c.clientId,FIC_MCP_USER_IDS:user};
  assert.deepEqual(configMcpFic(env),c);
  for(const extra of [{FIC_MCP_RESOURCE_URL:'http://example.com/mcp'},{FIC_MCP_USER_IDS:'*'},
    {FIC_MCP_JWKS_URL:'https://attacker.example.com/jwks'},{FIC_MCP_RESOURCE_URL:'https://example.com/mcp?secret=x'}])
    assert.equal(configMcpFic({...env,...extra}),null);
  assert.deepEqual(metadataMcpFic(c).authorization_servers,[c.issuer]);
});

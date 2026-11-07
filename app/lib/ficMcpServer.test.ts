import test from 'node:test';
import assert from 'node:assert/strict';
import { WebStandardStreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js';
import { creaServerMcpFic } from './ficMcpServer.ts';
import { ErroreFic, type creaClientFic } from './fattureInCloud.ts';
test('protocollo MCP: strumenti di sola lettura e errori espliciti',async()=>{
  let chiamate=0;
  const client={verifica:async()=>({id:'29153',nome:'test',partitaIva:'02439670031'}),
    cerca:async()=>{chiamate++;throw new ErroreFic('autorizzazione');},leggi:async()=>{throw new ErroreFic('risposta');}} as ReturnType<typeof creaClientFic>;
  async function rpc(method:string,params:unknown={}) {
    const server=creaServerMcpFic(client);
    const t=new WebStandardStreamableHTTPServerTransport({sessionIdGenerator:undefined,enableJsonResponse:true});
    await server.connect(t);
    const r=await t.handleRequest(new Request('https://test.example/mcp',{method:'POST',headers:{'Content-Type':'application/json',Accept:'application/json, text/event-stream','MCP-Protocol-Version':'2025-03-26'},body:JSON.stringify({jsonrpc:'2.0',id:1,method,params})}));
    await server.close(); return r.json();
  }
  const init=await rpc('initialize',{protocolVersion:'2025-03-26',capabilities:{},clientInfo:{name:'test',version:'1'}});
  assert.equal(init.result.serverInfo.name,'italiana-ricambi-fatture');
  const lista=await rpc('tools/list');
  assert.deepEqual(lista.result.tools.map((t:{name:string})=>t.name),['fic_cerca_documenti','fic_leggi_documento']);
  assert.ok(lista.result.tools.every((t:{annotations:{readOnlyHint:boolean}})=>t.annotations.readOnlyHint));
  const result=await rpc('tools/call',{name:'fic_cerca_documenti',arguments:{tipo:'invoice',dal:'2026-11-01',al:'2026-11-07'}});
  assert.equal(result.result.isError,true); assert.match(result.result.content[0].text,/Token non valido/); assert.equal(chiamate,1);
});

// Isolated server tests: only synthetic credentials/data, every HTTP request mocked.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url), ts=require('typescript');
const root=path.resolve(import.meta.dirname,'..');
function loader(){
 const cache=new Map();
 function load(file){
  file=path.resolve(root,file);if(cache.has(file))return cache.get(file);
  const exports={};cache.set(file,exports);
  const code=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2022}}).outputText;
  const req=name=>name==='server-only'?{}:name.endsWith('/glsServer')?{connessioneGlsDb:()=>({url:'https://db.test',headers:{}})}:
   name.startsWith('.')?load(path.resolve(path.dirname(file),name)+(name.endsWith('.ts')?'':'.ts')):require(name);
  new Function('require','exports','module',code)(req,exports,{exports});return exports;
 }
 return load;
}
const originalFetch=globalThis.fetch;
const fixture={admin_graphql_api_id:'gid://shopify/Order/123',name:'#TEST',updated_at:'2026-11-16T10:00:00Z',test:true,cancelled_at:null,
 financial_status:'PAID',fulfillment_status:'UNFULFILLED',currency:'EUR',tax_exempt:false,
 currentTotalPriceSet:{shopMoney:{amount:'1.00'}},currentTotalTaxSet:{shopMoney:{amount:'0.18'}},
 line_items:{nodes:[{title:'Collaudo',variant_title:'RI',quantity:1}],pageInfo:{hasNextPage:false,endCursor:null}}};
async function scenario({scope='read_orders',tokenStatus=200,pages=[],lease='lease',graphqlStatus=200,missing=false}={}){
 const saved={...process.env};const calls=[];let page=0;
 process.env.SHOPIFY_CLIENT_ID='synthetic-id';process.env.SHOPIFY_CLIENT_SECRET='synthetic-secret';
 if(missing)delete process.env.SHOPIFY_CLIENT_SECRET;
 globalThis.fetch=async(url,options)=>{
  const body=options.body instanceof URLSearchParams?Object.fromEntries(options.body):JSON.parse(options.body);calls.push({url,body});
  if(url.endsWith('inizia_sync_shopify'))return Response.json(lease);
  if(url.endsWith('/admin/oauth/access_token'))return Response.json({access_token:'synthetic-token',expires_in:86399,scope},{status:tokenStatus});
  if(url.endsWith('/graphql.json')){assert.ok(!body.query.includes('mutation'));assert.equal(options.redirect,'error');return Response.json(pages[page++]??{data:{orders:{nodes:[],pageInfo:{hasNextPage:false,endCursor:null}}}},{status:graphqlStatus});}
  if(url.endsWith('registra_snapshot_shopify')||url.endsWith('termina_sync_shopify'))return Response.json(true);
  throw Error('Unexpected HTTP request');
 };
 try {return {result:await loader()('app/lib/shopifySyncServer.ts').sincronizzaShopify(),calls};}
 finally {globalThis.fetch=originalFetch;for(const key of ['SHOPIFY_CLIENT_ID','SHOPIFY_CLIENT_SECRET']){if(saved[key]===undefined)delete process.env[key];else process.env[key]=saved[key];}}
}
test('lease prevents duplicate run without Shopify access',async()=>{const s=await scenario({lease:null});assert.equal(s.calls.length,1);assert.equal(s.result.esito,'gia_in_corso');});
test('missing credentials fails visibly without authentication',async()=>{const s=await scenario({missing:true});assert.equal(s.result.ok,false);assert.equal(s.calls.length,2);});
test('invalid credentials and extra write scopes fail closed',async()=>{for(const options of [{tokenStatus:401},{scope:'read_orders,write_orders'},{scope:'read_products'}]){const s=await scenario(options);assert.equal(s.result.ok,false);assert.ok(!s.calls.some(c=>c.url.endsWith('/graphql.json')));assert.ok(s.calls.at(-1).body.p_errore);}});
test('GraphQL errors and HTTP throttling are never successful scans',async()=>{for(const options of [{pages:[{errors:[{message:'upstream-private-data'}]}]},{graphqlStatus:429}]){const s=await scenario(options);assert.equal(s.result.ok,false);assert.ok(!JSON.stringify(s.result).includes('upstream-private-data'));}});
test('all pages read, normalized snapshots, success only at end',async()=>{
 const pages=[{data:{orders:{nodes:[fixture],pageInfo:{hasNextPage:true,endCursor:'next'}}}},{data:{orders:{nodes:[{...fixture,admin_graphql_api_id:'gid://shopify/Order/456'}],pageInfo:{hasNextPage:false,endCursor:null}}}}];
 const s=await scenario({pages});assert.equal(s.result.ordini,2);assert.equal(s.calls.at(-1).body.p_errore,null);
 assert.equal(s.calls.filter(c=>c.url.endsWith('/graphql.json'))[1].body.variables.after,'next');
 assert.deepEqual(s.calls.filter(c=>c.url.endsWith('registra_snapshot_shopify')).map(c=>c.body.p_dati.ordine_id),['123','456']);
});
test('incomplete pagination or lines does not mark success',async()=>{
 for(const orders of [{nodes:[],pageInfo:{hasNextPage:true,endCursor:null}},{nodes:[{...fixture,line_items:{...fixture.line_items,pageInfo:{hasNextPage:true,endCursor:'more'}}}],pageInfo:{hasNextPage:false,endCursor:null}}]){
  const s=await scenario({pages:[{data:{orders}}]});assert.equal(s.result.ok,false);assert.ok(s.calls.at(-1).body.p_errore);
 }
});
test('cron endpoint rejects unauthenticated requests before database access',async()=>{
 const saved=process.env.CRON_SECRET;process.env.CRON_SECRET='x'.repeat(64);
 try{const route=loader()('app/api/cron/shopify/route.ts');assert.equal((await route.GET(new Request('https://test/api/cron/shopify'))).status,401);assert.equal((await route.GET(new Request('https://test/api/cron/shopify',{headers:{authorization:'Bearer wrong'}}))).status,401);}
 finally{if(saved===undefined)delete process.env.CRON_SECRET;else process.env.CRON_SECRET=saved;}
});

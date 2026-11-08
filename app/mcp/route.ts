import { WebStandardStreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js';
import { clientFic } from '../lib/fattureInCloudServer';
import { discoveryMcpFic, configMcpFic, autorizzaMcpFic, challengeMcpFic } from '../lib/ficMcpAuth';
import { creaServerMcpFic } from '../lib/ficMcpServer';
import { quotaMcpFic } from '../lib/ficRegistroServer';
export const dynamic='force-dynamic';
export const runtime='nodejs';
export const maxDuration=60;
const headers={'Cache-Control':'private, no-store','X-Content-Type-Options':'nosniff'};
async function gestisci(req: Request) {
  const c=configMcpFic();
  if(!c) {
    const d=discoveryMcpFic();
    // Discovery pubblica per registrare il client; nessun token è accettato finché manca l'allowlist.
    return Response.json({errore:'Collegamento ChatGPT in configurazione.'},{status:d?401:503,
      headers:d?{...headers,'WWW-Authenticate':challengeMcpFic(d)}:headers});
  }
  if(req.headers.get('origin') && req.headers.get('origin')!==new URL(c.resource).origin)
    return Response.json({errore:'Origin non autorizzata.'},{status:403,headers});
  let userId:string|null=null;
  try { const auth=req.headers.get('authorization')||''; if(!/^Bearer /i.test(auth)) throw new Error();
    userId=await autorizzaMcpFic(auth.slice(7),c);
  } catch { /* Public protocol discovery; tool calls return an OAuth challenge. */ }
  if(!userId && req.method!=='POST')
    return Response.json({errore:'Autenticazione richiesta.'},{status:401,headers:{...headers,'WWW-Authenticate':challengeMcpFic(c)}});
  try {
    if(userId && !await quotaMcpFic(userId)) return Response.json({errore:'Limite richieste raggiunto.'},{status:429,headers:{...headers,'Retry-After':'60'}});
    // Anonymous discovery never creates a Fatture in Cloud client or reads its data.
    const server=creaServerMcpFic(userId?clientFic():null,challengeMcpFic(c));
    const transport=new WebStandardStreamableHTTPServerTransport({sessionIdGenerator:undefined,enableJsonResponse:true,maxRequestBodySize:16000});
    await server.connect(transport);
    try {const response=await transport.handleRequest(req); response.headers.set('Cache-Control','private, no-store'); return response;}
    finally {await server.close();}
  } catch {return Response.json({errore:'Servizio temporaneamente non disponibile.'},{status:503,headers});}
}
export const POST=gestisci;
export const GET=gestisci;
export const DELETE=gestisci;

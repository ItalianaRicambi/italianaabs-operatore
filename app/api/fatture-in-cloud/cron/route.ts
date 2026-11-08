import { timingSafeEqual } from 'node:crypto';
import { sincronizzaFic } from '../../../lib/ficRegistroServer';
import { TIPI_FIC, type TipoFic } from '../../../lib/fattureInCloud';
export const dynamic='force-dynamic';
export const runtime='nodejs';
export const maxDuration=300;
const headers={'Cache-Control':'private, no-store'};
export async function GET(req:Request) {
  const secret=process.env.CRON_SECRET, a=Buffer.from(req.headers.get('authorization')||''),b=Buffer.from(`Bearer ${secret||''}`);
  if(!secret||secret.length<32||a.length!==b.length||!timingSafeEqual(a,b)) return Response.json({errore:'Non autorizzato.'},{status:401,headers});
  if(process.env.FIC_SYNC_ENABLED!=='true') return Response.json({stato:'Sincronizzazione automatica non attiva.'},{status:503,headers});
  const al=new Intl.DateTimeFormat('en-CA',{timeZone:'Europe/Rome',year:'numeric',month:'2-digit',day:'2-digit'}).format(new Date());
  const dal=new Date(Date.parse(al)-30*86400000).toISOString().slice(0,10);
  const risultati:Record<string,unknown>={};
  for(const tipo of Object.keys(TIPI_FIC) as TipoFic[]) {
    try{risultati[tipo]=await sincronizzaFic(tipo,dal,al);}
    catch{return Response.json({errore:`Sincronizzazione ${tipo} non completata.`,completati:Object.keys(risultati)},{status:503,headers});}
  }
  return Response.json({dal,al,risultati},{headers});
}

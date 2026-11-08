import { rpcFic, verificaClientiOrdiniFic, verificaFattureChatFic } from '../../../lib/ficAutomazioniServer';
export const runtime='nodejs';
export const maxDuration=240;
export async function POST(request:Request) {
 const auth=request.headers.get('authorization') || '';
 if(!/^Bearer [A-Za-z0-9-]{64,100}$/.test(auth))return Response.json({errore:'Non autorizzato'},{status:401});
 let lease:string|null=null;
 try {
  if(!await rpcFic<boolean>('autorizza_worker_originali_k',{p_token:auth.slice(7)}))return Response.json({errore:'Non autorizzato'},{status:401});
  if(process.env.FIC_AUTOMAZIONI_ENABLED!=='true')return Response.json({esito:'disattivato'},{status:503});
  lease=await rpcFic<string|null>('fic_inizia_controlli');
  if(!lease)return Response.json({esito:'in_corso'});
  await verificaClientiOrdiniFic();
  await verificaFattureChatFic();
  return Response.json({esito:'completato'});
 }catch{return Response.json({errore:'Controlli amministrativi non completati'},{status:503});}
 finally { if(lease)await rpcFic('fic_termina_controlli',{p_lease:lease}).catch(()=>{}); }
}

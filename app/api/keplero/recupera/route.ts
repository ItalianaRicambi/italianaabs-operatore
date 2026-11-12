import {after} from 'next/server';
import {processTransportChecks} from '../../../lib/followupDati/transportCheckServer';
import {processFollowupBatch} from '../../../lib/followupDati/automatedServer';
import {rpcOriginaliK,recuperaOriginaliK} from '../../../lib/originaliKepleroServer';
export const runtime='nodejs';
export const maxDuration=180;
export async function POST(request:Request){
 const auth=request.headers.get('authorization')||'';
 if(!/^Bearer [A-Za-z0-9-]{64,100}$/.test(auth))return Response.json({errore:'Non autorizzato'},{status:401});
 try{
  if(!await rpcOriginaliK<boolean>('autorizza_worker_originali_k',{p_token:auth.slice(7)}))return Response.json({errore:'Non autorizzato'},{status:401});
  after(async()=>{
   const results=await Promise.allSettled([processTransportChecks(),processFollowupBatch()]);
   if(results.some(result=>result.status==='rejected'))console.warn('followup_dati_lotto_non_completato');
  });
  return Response.json(await recuperaOriginaliK());
 }catch{return Response.json({errore:'Recupero originali non completato. Verificare il registro K.'},{status:503});}
}

import {rpcMbe,sincronizzaMbe,leggiCollegamentoMbe} from '../../../lib/mbeServer';
export const runtime='nodejs';
export const maxDuration=60;
export async function POST(request:Request) {
 const auth=request.headers.get('authorization')||'';
 if(!/^Bearer [A-Za-z0-9-]{64,100}$/.test(auth))return Response.json({errore:'Non autorizzato'},{status:401});
 try {
  if(!await rpcMbe<boolean>('autorizza_worker_mbe',{p_token:auth.slice(7)}))return Response.json({errore:'Non autorizzato'},{status:401});
  if(!(await leggiCollegamentoMbe()).automatico)return Response.json({esito:'sospeso'});
  return Response.json(await sincronizzaMbe());
 }catch{return Response.json({errore:'Sincronizzazione MBE non completata. Verificare il collegamento nella dashboard.'},{status:503});}
}

import { autorizzazioneEmail, normalizzaEmail } from '../../../lib/richiesteEmail';
import { processaRichiestaEmail } from '../../../lib/richiesteEmailServer';
export const runtime='nodejs';
export const maxDuration=60;
export async function POST(request:Request){
 const secret=request.headers.get('x-keplero-secret') || request.headers.get('authorization')?.replace(/^Bearer\s+/i,'') || null;
 if(!autorizzazioneEmail(secret,process.env.KEPLERO_WEBHOOK_SECRET)) return Response.json({ok:false,errore:'Non autorizzato'},{status:401});
 let email;
 try {const raw=await request.text();if(raw.length>300000) return Response.json({ok:false,errore:'Email troppo grande'},{status:413});email=normalizzaEmail(JSON.parse(raw));}
 catch{return Response.json({ok:false,errore:'Dati originali email mancanti o non validi'},{status:400});}
 try {const risultato=await processaRichiestaEmail(email);return Response.json(risultato,{status:risultato.ok?200:503});}
 catch{return Response.json({ok:false,errore:'Registro email temporaneamente non disponibile'},{status:503});}
}

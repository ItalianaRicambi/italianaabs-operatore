import { getOperatoreAttivo } from '../../../../../operatore';
import { leggiRichiestaEmail } from '../../../../../lib/richiesteEmailServer';
import { leggiMessaggiConversazioneKeplero } from '../../../../../lib/kepleroMessagesServer';
import { ErroreMessaggiKeplero } from '../../../../../lib/kepleroMessages';
export const runtime = 'nodejs';
export const maxDuration = 60;
const headers = {'Cache-Control':'private, no-store','X-Robots-Tag':'noindex, nofollow','Referrer-Policy':'no-referrer'};
/** Lettura riservata degli originali K; nessuna scrittura di dati o stato. */
export async function GET(_request: Request, {params}: {params: Promise<{id:string}>}) {
 if (!await getOperatoreAttivo()) return Response.json({ok:false,errore:'Accesso operatore richiesto'},{status:401,headers});
 const {id} = await params;
 if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) return Response.json({ok:false,errore:'Email non valida'},{status:400,headers});
 try {
  const email = await leggiRichiestaEmail(id);
  if (!email) return Response.json({ok:false,errore:'Email non trovata'},{status:404,headers});
  const messaggi = await leggiMessaggiConversazioneKeplero(email.conversation_id);
  return Response.json({ok:true,richiesta_email_id:id,conversation_id:email.conversation_id,messaggi},{headers});
 } catch (error) {
  const codice = error instanceof ErroreMessaggiKeplero ? error.codice : 'non_disponibile';
  return Response.json({ok:false,errore:codice},{status:503,headers});
 }
}

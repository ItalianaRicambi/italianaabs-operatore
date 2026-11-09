import 'server-only';
import {rpcOriginaliK} from '../originaliKepleroServer';
import {leggiMessaggiConversazioneKeplero} from '../kepleroMessagesServer';
import {sendTemplate,type Attempt,type Receipt} from './transport';
import {reconcileStored,runReminder,type Review,type Store,type StoredAttempt} from './runner';

/** Adattatore persistente Supabase. Il revisore non è esposto a client/Keplero:
 * deve essere fornito dal worker server dopo letture originali, media e anagrafiche.
 */
export function createStore(requestId:string):Store{
 return {
  claim(review:Review){return rpcOriginaliK<string|null>('claim_followup_dati',{
   p_richiesta:requestId,p_pratica_updated_at:review.practiceVersion,p_verificata_at:review.context.snapshot.readStartedAt,
   p_impronta:review.context.snapshot.sourceFingerprint,p_campi:review.context.snapshot.missing,
  });},
  begin(claim:string,review:Review,attempt:Attempt){return rpcOriginaliK<boolean>('inizia_invio_followup_dati',{
   p_claim:claim,p_pratica_updated_at:review.practiceVersion,p_verificata_at:review.context.snapshot.readStartedAt,
   p_impronta:review.context.snapshot.sourceFingerprint,p_campi:review.context.snapshot.missing,p_tentativo:attempt,
  });},
  finish(claim:string,state:'sent'|'ambiguous'|'cancelled',receipt:Receipt|null,reason:string){
   return rpcOriginaliK<boolean>('esito_followup_dati',{
    p_claim:claim,p_stato:state,p_message_id:receipt?.providerMessageId??null,p_inviata_at:receipt?.sentAt??null,
    p_conferma:receipt?{...receipt,reason}:null,
   });
  },
  escalate(review:Review){return rpcOriginaliK<boolean>('segnala_followup_dati',{
   p_pratica:review.context.request.practiceId,p_fase:review.context.request.phase,
   p_pratica_updated_at:review.practiceVersion,p_verificata_at:review.context.snapshot.readStartedAt,
  });},
 };
}
export function runReviewedRequest(requestId:string,review:()=>Promise<Review>){
 return runReminder({review,store:createStore(requestId),now:Date.now,messages:leggiMessaggiConversazioneKeplero,
  send:attempt=>sendTemplate(attempt,process.env.KEPLERO_API_KEY)});
}
export function recoverAttempt(requestId:string,attempt:StoredAttempt){
 return reconcileStored(attempt,{store:createStore(requestId),now:Date.now,messages:leggiMessaggiConversazioneKeplero});
}

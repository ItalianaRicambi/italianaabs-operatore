import 'server-only';
import {rpcOriginaliK} from '../originaliKepleroServer';
import {leggiMessaggiConversazioneKeplero} from '../kepleroMessagesServer';
import {sendTemplate,type Attempt,type Receipt} from './transport';
import {reconcileStored,runReminder,type Review,type Store,type StoredAttempt} from './runner';
import {readFollowupConfiguration} from './calendarServer';
import {reviewCustomerReplies,type LiveEvidence} from './evidence';

/** Adattatore persistente Supabase. Il revisore non è esposto a client/Keplero:
 * deve essere fornito dal worker server dopo letture originali, media e anagrafiche.
 */
export function createStore(requestId:string):Store{
 return {
  claim(review:Review){return rpcOriginaliK<string|null>('claim_followup_dati',{
   p_richiesta:requestId,p_pratica_updated_at:review.practiceVersion,p_verificata_at:review.context.snapshot.readStartedAt,
   p_impronta:review.context.snapshot.sourceFingerprint,p_campi:review.context.snapshot.missing,
   p_rinvio:review.context.snapshot.customerDeferral??null,
  });},
  releaseUnsent(claim){return rpcOriginaliK<boolean>('rilascia_claim_followup_dati',{p_claim:claim});},
  begin(claim:string,review:Review,attempt:Attempt){return rpcOriginaliK<boolean>('followup_dati_inizia_worker',{
   p_claim:claim,p_pratica_updated_at:review.practiceVersion,p_verificata_at:review.context.snapshot.readStartedAt,
   p_impronta:review.context.snapshot.sourceFingerprint,p_campi:review.context.snapshot.missing,p_tentativo:attempt,
   p_rinvio:review.context.snapshot.customerDeferral??null,
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
   p_rinvio:review.context.snapshot.customerDeferral??null,
  });},
 };
}
export function runReviewedRequest(requestId:string,review:()=>Promise<Review & {evidence:LiveEvidence}>){
 return runReminder({review:async()=>{
  // Leggere prima della revisione live: il timer di freschezza non viene esteso.
  const configuration=await readFollowupConfiguration();
  const {evidence,...result}=await review();
  const {snapshot,request}=result.context;
  if (!request.sentAt || evidence.fingerprint !== snapshot.sourceFingerprint
   || evidence.startedAt !== snapshot.readStartedAt || evidence.finishedAt !== snapshot.readFinishedAt
   || !evidence.originals.some(message => message.id === request.messageId && message.direzione === 'uscita'
    && message.impronta === request.sourceFingerprint && message.data === request.sentAt)) {
   throw new Error('followup_review_evidence_mismatch');
  }
  const replies=reviewCustomerReplies(request.sentAt,evidence,configuration.calendar);
  return {...result,context:{...result.context,...configuration,snapshot:{...snapshot,...replies,
   responsePendingReview:snapshot.responsePendingReview||replies.responsePendingReview,
  }}};
 },store:createStore(requestId),now:Date.now,messages:leggiMessaggiConversazioneKeplero,
  send:attempt=>sendTemplate(attempt,process.env.KEPLERO_API_KEY)});
}
export function recoverAttempt(requestId:string,attempt:StoredAttempt){
 return reconcileStored(attempt,{store:createStore(requestId),now:Date.now,messages:leggiMessaggiConversazioneKeplero});
}

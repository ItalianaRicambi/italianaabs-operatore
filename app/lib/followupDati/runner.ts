import {prepareReminder,shouldEscalate,type Context} from './policy.ts';
import {reconcile,validateSend,type Attempt,type SendResult,type Receipt} from './transport.ts';
import type {MessaggioKeplero} from '../kepleroMessages.ts';
import {renderApprovedTemplate} from './templates.ts';

export type Review = {context:Context;practiceVersion:string;session:string;to:string;messageIds:string[]};
export type StoredAttempt = {claim:string;attempt:Attempt};
export type Store = {
 claim(review:Review):Promise<string|null>;
 releaseUnsent(claim:string):Promise<boolean>;
 /** Scrive il tentativo PRIMA del POST e fa CAS: una sola chiamata può ottenere true. */
 begin(claim:string,review:Review,attempt:Attempt):Promise<boolean>;
 finish(claim:string,state:'sent'|'ambiguous'|'cancelled',receipt:Receipt|null,reason:string):Promise<boolean>;
 escalate(review:Review):Promise<boolean>;
};
export type Dependencies = {
 review():Promise<Review>;store:Store;now():number;
 send(attempt:Attempt):Promise<SendResult>;
 messages(session:string):Promise<MessaggioKeplero[]>;
};
export type RunResult = {kind:'stop'|'wait'|'sent'|'ambiguous'|'cancelled'|'escalated';reason:string};
function sameTarget(a:Review,b:Review):boolean {
 return a.session===b.session&&a.to===b.to&&a.context.request.practiceId===b.context.request.practiceId
  &&a.context.request.phase===b.context.request.phase&&a.context.request.messageId===b.context.request.messageId
  &&a.context.request.sourceFingerprint===b.context.request.sourceFingerprint;
}
function dispatchDecision(review:Review,now:number) {
 return prepareReminder({...review.context,ledger:{state:'none',messageId:null,sentAt:null}},now);
}
async function deferUnsent(d:Dependencies,claim:string,first:Review,last:Review,decision:ReturnType<typeof dispatchDecision>):Promise<RunResult|null> {
 const deferral = last.context.snapshot.customerDeferral;
 if (decision.kind !== 'wait' || !sameTarget(first,last) || !deferral
  || Date.parse(deferral.notBefore) <= d.now() || !await d.store.releaseUnsent(claim)) return null;
 return {kind:'wait',reason:decision.at};
}
/** Due letture indipendenti. La seconda segue il claim. Solo un rinvio
 * verificato prima del tentativo può lasciare lo slot disponibile più avanti.
 */
export async function runReminder(d:Dependencies):Promise<RunResult>{
 const first=await d.review();
 if(first.context.ledger.state==='sent'){
  if(shouldEscalate(first.context,d.now())&&await d.store.escalate(first))return {kind:'escalated',reason:'operator_activity_created'};
  return {kind:'stop',reason:'reminder_already_sent'};
 }
 const decision=prepareReminder(first.context,d.now());
 if(decision.kind!=='ready')return {kind:decision.kind,reason:decision.kind==='stop'?decision.reason:decision.at};
 const claim=await d.store.claim(first);if(!claim)return {kind:'stop',reason:'claim_unavailable'};
 let attempted=false;
 try{
  const last=await d.review();
  // Il solo worker con claim può valutare di nuovo la policy; begin verifica il
  // possesso/stato nel DB e impedisce che un secondo processo consumi lo stesso slot.
  const final=dispatchDecision(last,d.now());
  const deferred=await deferUnsent(d,claim,first,last,final);
  if(deferred)return deferred;
  if(final.kind!=='ready'||!sameTarget(first,last)||JSON.stringify(final.variables)!==JSON.stringify(decision.variables)){
   await d.store.finish(claim,'cancelled',null,'changed_after_claim');return {kind:'cancelled',reason:'changed_after_claim'};
  }
  const attempt:Attempt={phase:last.context.request.phase,to:last.to,session:last.session,variables:final.variables,
   startedAt:new Date(d.now()).toISOString(),beforeIds:last.messageIds,expectedText:renderApprovedTemplate(last.context.request.phase,final.variables)};
  validateSend(attempt);
  if(!attempt.expectedText.includes(final.variables[0])||!attempt.expectedText.includes(final.variables[1]))throw new Error('template_text_unverified');
  if(!await d.store.begin(claim,last,attempt)){
   // Il DB può vedere una risposta arrivata dopo la seconda lettura. Conferma
   // il rinvio sugli originali prima di rilasciare una prenotazione non usata.
   const updated=await d.review();
   const deferred=await deferUnsent(d,claim,first,updated,dispatchDecision(updated,d.now()));
   return deferred??{kind:'stop',reason:'dispatch_not_authorized'};
  }
  if(dispatchDecision(last,d.now()).kind!=='ready'){
   await d.store.finish(claim,'cancelled',null,'expired_before_dispatch');
   return {kind:'cancelled',reason:'expired_before_dispatch'};
  }
  attempted=true;
  // A lost database response from begin throws before this line: fail closed.
  const sent=await d.send(attempt);
  if(sent.kind==='rejected'){
   await d.store.finish(claim,'cancelled',null,sent.code);return {kind:'cancelled',reason:sent.code};
  }
  return await reconcileStored({claim,attempt},d);
 }catch{
  await d.store.finish(claim,attempted?'ambiguous':'cancelled',null,attempted?'dispatch_unconfirmed':'review_failed').catch(()=>false);
  return {kind:attempted?'ambiguous':'cancelled',reason:attempted?'dispatch_unconfirmed':'review_failed'};
 }
}
/** Recovery is read-only at the provider, including after a process crash. */
export async function reconcileStored(stored:StoredAttempt,d:Pick<Dependencies,'messages'|'now'|'store'>):Promise<RunResult>{
 let receipt:Receipt|null=null;
 try{receipt=reconcile(stored.attempt,await d.messages(stored.attempt.session),d.now());}catch{/* Keep the slot closed. */}
 if(receipt&&await d.store.finish(stored.claim,'sent',receipt,'original_confirmed'))return {kind:'sent',reason:'original_confirmed'};
 await d.store.finish(stored.claim,'ambiguous',null,'dispatch_unconfirmed');
 return {kind:'ambiguous',reason:'dispatch_unconfirmed'};
}

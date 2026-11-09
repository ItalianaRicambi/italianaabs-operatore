/** Preparazione fail-closed. Nessun trasporto o trigger è collegato a questo modulo.
 * Le attestazioni devono provenire dal futuro adattatore server, mai dal client/AI.
 */
export type Phase = 'preventivo' | 'fatturazione';
export const templates: Record<Phase, string> = {
 preventivo: 'italianaabs_dati_preventivo_24h',
 fatturazione: 'italianaabs_dati_fatturazione_24h',
};
export const labels = {
 targa: 'targa del veicolo', codici: 'codici identificativi del componente',
 foto: 'foto leggibili del componente', guasto: 'descrizione del guasto',
 diagnosi: 'esito della diagnosi richiesta', denominazione: 'intestazione della fattura',
 indirizzo_fatturazione: 'indirizzo di fatturazione', cap: 'CAP', comune: 'comune',
 provincia: 'provincia', nazione: 'nazione', partita_iva_o_codice_fiscale: 'partita IVA o codice fiscale',
 partita_iva: 'partita IVA', codice_fiscale: 'codice fiscale', sdi_o_pec: 'codice SDI o PEC',
} as const;
export type Field = keyof typeof labels;
const prequote = new Set<Field>(['targa','codici','foto','guasto','diagnosi']);
const hour = 3_600_000;
const rome = new Intl.DateTimeFormat('en-CA', {timeZone:'Europe/Rome',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hourCycle:'h23'});
export type Calendar = { confirmedThrough: string; closures: { from:string; through:string }[] };
function local(instant:number) {
 const parts = Object.fromEntries(rome.formatToParts(instant).map(p=>[p.type,p.value]));
 const day = `${parts.year}-${parts.month}-${parts.day}`;
 return {day, minute:Number(parts.hour)*60+Number(parts.minute), weekday:new Date(`${day}T12:00:00Z`).getUTCDay()};
}
function validDay(day:string):boolean {
 return /^\d{4}-\d\d-\d\d$/.test(day) && Number.isFinite(Date.parse(day)) && new Date(day).toISOString().slice(0,10)===day;
}
function calendarValid(c:Calendar) {
 return validDay(c.confirmedThrough) && c.closures.every(d=>validDay(d.from)&&validDay(d.through)&&d.from<=d.through);
}
/** Orari già configurati nel DB aziendale: lun-gio 09–12:30 / 14–18:30; ven 09–13:30. */
export function isOpen(instant:number,c:Calendar):boolean {
 if(!Number.isFinite(instant)||!calendarValid(c))return false;
 const d=local(instant);
 if(d.day>c.confirmedThrough||c.closures.some(x=>d.day>=x.from&&d.day<=x.through))return false;
 if(d.weekday===5)return d.minute>=540&&d.minute<810;
 return d.weekday>=1&&d.weekday<=4&&((d.minute>=540&&d.minute<750)||(d.minute>=840&&d.minute<1110));
}
/** 24 ore sono trascorse in UTC, poi si cerca l'apertura, anche attraverso il cambio DST. */
export function nextOpening(instant:number,c:Calendar):number|null {
 if(!Number.isFinite(instant)||!calendarValid(c))return null;
 if(isOpen(instant,c))return instant;
 // Ricerca limitata: calendario incompleto/chiusura troppo lunga blocca, non autorizza.
 const limit=instant+45*24*hour;
 for(let t=Math.ceil(instant/60000)*60000;t<=limit;t+=60000){
  if(local(t).day>c.confirmedThrough)return null;
  if(isOpen(t,c))return t;
 }
 return null;
}
export type RequestEvidence = {
 practiceId:string; phase:Phase; messageId:string; sentAt:string|null; sourceFingerprint:string;
 deliveryConfirmed:boolean; fields:Field[];
};
export type Snapshot = {
 practiceId:string; practiceNumber:string; channel:'whatsapp'|'other'; phase:Phase;
 commercialState:string; completeness:string; quoteIssued:boolean; acceptedOrder:boolean;
 invoiceOrProformaIssued:boolean; closedOrDeclined:boolean; operatorBlocked:boolean;
 responsePendingReview:boolean; fiscalRegistryChecked:boolean; fiscalRegistryAmbiguous:boolean;
 missing:Field[];
 // L'adattatore deve rileggere originali E byte degli allegati, non il riassunto della chat.
 readStartedAt:string; readFinishedAt:string; allOriginalsRead:boolean; allAttachmentsReviewed:boolean;
 originalRequestPresent:boolean; originalRequestUnchanged:boolean;
 // Qualunque risposta successiva, inclusi file/audio/media, sospende questa richiesta.
 customerReplyAtOrAfterRequest:boolean; unknownDirectionAfterRequest:boolean;
 sourceFingerprint:string;
};
export type Ledger = { state:'none'|'claimed'|'sent'|'ambiguous'|'cancelled'; sentAt:string|null; messageId:string|null };
export type Context = { request:RequestEvidence; snapshot:Snapshot; ledger:Ledger; calendar:Calendar; enabledAfter:string|null };
export type Decision = { kind:'stop'; reason:string } | {kind:'wait'; at:string} |
 {kind:'ready'; key:string; template:string; variables:[string,string]; requestMessageId:string; snapshotFingerprint:string};
function stop(reason:string):Decision{return {kind:'stop',reason};}
function timestamp(s:string|null):number {
 if(!s||!/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|[+-]\d\d:\d\d)$/.test(s))return NaN;
 return validDay(s.slice(0,10))?Date.parse(s):NaN;
}
function evidenceProblem(c:Context,now:number):string|null {
 const r=c.request,s=c.snapshot;
 const flags=[s.quoteIssued,s.acceptedOrder,s.invoiceOrProformaIssued,s.closedOrDeclined,s.operatorBlocked,
  s.responsePendingReview,s.fiscalRegistryChecked,s.fiscalRegistryAmbiguous,s.allOriginalsRead,s.allAttachmentsReviewed,
  s.originalRequestPresent,s.originalRequestUnchanged,s.customerReplyAtOrAfterRequest,s.unknownDirectionAfterRequest,r.deliveryConfirmed];
 if(flags.some(v=>typeof v!=='boolean')||!Array.isArray(r.fields)||!Array.isArray(s.missing)||!['preventivo','fatturazione'].includes(r.phase))return 'evidence_unverified';
 if(!Number.isFinite(now))return 'clock_invalid';
 if(!r.practiceId||r.practiceId!==s.practiceId||r.phase!==s.phase||s.channel!=='whatsapp')return 'association_unverified';
 if(!/^ABS-\d{6,}$/.test(s.practiceNumber))return 'practice_number_invalid';
 if(s.closedOrDeclined||['rifiutato','chiuso'].includes(s.commercialState))return 'closed';
 if(s.operatorBlocked)return 'operator_block';
 if(s.invoiceOrProformaIssued)return 'already_invoiced';
 if(s.responsePendingReview||s.customerReplyAtOrAfterRequest||s.unknownDirectionAfterRequest)return 'response_to_review';
 const start=timestamp(s.readStartedAt),end=timestamp(s.readFinishedAt);
 if(!s.allOriginalsRead||!s.allAttachmentsReviewed||!Number.isFinite(start)||!Number.isFinite(end)||start>end||end>now||now-start>15_000)return 'live_review_incomplete_or_stale';
 if(!/^[a-f0-9]{64}$/.test(s.sourceFingerprint)||!s.originalRequestPresent||!s.originalRequestUnchanged)return 'request_changed_or_absent';
 if(!r.messageId||!r.deliveryConfirmed||!Number.isFinite(timestamp(r.sentAt))||timestamp(r.sentAt)>start||!/^[a-f0-9]{64}$/.test(r.sourceFingerprint))return 'request_send_unverified';
 // Cutover obbligatorio: anche una richiesta storica datata non entra in un recupero massivo.
 if(!Number.isFinite(timestamp(c.enabledAfter))||timestamp(r.sentAt)<timestamp(c.enabledAfter))return 'historical_request_excluded';
 if(!Array.isArray(s.missing)||s.missing.length===0)return 'data_complete';
 if(!s.missing.every(f=>Object.hasOwn(labels,f)&&r.fields.includes(f)))return 'new_targeted_request_required';
 if(r.fields.length===0||!r.fields.every(f=>Object.hasOwn(labels,f)))return 'request_fields_invalid';
 if(s.phase==='preventivo'){
  if(s.quoteIssued||s.acceptedOrder||!['nuova','raccolta_dati','richiesta_verifica'].includes(s.commercialState)||s.completeness!=='dati_mancanti')return 'prequote_phase_ended';
  if(!s.missing.every(f=>prequote.has(f)))return 'fields_wrong_phase';
 }else{
  if(!s.acceptedOrder||s.commercialState!=='ordine_acquisito')return 'order_not_accepted';
  if(!s.fiscalRegistryChecked||s.fiscalRegistryAmbiguous)return 'fiscal_registry_to_verify';
  if(s.missing.some(f=>prequote.has(f)))return 'fields_wrong_phase';
 }
 return null;
}
export function prepareReminder(c:Context,now:number):Decision {
 if(c.ledger.state!=='none')return stop('reminder_already_claimed');
 const problem=evidenceProblem(c,now);if(problem)return stop(problem);
 const due=nextOpening(timestamp(c.request.sentAt)+24*hour,c.calendar);
 if(due===null)return stop('calendar_unverified');
 if(now<due)return {kind:'wait',at:new Date(due).toISOString()};
 if(!isOpen(now,c.calendar)){
  const next=nextOpening(now,c.calendar);return next===null?stop('calendar_unverified'):{kind:'wait',at:new Date(next).toISOString()};
 }
 return {kind:'ready',key:`dati:${c.request.practiceId}:${c.request.phase}`,template:templates[c.request.phase],
  variables:[c.snapshot.practiceNumber,[...new Set(c.snapshot.missing)].map(f=>labels[f]).join(', ')],
  requestMessageId:c.request.messageId,snapshotFingerprint:c.snapshot.sourceFingerprint};
}
/** Solo un'attività interna, mai un secondo messaggio. Una nuova richiesta sposta anche questa attesa. */
export function shouldEscalate(c:Context,now:number):boolean {
 if(c.ledger.state!=='sent'||!c.ledger.messageId||!Number.isFinite(timestamp(c.ledger.sentAt)))return false;
 if(evidenceProblem(c,now))return false;
 return now>=Math.max(timestamp(c.ledger.sentAt),timestamp(c.request.sentAt))+48*hour;
}

import 'server-only';
import { leggiMessaggiConversazioneKeplero } from '../kepleroMessagesServer';
import { rpcOriginaliK } from '../originaliKepleroServer';
import { readFollowupConfiguration } from './calendarServer';
import { findTargetedRequest, readLiveEvidence, reviewCustomerReplies, type LiveEvidence } from './evidence';
import { prepareFiscalRequest, technicalRequestFromNote, type InitialRequest } from './initialRequest';
import { isOpen, type Calendar, type Ledger, type Phase } from './policy';
import type { Review, StoredAttempt } from './runner';
import { recoverAttempt, runReviewedRequest } from './storeServer';
import { BOT } from './transport';

type RuntimeContext = {
  id: string;
  practiceNumber: number | string;
  session: string;
  assistant: string;
  to: string;
  phase: Phase;
  updatedAt: string;
  commercialState: string;
  completeness: string;
  note: string | null;
  fiscalText: string | null;
  fiscalFields: string[] | null;
  missingFiscal: string[] | null;
  fiscalChecked: boolean;
  quoteHashes: string[];
  ledger: Ledger;
  storedAttempt: StoredAttempt | null;
};

function initialRequest(state: RuntimeContext): InitialRequest | null {
  if (state.phase === 'preventivo') return technicalRequestFromNote(state.note);
  return prepareFiscalRequest(state.fiscalText, state.fiscalFields ?? []);
}

async function loadContext(practiceId: string) {
  const state = await rpcOriginaliK<RuntimeContext | null>('followup_dati_contesto', {p_pratica: practiceId});
  if (!state || state.id !== practiceId || state.assistant !== BOT) return null;
  return state;
}

function relevantAttachmentsReviewed(state: RuntimeContext, evidence: LiveEvidence) {
  return evidence.attachments.every(attachment => state.phase === 'fatturazione'
    && attachment.contentType === 'application/pdf'
    && state.quoteHashes.includes(attachment.sha256)
    && evidence.originals.some(original => original.id === attachment.messageId && original.direzione === 'uscita'));
}

function knownLaterOutgoing(state: RuntimeContext, evidence: LiveEvidence, sentAt: string, requestId: string) {
  return evidence.originals.every(message => {
    if (message.direzione !== 'uscita' || message.id === requestId || Date.parse(message.data) < Date.parse(sentAt)) return true;
    const metadata = message.originale.metadata as Record<string, unknown> | undefined;
    return (state.ledger.state === 'sent' && state.ledger.messageId === metadata?.wa_message_id)
      || /^(?:va bene|grazie|perfetto|restiamo in attesa(?: dei dati)?)[.!]?$/iu.test(message.testo.trim());
  });
}

function reviewState(state: RuntimeContext, plan: InitialRequest, evidence: LiveEvidence, calendar: Calendar, cutoff: string) {
  const request = findTargetedRequest({ ...plan, practiceId: state.id, cutover: cutoff }, evidence, calendar);
  if (!request?.sentAt) return null;
  const review = reviewCustomerReplies(request.sentAt, evidence, calendar);
  const missing = state.phase === 'fatturazione'
    ? prepareFiscalRequest(state.fiscalText, state.missingFiscal ?? [])?.fields ?? []
    : plan.fields;
  const digits = String(state.practiceNumber);
  if (!/^\d+$/u.test(digits)) return null;
  return {
    context: {
      request, calendar, enabledAfter: cutoff, ledger: state.ledger,
      snapshot: {
        ...review,
        practiceId: state.id,
        practiceNumber: `ABS-${digits.padStart(6,'0')}`,
        phase: state.phase,
        channel: 'whatsapp',
        commercialState: state.commercialState,
        completeness: state.completeness,
        quoteIssued: false, // The database excludes a prior quote from the preventive phase.
        acceptedOrder: state.commercialState === 'ordine_acquisito',
        invoiceOrProformaIssued: false, // The database returns no context for an issued document.
        closedOrDeclined: false,
        operatorBlocked: false,
        responsePendingReview: review.responsePendingReview || !knownLaterOutgoing(state,evidence,request.sentAt,request.messageId),
        fiscalRegistryChecked: state.fiscalChecked,
        fiscalRegistryAmbiguous: false, // An ambiguous identity has no dispatch context.
        missing,
        allOriginalsRead: true,
        allAttachmentsReviewed: relevantAttachmentsReviewed(state,evidence),
        readStartedAt: evidence.startedAt,
        readFinishedAt: evidence.finishedAt,
        sourceFingerprint: evidence.fingerprint,
        originalRequestPresent: true,
        originalRequestUnchanged: true,
      },
    },
    session: state.session,
    to: state.to,
    practiceVersion: state.updatedAt,
    messageIds: evidence.originals.map(message => message.id),
  } satisfies Review;
}

async function processPractice(practiceId: string, cutoff: string, calendar: Calendar) {
  const state = await loadContext(practiceId);
  if (!state) return;
  if (state.storedAttempt) {
    if (state.storedAttempt.attempt.session === state.session && state.storedAttempt.attempt.to === state.to) {
      await recoverAttempt(practiceId,state.storedAttempt);
    }
    return;
  }
  const read = async (current: RuntimeContext) => {
    const plan = initialRequest(current);
    if (!plan) return null;
    const evidence = await readLiveEvidence(current.session,() => leggiMessaggiConversazioneKeplero(current.session));
    const review = reviewState(current,plan,evidence,calendar,cutoff);
    return review ? {...review,evidence} : null;
  };
  const first = await read(state);
  if (!first) return;
  const request = first.context.request;
  const requestId = await rpcOriginaliK<string | null>('followup_dati_registra_worker', {
    p_pratica: practiceId, p_fase: state.phase, p_sessione: state.session,
    p_messaggio: request.messageId, p_campi: request.fields, p_impronta: request.sourceFingerprint,
  });
  if (!requestId) return;
  await runReviewedRequest(requestId,async () => {
    const current = await loadContext(practiceId);
    if (!current || current.session !== state.session || current.to !== state.to || current.phase !== state.phase) {
      throw new Error('followup_practice_changed');
    }
    const latest = await read(current);
    if (!latest || latest.context.request.messageId !== request.messageId
      || latest.context.request.sourceFingerprint !== request.sourceFingerprint) throw new Error('followup_request_changed');
    return latest;
  });
}

export async function processFollowupBatch() {
  const config = await readFollowupConfiguration();
  if (!config.enabledAfter || !process.env.KEPLERO_API_KEY?.trim() || !isOpen(Date.now(),config.calendar)) return;
  const cutoff = config.enabledAfter;
  const ids = await rpcOriginaliK<string[]>('followup_dati_lotto');
  const results = await Promise.allSettled(ids.map(id => processPractice(id,cutoff,config.calendar)));
  const failures = results.filter(result => result.status === 'rejected').length;
  if (failures) console.warn('followup_dati_verifiche_incomplete',{failures});
}

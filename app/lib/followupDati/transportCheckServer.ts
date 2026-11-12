import 'server-only';
import { connessioneGlsDb } from '../glsServer';
import { leggiMessaggiConversazioneKeplero } from '../kepleroMessagesServer';
import type { Phase } from './policy';
import { renderApprovedTemplate } from './templates';
import { reconcile, sendTemplate, type Attempt, type Receipt } from './transport';

type Check = {
  fase: Phase;
  sessione: string;
  telefono: string;
  esito: 'pronto' | 'in_corso' | 'incerto';
  tentativo: Attempt | null;
};
const source = 'followup_dati_collaudo';

async function writeCheck(phase: Phase, from: Check['esito'], data: Record<string,unknown>) {
  const {url,headers} = connessioneGlsDb();
  const response = await fetch(`${url}/rest/v1/${source}?fase=eq.${phase}&esito=eq.${from}`, {
    method: 'PATCH', headers: {...headers,Prefer:'return=representation'},
    body: JSON.stringify(data), cache:'no-store', signal:AbortSignal.timeout(8000),
  });
  if (!response.ok) throw new Error('followup_check_write_failed');
  const rows: unknown = await response.json();
  return Array.isArray(rows) && rows.length === 1;
}

async function readReceipt(attempt: Attempt): Promise<Receipt | null> {
  const messages = await leggiMessaggiConversazioneKeplero(attempt.session);
  return reconcile(attempt,messages,Date.now());
}

async function runCheck(check: Check, key: string) {
  let attempt = check.tentativo;
  let state = check.esito;
  if (state === 'pronto') {
    const messages = await leggiMessaggiConversazioneKeplero(check.sessione);
    const variables: [string,string] = [
      check.fase === 'preventivo' ? 'ABS-990001' : 'ABS-990002',
      check.fase === 'preventivo' ? 'TEST INTERNO AUTOMATICO — targa e foto' : 'TEST INTERNO AUTOMATICO — codice SDI o PEC',
    ];
    attempt = {
      phase:check.fase,session:check.sessione,to:check.telefono,variables,
      startedAt:new Date().toISOString(),
      beforeIds:messages.map(message=>String(message.id)),
      expectedText:renderApprovedTemplate(check.fase,variables),
    };
    // L'aggiornamento condizionale è la prenotazione atomica prima del POST.
    if (!await writeCheck(check.fase,'pronto',{esito:'in_corso',tentativo:attempt})) return;
    state = 'in_corso';
    const result = await sendTemplate(attempt,key);
    if (result.kind === 'rejected') {
      await writeCheck(check.fase,state,{esito:'rifiutato'});
      return;
    }
  }
  if (!attempt || attempt.phase !== check.fase || attempt.session !== check.sessione || attempt.to !== check.telefono) return;
  const receipt = await readReceipt(attempt);
  await writeCheck(check.fase,state,receipt ? {esito:'confermato',conferma:receipt} : {esito:'incerto'});
}

export async function processTransportChecks() {
  const key = process.env.KEPLERO_API_KEY?.trim();
  if (!key) return;
  const {url,headers} = connessioneGlsDb();
  const expires = encodeURIComponent(new Date().toISOString());
  const response = await fetch(`${url}/rest/v1/${source}?select=fase,sessione,telefono,esito,tentativo&esito=in.(pronto,in_corso,incerto)&scadenza=gt.${expires}&limit=2`, {
    headers,cache:'no-store',signal:AbortSignal.timeout(8000),
  });
  if (!response.ok) throw new Error('followup_check_read_failed');
  const checks = await response.json() as Check[];
  // Un'esecuzione successiva rilegge soltanto l'esito di un tentativo già prenotato.
  const results = await Promise.allSettled(checks.map(check => runCheck(check,key)));
  const failures = results.filter(result => result.status === 'rejected').length;
  if (failures) console.warn('followup_dati_collaudo_incompleto',{failures});
}

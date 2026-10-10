'use server';
import { createHash } from 'node:crypto';
import { revalidatePath } from 'next/cache';
import { richiediOperatoreAttivo } from '../operatore';
import { leggiDettaglioGls, NOMI_ABBINAMENTO_GLS, type EsitoGls } from '../lib/esitiGls';
import { connessioneGlsDb, registraEsitoGls } from '../lib/glsServer';

type State = { ok: boolean; messaggio: string };
function id(value: FormDataEntryValue | null) {
 const v = String(value || '');
 if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v)) throw new Error('Identificativo non valido.');
 return v;
}
function aggiorna(praticaId: string | null) {
 revalidatePath('/'); revalidatePath('/gls');
 if (praticaId) revalidatePath(`/pratica/${praticaId}`);
}
export async function importaDettaglioGls(_state: State, form: FormData): Promise<State> {
 const operatore = await richiediOperatoreAttivo();
 try {
  if (form.get('verificata') !== 'on') throw new Error('Verifica nel portale GLS il codice, il cliente e il dettaglio copiato.');
  const dati = leggiDettaglioGls(String(form.get('testo') || ''), String(form.get('riferimento') || ''), String(form.get('data_ritiro') || ''));
  // Il contratto del portale verificato; la configurazione è solo backend.
  if (dati.contratto !== (process.env.GLS_CONTRATTO || '6178')) throw new Error('Il dettaglio appartiene a un altro contratto GLS.');
  const verificataAt = new Date().toISOString();
  const fonteId = `operatore:${createHash('sha256').update(JSON.stringify([operatore, dati, verificataAt])).digest('hex')}`;
  const r = await registraEsitoGls({ ...dati, fonte: 'portale_gls', fonte_id: fonteId, verificata_at: verificataAt }, null, operatore);
  aggiorna(r.pratica_id);
  return { ok: true, messaggio: r.esito === 'abbinata' ? 'Esito GLS registrato nella pratica.' : `Esito acquisito. ${NOMI_ABBINAMENTO_GLS[r.esito] || 'Verifica l’abbinamento.'}` };
 } catch (e) { return { ok: false, messaggio: e instanceof Error ? e.message : 'Esito non registrato.' }; }
}
export async function abbinaEsitoGls(_state: State, form: FormData): Promise<State> {
 const operatore = await richiediOperatoreAttivo();
 try {
  if (form.get('verificata') !== 'on') throw new Error('Verifica cliente, destinazione, codice e data della presa.');
  const ricevuta = id(form.get('esito_id')), attivita = id(form.get('attivita_id'));
  const { url, headers } = connessioneGlsDb();
  const response = await fetch(`${url}/rest/v1/esiti_prese_gls?id=eq.${ricevuta}&select=*`, { headers, cache: 'no-store' });
  if (!response.ok) throw new Error('Dettaglio GLS non disponibile.');
  const esito = ((await response.json()) as EsitoGls[])[0];
  if (!esito) throw new Error('Esito GLS non trovato.');
  const r = await registraEsitoGls({ fonte: esito.fonte, fonte_id: esito.fonte_id, contratto: esito.contratto,
   riferimento: esito.riferimento, data_ritiro: esito.data_ritiro, mittente: esito.mittente, destinatario: esito.destinatario,
   numero_spedizione: esito.numero_spedizione, eventi: esito.eventi, testo: esito.testo, verificata_at: esito.verificata_at }, attivita, operatore);
  aggiorna(r.pratica_id);
  return { ok: r.esito === 'abbinata', messaggio: r.esito === 'abbinata' ? 'Abbinamento verificato: esito registrato.' : NOMI_ABBINAMENTO_GLS[r.esito] || 'Abbinamento da verificare.' };
 } catch (e) { return { ok: false, messaggio: e instanceof Error ? e.message : 'Abbinamento non registrato.' }; }
}

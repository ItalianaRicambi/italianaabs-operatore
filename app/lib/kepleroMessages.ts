/** Protocollo descritto dall'assistenza Keplero il 1 e l'8 ottobre 2026.
 * Non importa questo modulo nel client: la chiave viene fornita solo dal wrapper server.
 * Gli oggetti restano dati non attendibili; nessuna associazione automatica alla pratica.
 */
export type MessaggioKeplero = Readonly<Record<string, unknown>>;
export type ErroreKeplero = 'non_configurato' | 'conversazione_non_valida' | 'non_autorizzato' | 'non_disponibile' | 'risposta_non_valida' | 'limite_superato';
export class ErroreMessaggiKeplero extends Error {
 readonly codice: ErroreKeplero;
 readonly statoHttp?: number;
 constructor(codice: ErroreKeplero, statoHttp?: number) {
  super(`Recupero messaggi Keplero: ${codice}`);
  this.name = 'ErroreMessaggiKeplero';
  this.codice = codice;
  this.statoHttp = statoHttp;
 }
}
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const MAX_MESSAGGI = 5000;
const MAX_BYTE_PAGINA = 4 * 1024 * 1024;
const MAX_BYTE_TOTALI = 16 * 1024 * 1024;
function oggetto(v: unknown): v is Record<string, unknown> {
 return !!v && typeof v === 'object' && !Array.isArray(v);
}
async function leggiJson(r: Response): Promise<{dati: unknown; byte: number}> {
 const reader = r.body?.getReader();
 if (!reader) throw new ErroreMessaggiKeplero('risposta_non_valida');
 const chunks: Uint8Array[] = [];
 let byte = 0;
 try {
  while (true) {
   const part = await reader.read();
   if (part.done) break;
   byte += part.value.byteLength;
   if (byte > MAX_BYTE_PAGINA) throw new ErroreMessaggiKeplero('limite_superato');
   chunks.push(part.value);
  }
 } catch (error) {
  await reader.cancel().catch(() => {});
  throw error;
 } finally { reader.releaseLock(); }
 const buffer = new Uint8Array(byte);
 let offset = 0;
 for (const chunk of chunks) { buffer.set(chunk, offset); offset += chunk.byteLength; }
 try { return {dati: JSON.parse(new TextDecoder().decode(buffer)), byte}; }
 catch { throw new ErroreMessaggiKeplero('risposta_non_valida'); }
}

export async function recuperaMessaggiKeplero(
 conversazione: string,
 chiave: string | undefined,
 richiedi: typeof fetch = fetch,
): Promise<MessaggioKeplero[]> {
 if (!UUID.test(conversazione)) throw new ErroreMessaggiKeplero('conversazione_non_valida');
 const token = chiave?.trim().replace(/^Bearer[ \t]+/i, '').trim();
 if (!token || /[\r\n]/.test(token)) throw new ErroreMessaggiKeplero('non_configurato');
 const signal = AbortSignal.timeout(25_000);
 const messaggi: MessaggioKeplero[] = [];
 let byteTotali = 0;
 let totale: number | undefined;
 try {
  for (let page = 1; page <= MAX_MESSAGGI / 100; page++) {
   // Host fisso: nessun URL proveniente da email o parametro viene richiesto.
   const url = `https://v2.api.keplero.ai/v2/sessions/${conversazione}/messages?page=${page}&perPage=100`;
   const r = await richiedi(url, {
    method: 'GET', headers: {Authorization: `Bearer ${token}`, Accept: 'application/json'},
    cache: 'no-store', redirect: 'error', signal,
   });
   if (!r.ok) {
    await r.body?.cancel().catch(() => {});
    throw new ErroreMessaggiKeplero(r.status === 401 || r.status === 403 ? 'non_autorizzato' : 'non_disponibile', r.status);
   }
   const {dati, byte} = await leggiJson(r);
   byteTotali += byte;
   if (byteTotali > MAX_BYTE_TOTALI) throw new ErroreMessaggiKeplero('limite_superato');
   if (!oggetto(dati) || !Array.isArray(dati.data) || !dati.data.every(oggetto) || !oggetto(dati.pagination)) {
    throw new ErroreMessaggiKeplero('risposta_non_valida');
   }
   const p = dati.pagination;
   if (p.page !== page || p.perPage !== 100 || !Number.isSafeInteger(p.total) || (p.total as number) < 0) {
    throw new ErroreMessaggiKeplero('risposta_non_valida');
   }
   if ((p.total as number) > MAX_MESSAGGI) throw new ErroreMessaggiKeplero('limite_superato');
   // Una conversazione mutata durante la paginazione va riprovata, non usata parzialmente.
   if (totale !== undefined && totale !== p.total) throw new ErroreMessaggiKeplero('risposta_non_valida');
   totale = p.total as number;
   const attesi = Math.min(100, Math.max(0, totale - (page - 1) * 100));
   if (dati.data.length !== attesi) throw new ErroreMessaggiKeplero('risposta_non_valida');
   messaggi.push(...dati.data);
   if (page * 100 >= totale) return messaggi;
  }
  throw new ErroreMessaggiKeplero('limite_superato');
 } catch (error) {
  if (error instanceof ErroreMessaggiKeplero) throw error;
  // Non includere URL, body del provider, header o chiave negli errori/log.
  throw new ErroreMessaggiKeplero('non_disponibile');
 }
}

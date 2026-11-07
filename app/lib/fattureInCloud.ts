/** Client API v2 in sola lettura. Nessun URL o metodo HTTP è fornito dal chiamante. */
export const TIPI_FIC = { invoice: 'Fatture', quote: 'Preventivi', order: 'Ordini', proforma: 'Proforma' } as const;
export type TipoFic = keyof typeof TIPI_FIC;
export type ConfigFic = { token: string; companyId: string; partitaIva: string };
export type RicercaFic = { tipo: TipoFic; dal: string; al: string; cerca: string };
export type DocumentoFic = {
  id: number; tipo: TipoFic; data: string; numero: string; cliente: string;
  partitaIva: string; codiceFiscale: string; oggetto: string; note: string;
  importo: number | null; valuta: string;
  righe: { codice: string; nome: string; descrizione: string }[];
  pagamenti: { importo: number | null; scadenza: string; stato: string }[];
};
export type RisultatoFic = { documenti: DocumentoFic[]; esaminati: number; totale: number; completo: boolean; verificatoAlle: string };
const ERRORI = {
  configurazione: 'Collegamento Fatture in Cloud da configurare sul server.',
  parametri: 'Seleziona un tipo valido e un intervallo di massimo 31 giorni. La ricerca può contenere fino a 100 caratteri.',
  autorizzazione: 'Token non valido o permessi insufficienti in Fatture in Cloud.',
  azienda: 'Il token non autorizza l’azienda configurata con la partita IVA attesa.',
  quota: 'Limite API di Fatture in Cloud raggiunto. Riprova più tardi.',
  risposta: 'Risposta di Fatture in Cloud incompleta o non valida. Nessun risultato confermato.',
  rete: 'Fatture in Cloud non è raggiungibile al momento. Riprova più tardi.',
} as const;
export class ErroreFic extends Error {
  readonly codice: keyof typeof ERRORI;
  constructor(codice: keyof typeof ERRORI) { super(ERRORI[codice]); this.codice = codice; }
}
type Oggetto = Record<string, unknown>;
function oggetto(x: unknown): Oggetto {
  if (!x || typeof x !== 'object' || Array.isArray(x)) throw new ErroreFic('risposta');
  return x as Oggetto;
}
function testo(x: unknown): string { return typeof x === 'string' ? x : ''; }
function denaro(x: unknown): number | null { return typeof x === 'number' && Number.isFinite(x) ? x : null; }
function dataValida(x: string): boolean {
  return /^\d{4}-\d{2}-\d{2}$/.test(x) && Number.isFinite(Date.parse(x)) && new Date(x).toISOString().slice(0, 10) === x;
}
function intero(x: unknown, minimo = 0): x is number { return Number.isSafeInteger(x) && (x as number) >= minimo; }
export function validaRicercaFic(input: Record<string, unknown>): RicercaFic {
  const tipo = input.tipo, dal = testo(input.dal), al = testo(input.al), cerca = input.cerca === undefined ? '' : input.cerca;
  if (typeof tipo !== 'string' || !Object.hasOwn(TIPI_FIC, tipo) || !dataValida(dal) || !dataValida(al)
    || al < dal || Date.parse(al) - Date.parse(dal) > 30 * 86400000 || typeof cerca !== 'string'
    || cerca.length > 100 || /[\x00-\x1f]/.test(cerca)) throw new ErroreFic('parametri');
  return { tipo: tipo as TipoFic, dal, al, cerca: cerca.trim() };
}
export function validaConfigFic(config: ConfigFic): ConfigFic {
  const token = config.token.trim();
  if (!token || token.length > 16000 || /\s/.test(token) || !/^[1-9]\d{0,14}$/.test(config.companyId)
    || !/^\d{11}$/.test(config.partitaIva)) throw new ErroreFic('configurazione');
  return { ...config, token };
}
// La ricerca considera anche codici con punti, spazi e trattini (es. 10.0206-0410.4).
function normalizza(x: string): string { return x.normalize('NFKD').replace(/[\u0300-\u036f]/g, '').toUpperCase().replace(/[^A-Z0-9]/g, ''); }
export function corrispondeFic(d: DocumentoFic, ricerca: string): boolean {
  if (!ricerca) return true;
  const q = normalizza(ricerca);
  if (!q) return false;
  return [d.numero, d.cliente, d.partitaIva, d.codiceFiscale, d.oggetto, d.note,
    ...d.righe.flatMap(r => [r.codice, r.nome, r.descrizione])].some(v => normalizza(v).includes(q));
}
function documento(x: unknown, tipo: TipoFic): DocumentoFic {
  const d = oggetto(x), e = oggetto(d.entity);
  if (!intero(d.id, 1) || d.type !== tipo || !dataValida(testo(d.date)) || !testo(e.name)) throw new ErroreFic('risposta');
  if (!(Array.isArray(d.items_list) || d.items_list === null) || !(Array.isArray(d.payments_list) || d.payments_list === null)) throw new ErroreFic('risposta');
  return {
    id: d.id, tipo, data: testo(d.date), numero: `${d.number ?? ''}${testo(d.numeration)}`,
    cliente: testo(e.name), partitaIva: testo(e.vat_number), codiceFiscale: testo(e.tax_code),
    oggetto: [testo(d.subject), testo(d.visible_subject)].filter(Boolean).join(' · '), note: testo(d.notes),
    importo: denaro(d.amount_gross), valuta: testo(oggetto(d.currency).id),
    righe: (d.items_list ?? []).map(v => { const r = oggetto(v); return { codice: testo(r.code), nome: testo(r.name), descrizione: testo(r.description) }; }),
    pagamenti: (d.payments_list ?? []).map(v => { const p = oggetto(v); return { importo: denaro(p.amount), scadenza: testo(p.due_date), stato: testo(p.status) }; }),
  };
}
export function creaClientFic(configInput: ConfigFic, richiedi: typeof fetch = fetch) {
  const config = validaConfigFic(configInput);
  async function get(path: string, signal: AbortSignal): Promise<Oggetto> {
    let r: Response;
    try {
      r = await richiedi(`https://api-v2.fattureincloud.it${path}`, {
        method: 'GET', headers: { Authorization: `Bearer ${config.token}`, Accept: 'application/json' },
        cache: 'no-store', redirect: 'error', signal,
      });
    } catch { throw new ErroreFic('rete'); }
    if (!r.ok) {
      await r.body?.cancel();
      throw new ErroreFic(r.status === 401 || r.status === 403 ? 'autorizzazione' : r.status === 429 ? 'quota' : 'rete');
    }
    // Limite anche per risposte prive di Content-Length. Mai propagare corpi o errori remoti.
    const reader = r.body?.getReader(); if (!reader) throw new ErroreFic('risposta');
    const chunks: Uint8Array[] = []; let size = 0;
    try {
      for (;;) {
        const chunk = await reader.read(); if (chunk.done) break;
        size += chunk.value.byteLength;
        if (size > 4_000_000) { await reader.cancel(); throw new ErroreFic('risposta'); }
        chunks.push(chunk.value);
      }
      return oggetto(JSON.parse(Buffer.concat(chunks).toString('utf8')));
    } catch { throw new ErroreFic('risposta'); }
  }
  async function verificaAzienda(signal: AbortSignal) {
    const body = await get('/user/companies', signal), data = oggetto(body.data);
    if (!Array.isArray(data.companies)) throw new ErroreFic('risposta');
    const azienda = data.companies.map(oggetto).find(c => String(c.id) === config.companyId);
    const iva = String(azienda?.vat_number ?? '').replace(/^IT/i, '').padStart(11, '0');
    if (!azienda || iva !== config.partitaIva) throw new ErroreFic('azienda');
    // Non restituire il payload: può contenere access_token delle aziende.
    return { id: config.companyId, nome: testo(azienda.name), partitaIva: config.partitaIva };
  }
  return {
    verifica: () => verificaAzienda(AbortSignal.timeout(15000)),
    async cerca(input: RicercaFic): Promise<RisultatoFic> {
      const filtro = validaRicercaFic(input), signal = AbortSignal.timeout(45000);
      await verificaAzienda(signal);
      const righe: DocumentoFic[] = [], ids = new Set<number>();
      let totale: number | null = null, ultimaPagina = 1;
      for (let page = 1; page <= 10; page++) {
        const params = new URLSearchParams({ type: filtro.tipo, fieldset: 'detailed', sort: '-date,-number',
          per_page: '50', page: String(page), q: `date >= '${filtro.dal}' and date <= '${filtro.al}'` });
        const body = await get(`/c/${config.companyId}/issued_documents?${params}`, signal);
        if (!Array.isArray(body.data) || !intero(body.total) || !intero(body.last_page, 1)
          || body.current_page !== page || body.data.length > 50 || (totale !== null && totale !== body.total)) throw new ErroreFic('risposta');
        totale = body.total; ultimaPagina = body.last_page;
        for (const r of body.data) {
          const d = documento(r, filtro.tipo);
          if (ids.has(d.id) || d.data < filtro.dal || d.data > filtro.al) throw new ErroreFic('risposta');
          ids.add(d.id); righe.push(d);
        }
        if (page >= ultimaPagina) {
          if (righe.length !== totale) throw new ErroreFic('risposta');
          break;
        }
        if (body.data.length === 0) throw new ErroreFic('risposta');
      }
      return { documenti: righe.filter(d => corrispondeFic(d, filtro.cerca)), esaminati: righe.length,
        totale: totale!, completo: ultimaPagina <= 10, verificatoAlle: new Date().toISOString() };
    },
  };
}

import type { DocumentoFic } from './fattureInCloud';

export type PraticaFic = { id: string; numero_pratica: number; targa: string | null;
  nome_cliente: string | null; created_at: string; tipo_flusso: string; archiviata_test?: string; archiviata_duplicato?: string;
  clienti: { partita_iva: string | null; codice_fiscale: string | null } | null };
export type AbbinamentoFic = { stato: 'univoco' | 'ambiguo' | 'assente'; candidati: PraticaFic[]; motivo: string };
const normalizza = (s: string | null) => (s || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
const iva = (s: string | null) => normalizza(s).replace(/^IT(?=\d{11}$)/, '');

/** Soltanto proposte: una targa o un codice ricambio non chiudono una pratica. */
export function abbinaFic(d: DocumentoFic, pratiche: PraticaFic[]): AbbinamentoFic {
  const testo = [d.oggetto, d.note, ...d.righe.flatMap(r => [r.nome, r.descrizione])].join('\n').toUpperCase();
  const numeri = [...testo.matchAll(/\bPRATICA\s*(?:N[.°º]?\s*)?#?\s*(\d{1,10})\b/g)].map(m => Number(m[1]));
  const targhe = new Set([...testo.matchAll(/\b([A-Z]{2}[ -]?\d{3}[ -]?[A-Z]{2})\b/g)].map(m => normalizza(m[1])));
  const compatibili = pratiche.filter(p => {
    if (p.tipo_flusso !== 'commerciale' || p.created_at.slice(0,10) > d.data || p.archiviata_test==='true' || p.archiviata_duplicato==='true') return false;
    const c = p.clienti;
    const stessaIva = !!iva(d.partitaIva) && iva(d.partitaIva) === iva(c?.partita_iva || '');
    const stessoCf = !!normalizza(d.codiceFiscale) && normalizza(d.codiceFiscale) === normalizza(c?.codice_fiscale || '');
    const conflittoIva = !!iva(d.partitaIva) && !!iva(c?.partita_iva || '') && !stessaIva;
    const conflittoCf = !!normalizza(d.codiceFiscale) && !!normalizza(c?.codice_fiscale || '') && !stessoCf;
    const targa = normalizza(p.targa);
    return !conflittoIva && !conflittoCf && (stessaIva || stessoCf) && !!targa && targhe.has(targa)
      && (!numeri.length || numeri.includes(p.numero_pratica));
  });
  // Un documento con più targhe/riferimenti richiede revisione anche se una sola pratica è presente.
  const univoco = compatibili.length === 1 && targhe.size === 1 && new Set(numeri).size <= 1;
  return { stato: !compatibili.length ? 'assente' : univoco ? 'univoco' : 'ambiguo', candidati: compatibili,
    motivo: !compatibili.length ? 'Nessuna pratica con targa e identità fiscale concordanti.'
      : univoco ? 'Targa e identità fiscale concordanti. Verificare servizio, data e documento prima di aggiornare la pratica.'
        : 'Più targhe, riferimenti o pratiche compatibili: verifica manuale richiesta.' };
}

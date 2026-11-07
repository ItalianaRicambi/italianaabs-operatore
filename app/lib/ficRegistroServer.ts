import 'server-only';
import { clientFic } from './fattureInCloudServer';
import { validaRicercaFic, type DocumentoFic, type TipoFic } from './fattureInCloud';
import type { PraticaFic } from './abbinamentiFic';

export type RegistroFic = { documento_id: number; documento: DocumentoFic; presente: boolean; verificato_at: string };
export function ambienteFic() { return process.env.VERCEL_ENV === 'production' ? 'production' : 'preview'; }
async function db(path: string, body?: unknown, conTotale = false) {
  const url = process.env.SUPABASE_URL, key = process.env.SUPABASE_SECRET_KEY;
  if (!url || !key) throw new Error('Registro documenti non configurato.');
  const r = await fetch(`${url}/rest/v1/${path}`, { method: body === undefined ? 'GET' : 'POST',
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', ...(conTotale?{Prefer:'count=exact'}:{}) },
    body: body === undefined ? undefined : JSON.stringify(body), cache: 'no-store', signal: AbortSignal.timeout(20000) });
  if (!r.ok) { await r.body?.cancel(); throw new Error('Registro documenti non disponibile. Nessun aggiornamento confermato.'); }
  const dati = await r.json();
  if (!conTotale) return dati;
  const totale = r.headers.get('content-range')?.split('/')[1];
  if (!totale || !/^\d+$/.test(totale) || !Array.isArray(dati)) throw new Error('Elenco pratiche incompleto.');
  return {righe:dati, totale:Number(totale)};
}
export async function sincronizzaFic(tipo: TipoFic, dal: string, al: string) {
  const filtro = validaRicercaFic({ tipo, dal, al, cerca: '' });
  const avvio = new Date().toISOString();
  const r = await clientFic().cerca(filtro);
  if (!r.completo) throw new Error('Periodo troppo ampio: ridurlo prima di sincronizzare. Nessun documento salvato.');
  return db('rpc/fic_registra_snapshot', { p_ambiente: ambienteFic(), p_tipo: tipo, p_dal: dal, p_al: al,
    p_avvio: avvio, p_documenti: r.documenti });
}
export async function leggiRegistroFic() {
  return await db(`fic_documenti?ambiente=eq.${ambienteFic()}&select=documento_id,documento,presente,verificato_at&order=data_documento.desc,documento_id.desc&limit=100`) as RegistroFic[];
}
export async function quotaMcpFic(userId: string): Promise<boolean> {
  return (await db('rpc/fic_mcp_consuma_quota', {p_user_id:userId})) === true;
}
export async function pratichePerFic(): Promise<PraticaFic[]> {
  // Offset e limite espliciti: mai presentare un abbinamento come univoco su una lista troncata.
  const righe: PraticaFic[] = [];
  let atteso:number|null=null;
  for (let page=0;page<20;page++) {
    const r = await db(`pratiche?select=id,numero_pratica,targa,nome_cliente,created_at,tipo_flusso,archiviata_test:dati_raw->archiviazione_test->>archiviata,archiviata_duplicato:dati_raw->pratica_duplicata->>archiviata,clienti(partita_iva,codice_fiscale)&tipo_flusso=eq.commerciale&order=id&limit=500&offset=${righe.length}`,undefined,true) as {righe:PraticaFic[];totale:number};
    if(atteso!==null && atteso!==r.totale) throw new Error('Elenco pratiche variato: riprovare.');
    atteso=r.totale;
    righe.push(...r.righe);
    if(new Set(righe.map(p=>p.id)).size!==righe.length) throw new Error('Elenco pratiche variato: riprovare.');
    if(righe.length===atteso) return righe;
    if(!r.righe.length || righe.length>atteso) throw new Error('Elenco pratiche incompleto.');
  }
  throw new Error('Troppe pratiche per verificare gli abbinamenti: nessuna proposta confermata.');
}

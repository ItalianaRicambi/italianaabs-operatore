import 'server-only';
import { fetchTutteLePagine } from './supabaseRest';
import type { EsitoGls } from './esitiGls';

export function connessioneGlsDb() {
 const url = process.env.SUPABASE_URL || process.env.NEXT_PUBLIC_SUPABASE_URL;
 const key = process.env.SUPABASE_SECRET_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY;
 if (!url || !key) throw new Error('Connessione database non disponibile.');
 return { url, headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' } };
}
export async function leggiEsitiGls(praticaId?: string) {
 try {
  const { url, headers } = connessioneGlsDb();
  const righe = await fetchTutteLePagine<EsitoGls>(`${url}/rest/v1/v_esiti_prese_gls_correnti?select=*&order=verificata_at.desc,id.asc${praticaId ? `&pratica_id=eq.${encodeURIComponent(praticaId)}` : ''}`, { headers });
  return { righe, errore: null };
 } catch { return { righe: [] as EsitoGls[], errore: 'Impossibile leggere gli esiti GLS. Riprova o verifica il collegamento.' }; }
}
export async function registraEsitoGls(dati: unknown, attivitaId: string | null, operatore: string | null) {
 const { url, headers } = connessioneGlsDb();
 const r = await fetch(`${url}/rest/v1/rpc/registra_esito_presa_gls`, { method: 'POST', headers,
  body: JSON.stringify({ p_dati: dati, p_attivita_id: attivitaId, p_operatore: operatore }), cache: 'no-store' });
 if (!r.ok) throw new Error('Esito GLS non registrato. Verifica i dati e il ritiro collegato.');
 return await r.json() as { esito: string; stato: string; pratica_id: string | null };
}

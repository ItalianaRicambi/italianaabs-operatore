import { randomUUID } from 'node:crypto';
import type { ReactNode } from 'react';
import { ContestoNavigazioneElenco, type VoceElenco } from './NavigazionePratiche';
import { numeroPratica, type ShopifyCoda } from '../lib/codaOrdini';

// Stesso ordine visivo; gli ordini senza pratica restano nella pagina, non nelle frecce.
export function vociOrdini(shopify: ShopifyCoda[], pratiche: { pratica_id: string; numero_pratica: number }[]): VoceElenco[] {
  return [
    ...shopify.flatMap(r => r.pratica_id ? [{ id: r.pratica_id, codice: `Shopify ${r.dati.numero}`, ancora: `shopify-${r.dati.ordine_id}` }] : []),
    ...pratiche.map(p => ({ id: p.pratica_id, codice: numeroPratica(p.numero_pratica) })),
  ];
}

export function ContestoOrdini({ filtro, etichetta, voci, children }: {
  filtro: string; etichetta: string; voci: VoceElenco[]; children: ReactNode;
}) {
  const viste = new Set<string>();
  const uniche = voci.filter(v => {
    if (viste.has(v.id)) return false;
    viste.add(v.id);
    return true;
  });
  return <ContestoNavigazioneElenco chiave={randomUUID()} filtro={filtro}
    etichetta={etichetta} cerca="" ritorno="/ordini" voci={uniche}>
    {children}
  </ContestoNavigazioneElenco>;
}

import Link from 'next/link';
import { statoOrdiniShopify } from '../lib/ordiniShopifyServer';
export async function StatoOrdiniShopify() {
  const stato = await statoOrdiniShopify().catch(() => null);
  const configurato = !!process.env.SHOPIFY_WEBHOOK_SECRET && process.env.SHOPIFY_WEBHOOK_SECRET.length >= 32;
  return <section className="mb-6 rounded-2xl border border-blue-200 bg-white p-5">
    <div className="flex flex-wrap items-center justify-between gap-3"><h2 className="text-lg font-bold text-blue-950">Ordini pervenuti da Shopify: {stato ? stato.ricevuti : 'da verificare'}</h2><Link href="/shopify" className="rounded-lg bg-blue-700 px-4 py-2 text-sm font-bold text-white">Apri ordini e verifiche IVA</Link></div>
    {!configurato ? <p role="alert" className="mt-3 text-sm font-semibold text-amber-900">Acquisizione automatica da collegare: questo contatore non conferma ancora la ricezione di tutti gli ordini.</p>
      : !stato?.ultimo_evento_at && <p role="alert" className="mt-3 text-sm text-amber-900">Collegamento predisposto, in attesa del primo evento Shopify verificato.</p>}
    {stato ? <p className="mt-3 text-sm">Pronti per la stesura: {stato.pronti} · In attesa del pagamento PS/PSMI: {stato.attesa_pagamento} · Verifiche IVA: <strong>{stato.verifiche_iva}</strong><br />Ultima acquisizione: {stato.ultimo_evento_at ? new Date(stato.ultimo_evento_at).toLocaleString('it-IT', { timeZone: 'Europe/Rome' }) : 'nessuna'}</p>
      : <p role="alert" className="mt-3 text-sm text-red-800">Registro ordini non disponibile: verificare il collegamento.</p>}
  </section>;
}

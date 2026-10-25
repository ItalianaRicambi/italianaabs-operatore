import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getOperatoreAttivo } from '../operatore';
import { BarraOperatore } from '../components/IdentitaOperatore';
import { leggiOrdiniShopify } from '../lib/ordiniShopifyServer';
import type { IndirizzoShopify } from '../lib/ordiniShopify';
function indirizzo(a: IndirizzoShopify) { return [a.azienda || a.nome, a.via, [a.cap, a.citta, a.provincia].filter(Boolean).join(' '), a.paese].filter(Boolean).join(' · ') || 'Da verificare'; }
const valuta = (centesimi: number, codice: string) => new Intl.NumberFormat('it-IT', { style: 'currency', currency: codice }).format(centesimi / 100);
const IVA = { iva_applicata: 'IVA applicata', esenzione_shopify: 'IVA non addebitata da Shopify', da_verificare: 'IVA da verificare' };
export default async function OrdiniShopify() {
  const operatore = await getOperatoreAttivo(); if (!operatore) redirect('/');
  const righe = await leggiOrdiniShopify().catch(() => null);
  return <main className="min-h-screen bg-slate-50"><BarraOperatore operatore={operatore} /><div className="mx-auto max-w-5xl px-6 py-8">
    <Link href="/" className="font-bold text-blue-800 underline">Torna alla dashboard</Link><h1 className="mt-4 text-3xl font-bold">Ordini Shopify e verifica IVA</h1>
    <p className="mt-3 text-slate-600">L’operatore prepara il documento d’ordine. Il pagamento anticipato è richiesto per PS/PSMI; per RE/RI può avvenire a fine lavori. Le verifiche IVA precedono la fatturazione.</p>
    {!righe ? <p role="alert" className="mt-5 text-red-800">Registro non disponibile. Verificare l’acquisizione degli ordini.</p> : <>
      <p className="my-5 text-sm">Ordini attivi mostrati: {righe.length} (massimo 200). Ordini di prova e annullati esclusi.</p>
      {!righe.length && <p className="rounded-xl border bg-white p-5">Nessun ordine operativo acquisito. La sola assenza di righe non conferma che il collegamento sia attivo.</p>}
      <div className="space-y-4">{righe.map(r => <section key={r.id} className={`rounded-xl border bg-white p-5 ${r.valutazione.verifica_iva || r.conflitto ? 'border-amber-400' : 'border-slate-200'}`}>
        <div className="flex flex-wrap justify-between gap-3"><h2 className="text-lg font-bold">{r.dati.numero} · {r.dati.cliente}</h2><strong>{valuta(r.dati.totale, r.dati.valuta)}</strong></div>
        <p className="mt-2 text-sm">Soluzioni: {r.dati.servizi.join(', ')} · Pagamento Shopify: {r.dati.stato_pagamento}</p>
        <p className="mt-2 font-semibold">{r.conflitto ? 'Verificare gli aggiornamenti discordanti prima della stesura dell’ordine.' : r.valutazione.motivazione_ordine}</p>
        {r.conflitto && <p role="alert" className="mt-3 font-bold text-red-800">Aggiornamenti discordanti: verificare l’ordine originale prima di procedere.</p>}
        <div className="mt-4 rounded-lg bg-amber-50 p-3"><h3 className="font-bold">{IVA[r.valutazione.stato_iva]}{r.valutazione.verifica_iva ? ' · controllo operatore richiesto' : ''}</h3><p className="mt-1 text-sm">{r.valutazione.messaggio_iva}</p><p className="mt-2 text-sm">IVA ordine: {r.dati.iva === null ? 'non trasmessa' : valuta(r.dati.iva, r.dati.valuta)} · Partita IVA dichiarata negli attributi ordine: {r.dati.partita_iva_discordante ? 'valori discordanti; consultare Shopify' : r.dati.partita_iva_dichiarata || 'non trasmessa; consultare Shopify'}</p></div>
        <dl className="mt-4 space-y-2 text-sm"><div><dt className="font-bold">Fatturazione</dt><dd>{indirizzo(r.dati.fatturazione)}</dd></div><div><dt className="font-bold">Spedizione</dt><dd>{indirizzo(r.dati.spedizione)}</dd></div></dl>
        <ul className="mt-4 list-inside list-disc text-sm">{r.dati.articoli.map((a, i) => <li key={i}>{a.quantita} × {a.titolo} · {a.variante || 'variante da verificare'}</li>)}</ul>
        <div className="mt-4 flex flex-wrap gap-4"><a href={`https://admin.shopify.com/store/j4mqgv-am/orders/${r.dati.ordine_id}`} target="_blank" rel="noopener noreferrer" className="font-bold text-blue-800 underline">Apri ordine originale Shopify</a>{r.pratica_id && <Link href={`/pratica/${r.pratica_id}`} className="font-bold text-blue-800 underline">Apri pratica collegata</Link>}</div>
      </section>)}</div>
    </>}
  </div></main>;
}

import Link from 'next/link';
import { redirect } from 'next/navigation';
import { getOperatoreAttivo } from '../operatore';
import { BarraOperatore } from '../components/IdentitaOperatore';
import { leggiCodaOrdini } from '../lib/codaOrdiniServer';
import { classificaCoda, numeroPratica, oraRoma, type EvasionePratica } from '../lib/codaOrdini';
import { FormEvasione } from './FormEvasione';
import type { RigaOrdineShopify } from '../lib/ordiniShopifyServer';
export const dynamic = 'force-dynamic';
function Pratica({p}:{p:EvasionePratica}) {
 return <article id={'pratica-'+p.pratica_id} className="rounded-xl border bg-white p-4">
 <h3 className="font-bold">{numeroPratica(p.numero_pratica)} · {p.targa || 'Targa mancante'}</h3>
 <p>Evasione: {p.stato} · Fatturazione: {p.stato_fatturazione}</p><p className="mt-1 text-sm">{p.nota}</p>
 {p.blocco_operatore && <p className="font-bold text-amber-900">Blocco operatore attivo: non viene modificato.</p>}
 <Link href={'/pratica/'+p.pratica_id} className="mt-2 inline-block font-bold text-blue-800 underline">Apri pratica →</Link>
 {p.shopify_order_id ? <p className="mt-2 text-amber-900">Riferimento Shopify presente: verificare l’ordine originale e il collegamento. Evasione gestita su Shopify.</p> : <FormEvasione id={p.pratica_id} revisione={p.revisione} stato={p.stato} tipo="evasione"/>}
 </article>;
}
function Shopify({r}:{r:RigaOrdineShopify}) {
 return <article id={'shopify-'+r.dati.ordine_id} className="rounded-xl border bg-white p-4">
 <h3 className="font-bold">Shopify {r.dati.numero} · {r.dati.servizi.join(', ')}</h3>
 <p>Evasione: {r.dati.stato_evasione || 'da_verificare'} · Pagamento: {r.dati.stato_pagamento}</p>
 <p className="mt-1 text-sm">{r.conflitto?'Aggiornamenti discordanti: verificare l’originale.':r.valutazione.motivazione_ordine}</p>
 <ul className="mt-2 list-inside list-disc text-sm">{r.dati.articoli.map((a,i)=><li key={i}>{a.quantita} × {a.titolo} · {a.variante}</li>)}</ul>
 <p className="mt-2 font-bold">{r.pratica_id?'Pratica collegata':'Pratica non collegata: l’ordine resta comunque visibile e da gestire.'}</p>
 <a href={'https://admin.shopify.com/store/j4mqgv-am/orders/'+r.dati.ordine_id} target="_blank" rel="noopener noreferrer" className="mt-2 inline-block font-bold text-blue-800 underline">Apri originale Shopify →</a>
 {r.pratica_id && <Link href={'/pratica/'+r.pratica_id} className="ml-4 underline">Apri pratica</Link>}
 </article>;
}
export default async function Ordini() {
 const operatore = await getOperatoreAttivo(); if(!operatore) redirect('/');
 let d; try {d=await leggiCodaOrdini();} catch {return <main className="p-8"><h1>Coda ordini non disponibile</h1><p role="alert">Errore di lettura: non è possibile attestare la completezza degli ordini.</p><Link href="/">Torna alla dashboard</Link></main>;}
 const c=classificaCoda(d.shopify,d.pratiche), byId=new Map(d.shopify.map(r=>[r.id,r]));
 return <main className="min-h-screen bg-slate-50"><BarraOperatore operatore={operatore}/><div className="mx-auto max-w-6xl space-y-6 px-6 py-8">
 <div className="flex flex-wrap justify-between gap-3"><Link href="/" className="font-bold underline">← Dashboard</Link><Link href="/ordini" prefetch={false} className="font-bold underline">Aggiorna elenco</Link><Link href="/shopify" className="font-bold underline">Registro Shopify e IVA</Link></div>
 <h1 className="text-3xl font-black">Ordini da evadere</h1>
 <p>Fatturazione ed evasione sono indipendenti. Una fattura, un pagamento o una prenotazione del corriere non attestano l’evasione. Gli ordini Shopify senza pratica non sono esclusi.</p>
 {d.errori.length>0 && <p role="alert" className="rounded border-2 border-red-700 p-4 font-bold text-red-800">Dati incompleti: {d.errori.join(', ')} non disponibili. I conteggi non attestano la copertura.</p>}
 <section className="space-y-3"><h2 className="text-xl font-bold">Shopify da evadere ({c.shopifyAperti.length})</h2>{c.shopifyAperti.map(r=><Shopify key={r.id} r={byId.get(r.id)!}/>)}</section>
 <section className="space-y-3"><h2 className="text-xl font-bold">Pratiche confermate da evadere ({c.praticheAperte.length})</h2>{c.praticheAperte.map(p=><Pratica key={p.pratica_id} p={p}/>)}</section>
 <section className="space-y-3"><h2 className="text-xl font-bold">Accettazioni e ordini dichiarati da verificare ({new Set(d.verifiche.map(v=>v.pratica_id)).size} pratiche)</h2>
 <p>Prove letterali da verificare con offerta, opzione scelta e possibili revoche. Nessuna acquisizione automatica e nessun aggiramento dei blocchi.</p>
 {d.verifiche.map(v=><article key={v.id} className="rounded-xl border border-amber-400 bg-amber-50 p-4">
 <h3 className="font-bold">{numeroPratica(v.numero_pratica)} · {v.targa || 'Targa mancante'} · stato: {v.stato_commerciale}</h3>
 <p className="mt-2">«{v.messaggio}»</p><p className="text-sm">Evento {v.evento_id} · {oraRoma(v.evento_at)} Europe/Rome</p>
 {v.possibile_revoca && <p className="font-bold text-red-800">Possibile revoca successiva: leggere la conversazione prima di acquisire l’ordine.</p>}
 {v.blocco_operatore && <p className="font-bold">Blocco operatore presente: da rispettare.</p>}
 <Link href={'/pratica/'+v.pratica_id+'#sezione-offerta'} className="mt-2 inline-block font-bold underline">Verifica offerta e scelta nella pratica →</Link>
 <FormEvasione tipo="verifica" id={v.id}/></article>)}</section>
 <section className="space-y-3"><h2 className="text-xl font-bold">Stato Shopify da verificare ({c.shopifyDaVerificare.length})</h2>{c.shopifyDaVerificare.map(r=><Shopify key={r.id} r={byId.get(r.id)!}/>)}</section>
 <details className="rounded-xl border bg-white p-4"><summary className="cursor-pointer text-xl font-bold">Storico con evasione non attestata ({c.praticheDaVerificare.length})</summary><p className="my-3">La fattura non prova che siano ancora aperti né già evasi. Verifica documentale necessaria; non classificati automaticamente come urgenti.</p><div className="space-y-3">{c.praticheDaVerificare.map(p=><Pratica key={p.pratica_id} p={p}/>)}</div></details>
 <details className="rounded-xl border bg-white p-4"><summary className="cursor-pointer font-bold">Evasi ({c.shopifyEvasi.length+c.praticheEvase.length})</summary><div className="mt-3 space-y-3">{c.shopifyEvasi.map(r=><Shopify key={r.id} r={byId.get(r.id)!}/>)}{c.praticheEvase.map(p=><Pratica key={p.pratica_id} p={p}/>)}</div></details>
 <p className="rounded border border-amber-400 bg-amber-50 p-4">Copertura Shopify: eventi ricevuti, non riconciliazione completa della sorgente. La riconciliazione periodica con l’API Shopify deve essere attivata e collaudata; l’assenza di eventi non dimostra l’assenza di ordini. Evaso su Shopify non significa consegnato al destinatario.</p>
 </div></main>;
}

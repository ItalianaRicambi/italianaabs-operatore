import Link from 'next/link';
import { leggiCodaOrdini } from '../lib/codaOrdiniServer';
import { classificaCoda, numeroPratica } from '../lib/codaOrdini';
import { CoperturaShopify } from './CoperturaShopify';
export async function CodaOrdini() {
 let dati;
 try { dati = await leggiCodaOrdini(); } catch { return <section role="alert" className="mb-5 rounded-xl border-2 border-red-700 p-5 text-red-800">Coda ordini non disponibile: non è possibile attestare che tutti gli ordini siano visibili. <Link href="/ordini" className="underline">Apri controllo ordini</Link></section>; }
 const c = classificaCoda(dati.shopify,dati.pratiche);
 const n = c.shopifyAperti.length+c.praticheAperte.length;
 const verifiche = [...new Map(dati.verifiche.map(v=>[v.pratica_id,v])).values()];
 return <section className="mb-6 rounded-2xl border-2 border-blue-800 bg-blue-50 p-5 text-blue-950">
  <h2 className="text-xl font-black">{n} ORDINI DA EVADERE · Shopify incluso</h2>
  <p className="mt-2">{c.shopifyAperti.length} Shopify · {c.praticheAperte.length} pratiche confermate. La fattura non chiude l’evasione.</p>
  {dati.errori.length>0 && <p role="alert" className="mt-2 font-bold text-red-800">Conteggio incompleto: lettura non riuscita per {dati.errori.join(', ')}.</p>}
  <div className="mt-3 flex flex-wrap gap-2">
   {c.shopifyAperti.slice(0,6).map(r=><Link key={r.id} href={'/ordini#shopify-'+r.dati.ordine_id} className="rounded border bg-white px-3 py-2 font-bold">Shopify {r.dati.numero}{!r.pratica_id?' · da collegare':''} →</Link>)}
   {c.praticheAperte.slice(0,6).map(p=><Link key={p.pratica_id} href={'/pratica/'+p.pratica_id} className="rounded border bg-white px-3 py-2 font-bold">{p.targa || numeroPratica(p.numero_pratica)} →</Link>)}
  </div>
  <p className="mt-3 font-bold">{verifiche.length} pratiche con accettazione / ordine dichiarato da verificare · {c.praticheDaVerificare.length+c.shopifyDaVerificare.length} evasioni non attestate</p>
  {verifiche.length>0 && <p className="mt-1 text-sm">{verifiche.slice(0,5).map(v=>v.targa || numeroPratica(v.numero_pratica)).join(' · ')} — non ancora ordini confermati.</p>}
  <Link href="/ordini" prefetch={false} className="mt-4 inline-flex rounded-lg bg-blue-900 px-4 py-3 font-bold text-white">Apri ordini, evasioni e verifiche →</Link>
  <CoperturaShopify/>
 </section>;
}

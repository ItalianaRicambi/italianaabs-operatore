import { leggiStatoSync } from '../lib/shopifySyncServer';
import { problemaSync } from '../lib/shopifyApi';
import { oraRoma } from '../lib/codaOrdini';
export async function CoperturaShopify() {
 const stato=await leggiStatoSync().catch(()=>null), problema=problemaSync(stato);
 return <div className={'mt-3 rounded border p-3 text-sm '+(problema?'border-red-700 bg-red-50 text-red-900':'border-blue-300 bg-white')}>
  {problema && <p role="alert" className="font-bold">{problema} La completezza degli ordini non è attestata.</p>}
  {stato?.ultimo_successo_at && <p>Ultima lettura API completata: {oraRoma(stato.ultimo_successo_at)} Europe/Rome · {stato.ordini_letti} ordini letti.</p>}
  <p>Controllo previsto ogni 5 minuti, anche nel weekend. Accesso limitato agli ordini creati negli ultimi 60 giorni; lo storico locale resta conservato. Evaso non significa consegnato. Gli ordini non più accessibili richiedono verifica su Shopify.</p>
 </div>;
}

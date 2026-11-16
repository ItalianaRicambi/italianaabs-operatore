import 'server-only';
import { cache } from 'react';
import { connessioneGlsDb } from './glsServer';
import { fetchTutteLePagine } from './supabaseRest';
import { leggiOrdiniShopify } from './ordiniShopifyServer';
import type { EvasionePratica, VerificaOrdine } from './codaOrdini';
export const leggiCodaOrdini = cache(async () => {
 const {url,headers} = connessioneGlsDb();
 const risultati = await Promise.allSettled([
  leggiOrdiniShopify(false),
  fetchTutteLePagine<EvasionePratica>(url+'/rest/v1/v_evasioni_pratiche?select=*&order=updated_at.desc,pratica_id.asc',{headers}),
  fetchTutteLePagine<VerificaOrdine>(url+'/rest/v1/v_verifiche_acquisizione_ordini?select=*&order=evento_at.desc,id.asc',{headers}),
 ]);
 const [shopify,pratiche,verifiche] = risultati;
 return {
  shopify: shopify.status === 'fulfilled' ? shopify.value : [],
  pratiche: pratiche.status === 'fulfilled' ? pratiche.value : [],
  verifiche: verifiche.status === 'fulfilled' ? verifiche.value : [],
  errori: risultati.flatMap((r,i) => r.status === 'rejected' ? [['Shopify','Evasioni pratiche','Conferme da verificare'][i]] : []),
 };
});

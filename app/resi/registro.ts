import 'server-only';
import {connessioneGlsDb} from '../lib/glsServer';
import {fetchTutteLePagine} from '../lib/supabaseRest';

export type Dettagli = Record<string,string>;
export type Reso = {
 id:string; fattura:string; data_fattura:string; cliente:string; veicolo:string; componente:string;
 stato:string; spedizione:string|null; prossima:string|null; sei_mesi:string|null; ultimo_invio:string|null;
 riesame:boolean; fonte:string; nota:string; presa:string|null; pratica_id:string|null;
 decisione:Dettagli|null; comunicazione:Dettagli|null; revisione:number; unico_tentativo:string|null;
};
export type Evento = {id:string; data_evento:string; dettagli:Dettagli; tipo:string; autore:string};
export function leggiRegistro<T>(risorsa:string, parametri:URLSearchParams) {
 const {url,headers}=connessioneGlsDb();
 return fetchTutteLePagine<T>(url+'/rest/v1/'+risorsa+'?'+parametri.toString(),{headers});
}
export function resi(filtri:Record<string,string>={}) {
 return leggiRegistro<Reso>('v_resi_scambio',new URLSearchParams({order:'riesame.desc.nullslast,data_fattura.asc,id.asc',...filtri}));
}
export const stati:Record<string,string>={
 attesa:'In attesa del cliente',montaggio:'Montaggio previsto',accordo:'Accordo con il cliente',
 verifica:'Da verificare',assistenza:'Assistenza aperta',presa:'Presa prenotata',reso:'Rientrato',
 escluso:'Escluso',decaduta:'Garanzia commerciale decaduta per mancato reso'
};
export function dataIT(data:string|null) {
 return data ? data.slice(0,10).split('-').reverse().join('/') : '—';
}

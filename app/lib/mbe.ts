import { randomUUID } from 'node:crypto';
import { XMLParser, XMLValidator } from 'fast-xml-parser';

// Only these two read operations are exposed. No arbitrary SOAP operation/URL.
const ENDPOINT = 'https://api.mbeonline.it/ws';
const STATI = ['DELIVERED', 'PARTIALLY_DELIVERED', 'WAITING_DELIVERY', 'NOT_AVAILABLE', 'EXCEPTION'] as const;
export type StatoMbe = typeof STATI[number];
export type SpedizioneMbe = {
 tracking_mbe:string; riferimento:string; data_spedizione:string; corriere:string;
 tracking_corriere:string; colli_mbe:string[]; colli_corriere:string[]; bozza:boolean|null;
 mittente:{nome:string;citta:string;paese:string}; destinatario:{nome:string;citta:string;paese:string};
};
export type EsitoTrackingMbe = { tracking_mbe:string; stato:StatoMbe; data_consegna:string|null; descrizione:string; tracking_corriere:string };
type Nodo = Record<string, unknown>;
export class ErroreMbe extends Error {}
function invalido():never { throw new ErroreMbe('Risposta MBE incompleta o non riconosciuta. Nessun dato importato.'); }
function nodo(x:unknown):Nodo { if(!x || typeof x!=='object' || Array.isArray(x))return invalido(); return x as Nodo; }
function lista(x:unknown):unknown[] { return x===undefined?[]:Array.isArray(x)?x:[x]; }
function testo(x:unknown,max=500):string { if(x===undefined || x==='')return ''; if(typeof x!=='string'||x.length>max)return invalido();return x.trim(); }
function codice(x:unknown):string { const s=testo(x,20); if(!/^[A-Za-z0-9-]{1,20}$/.test(s))return invalido(); return s; }
function data(x:unknown):string { const s=testo(x,10); if(!/^\d{4}-\d{2}-\d{2}$/.test(s)||!Number.isFinite(Date.parse(s))||new Date(s).toISOString().slice(0,10)!==s)return invalido();return s; }
function indirizzo(x:unknown) { const n=nodo(x);return {nome:testo(n.CompanyName)||testo(n.Name),citta:testo(n.City),paese:testo(n.Country,3)}; }
export function contenitoreMbe(xml:string,operazione:'ShipmentsListV3Request'|'TrackingRequest',id:string):Nodo {
 if(Buffer.byteLength(xml)>4*1024*1024 || /<!DOCTYPE|<!ENTITY/i.test(xml) || XMLValidator.validate(xml)!==true)return invalido();
 // No DTD/entities from remote sources. Only XML predefined/numeric entities.
 const doc=new XMLParser({ignoreAttributes:true,removeNSPrefix:true,parseTagValue:false,parseAttributeValue:false,trimValues:true,processEntities:true}).parse(xml);
 const body=nodo(nodo(nodo(doc).Envelope).Body);
 if(body.Fault)throw new ErroreMbe('Il servizio MBE ha restituito un errore SOAP. Verificare il collegamento.');
 const r=nodo(nodo(body[`${operazione}Response`]).RequestContainer);
 if(testo(r.Status,20)!=='OK')throw new ErroreMbe('MBE non ha confermato la lettura. Verificare le autorizzazioni del centro MBE.');
 if(operazione==='ShipmentsListV3Request' && testo(r.InternalReferenceID,100)!==id)return invalido();
 if(r.InternalReferenceID!==undefined && testo(r.InternalReferenceID,100)!==id)return invalido();
 return r;
}
export function paginaMbe(r:Nodo,pagina:number) {
 const intero=(v:unknown)=>{const s=testo(v,6);if(!/^\d+$/.test(s))return invalido();return Number(s);};
 // Missing pagination must not silently truncate an account to its first page.
 const p=intero(r.Page),totale=intero(r.TotalPages);
 const righe=lista(r.ShipmentsFullInfo===undefined||r.ShipmentsFullInfo===''?undefined:nodo(r.ShipmentsFullInfo).ShipmentFullInfo);
 if(p!==pagina || totale>40 || (totale===0?pagina!==1||righe.length>0:p>totale))return invalido();
 if(righe.length>25)return invalido();
 const spedizioni=righe.map(v=>{
  const s=nodo(v),info=nodo(s.ShipmentInfo),track=nodo(s.TrackingInfo);
  const b=testo(info.ShipmentToBeClosed,5);if(b && !['true','false','1','0'].includes(b))return invalido();
  return {tracking_mbe:codice(track.MasterTrackingMBE),riferimento:testo(info.Referring,500),data_spedizione:data(info.Date),corriere:testo(info.Courier,100),tracking_corriere:testo(track.CourierMasterTrk,100),
   colli_mbe:lista(track.TrackingsMBE===undefined||track.TrackingsMBE===''?undefined:nodo(track.TrackingsMBE).TrackingMBE).map(codice),
   colli_corriere:lista(track.CourierPackageTrackings===undefined||track.CourierPackageTrackings===''?undefined:nodo(track.CourierPackageTrackings).CourierPackageTracking).map(x=>testo(x,100)),
   bozza:b?b==='true'||b==='1':null,mittente:s.SenderInfo===undefined?{nome:'',citta:'',paese:''}:indirizzo(s.SenderInfo),destinatario:indirizzo(s.ReceiverInfo)};
 });
 return {spedizioni,totale:Math.max(1,totale)};
}
export function esitiMbe(r:Nodo,richiesti:string[]):EsitoTrackingMbe[] {
 let risultati=lista(r.TrackingResult);
 if(!risultati.length && richiesti.length===1 && r.TrackingStatus!==undefined)risultati=[{...r,TrackingMBE:richiesti[0]}];
 if(risultati.length!==richiesti.length)return invalido();
 const visti=new Set<string>();
 return risultati.map(v=>{const n=nodo(v),id=codice(n.TrackingMBE),stato=testo(n.TrackingStatus,30) as StatoMbe;
  if(!richiesti.includes(id)||visti.has(id)||!STATI.includes(stato))return invalido();visti.add(id);
  return {tracking_mbe:id,stato,data_consegna:n.DeliveryDate?data(n.DeliveryDate):null,descrizione:testo(n.Description,2000),tracking_corriere:testo(n.CourierTracking,100)};
 });
}
function escapeXml(s:string) {return s.replace(/[<>&"']/g,c=>({'<':'&lt;','>':'&gt;','&':'&amp;','"':'&quot;',"'":'&apos;'}[c]!));}
async function corpoLimitato(r:Response):Promise<string> {
 if(!r.body)return invalido();const reader=r.body.getReader();const chunks:Uint8Array[]=[];let size=0;
 try{while(true){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>4*1024*1024)return invalido();chunks.push(value);}}
 finally{await reader.cancel().catch(()=>{});}
 return Buffer.concat(chunks).toString('utf8');
}
export function creaClientMbe(username:string,password:string,trasporto:typeof fetch=fetch) {
 if(!username || !password || username.includes(':') || /[\r\n]/.test(username+password) || username.length>500 || password.length>1000)throw new ErroreMbe('Credenziali MBE non configurate correttamente sul server.');
 const scadenza=Date.now()+45000;let bytes=0;
 async function leggi(operazione:'ShipmentsListV3Request'|'TrackingRequest',campi:string) {
  const id=randomUUID(),rimasto=scadenza-Date.now();if(rimasto<500)throw new ErroreMbe('Tempo di lettura MBE esaurito. Riprovare.');
  const body=`<?xml version="1.0" encoding="UTF-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ws="http://www.onlinembe.eu/ws/"><soap:Body><ws:${operazione}><RequestContainer><System>IT</System><Credentials><Username></Username><Passphrase></Passphrase></Credentials><InternalReferenceID>${id}</InternalReferenceID>${campi}</RequestContainer></ws:${operazione}></soap:Body></soap:Envelope>`;
  let r:Response;try{r=await trasporto(ENDPOINT,{method:'POST',headers:{Authorization:`Basic ${Buffer.from(`${username}:${password}`).toString('base64')}`,'Content-Type':'text/xml; charset=utf-8',SOAPAction:'""'},body,redirect:'error',cache:'no-store',signal:AbortSignal.timeout(Math.min(15000,rimasto))});}
  catch{throw new ErroreMbe('Servizio MBE non raggiungibile o tempo scaduto. Riprovare.');}
  if(r.status===401||r.status===403)throw new ErroreMbe('Accesso MBE rifiutato. Verificare credenziali MBE Online e abilitazione API con il centro.');
  if(r.status===429)throw new ErroreMbe('Limite temporaneo MBE raggiunto. Riprovare più tardi.');
  if(!r.ok)throw new ErroreMbe('Servizio MBE temporaneamente non disponibile. Riprovare.');
  let xml:string;try{xml=await corpoLimitato(r);}catch(e){if(e instanceof ErroreMbe)throw e;throw new ErroreMbe('Lettura MBE interrotta. Nessun dato importato.');}
  bytes+=Buffer.byteLength(xml);if(bytes>16*1024*1024)return invalido();
  return contenitoreMbe(xml,operazione,id);
 }
 return {
  async spedizioni(da:string,a:string):Promise<SpedizioneMbe[]> {
   data(da);data(a);let totale=1;const tutte:SpedizioneMbe[]=[];const viste=new Set<string>();
   for(let page=1;page<=totale;page++){
    const r=paginaMbe(await leggi('ShipmentsListV3Request',`<DateFrom>${da}</DateFrom><DateTo>${a}</DateTo><WithCourierWaybill>false</WithCourierWaybill><Page>${page}</Page>`),page);
    if(page>1&&totale!==r.totale)return invalido();totale=r.totale;
    for(const s of r.spedizioni){if(viste.has(s.tracking_mbe))return invalido();viste.add(s.tracking_mbe);tutte.push(s);}
   }return tutte;
  },
  async tracking(ids:string[]):Promise<EsitoTrackingMbe[]> {
   if(ids.length>1000||new Set(ids).size!==ids.length)return invalido();const esiti:EsitoTrackingMbe[]=[];
   for(let i=0;i<ids.length;i+=100){const gruppo=ids.slice(i,i+100).map(codice);esiti.push(...esitiMbe(await leggi('TrackingRequest',gruppo.map(id=>`<TrackingMBE>${escapeXml(id)}</TrackingMBE>`).join('')),gruppo));}
   return esiti;
  }
 };
}
export const NOMI_STATI_MBE:Record<StatoMbe,string> = {DELIVERED:'Consegnata (MBE)',PARTIALLY_DELIVERED:'Consegnata parzialmente',WAITING_DELIVERY:'Consegna in attesa (MBE)',NOT_AVAILABLE:'Stato non disponibile',EXCEPTION:'Anomalia segnalata da MBE'};

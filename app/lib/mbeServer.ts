import 'server-only';
import { connessioneGlsDb } from './glsServer';
import { creaClientMbe, ErroreMbe, type SpedizioneMbe, type StatoMbe } from './mbe';
export type RigaMbe = SpedizioneMbe & {tracking_corriere_stato:string;pratica_id:string|null;abbinamento:string;motivo:string;tipo_destinazione:string;stato:StatoMbe|null;data_consegna:string|null;descrizione:string;ultima_lettura_at:string};
export type CollegamentoMbe = {automatico:boolean;ultimo_tentativo_at:string|null;ultimo_successo_at:string|null;ultimo_errore:string|null;importate:number;controllate:number;lease_scade_at:string|null};
export function credenzialiMbePresenti() {return Boolean(process.env.MBE_API_USERNAME && process.env.MBE_API_PASSWORD);}
export function collaudoMbeRecente(stato:CollegamentoMbe) {return Boolean(credenzialiMbePresenti()&&stato.ultimo_successo_at&&!stato.ultimo_errore&&Date.now()-Date.parse(stato.ultimo_successo_at)<86400000);}
export async function rpcMbe<T>(nome:string,args:Record<string,unknown>={}):Promise<T> {
 const {url,headers}=connessioneGlsDb();
 const r=await fetch(`${url}/rest/v1/rpc/${nome}`,{method:'POST',headers,body:JSON.stringify(args),cache:'no-store',signal:AbortSignal.timeout(10000)});
 if(!r.ok)throw new Error('Operazione MBE non registrata nel database. Riprovare.');return r.json() as Promise<T>;
}
async function righeDb<T>(percorso:string):Promise<T> {
 const {url,headers}=connessioneGlsDb();
 const r=await fetch(`${url}/rest/v1/${percorso}`,{headers,cache:'no-store',signal:AbortSignal.timeout(10000)});
 if(!r.ok)throw new Error('Registro MBE non disponibile.');return r.json() as Promise<T>;
}
export async function leggiMbe(praticaId?:string) {
 if(praticaId&&!/^[0-9a-f-]{36}$/i.test(praticaId))throw new Error('Pratica non valida');
 return righeDb<RigaMbe[]>(`mbe_spedizioni?select=*&order=data_spedizione.desc,tracking_mbe.asc&limit=200${praticaId?`&pratica_id=eq.${encodeURIComponent(praticaId)}`:''}`);
}
export async function leggiCollegamentoMbe() {
 const r=await righeDb<CollegamentoMbe[]>('mbe_collegamento?select=*&limit=1');if(!r[0])throw new Error('Collegamento non disponibile');return r[0];
}
export async function sincronizzaMbe() {
 if(!credenzialiMbePresenti())throw new ErroreMbe('Collegamento da configurare: inserire MBE_API_USERNAME e MBE_API_PASSWORD nelle variabili server di Vercel, quindi eseguire una nuova distribuzione.');
 const lease=await rpcMbe<string|null>('inizia_sincronizzazione_mbe');
 if(!lease)throw new ErroreMbe('Una sincronizzazione MBE è già in corso. Riprovare tra pochi minuti.');
 try {
  const client=creaClientMbe(process.env.MBE_API_USERNAME!,process.env.MBE_API_PASSWORD!);
  const parti=new Intl.DateTimeFormat('en-CA',{timeZone:'Europe/Rome',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(new Date());
  const parte=(tipo:string)=>parti.find(p=>p.type===tipo)!.value;
  const oggi=`${parte('year')}-${parte('month')}-${parte('day')}`,da=new Date(`${oggi}T00:00:00Z`);da.setUTCDate(da.getUTCDate()-30);
  const recenti=await client.spedizioni(da.toISOString().slice(0,10),oggi);
  // Retry older pending references when a practice was registered after import.
  const pendenti=await righeDb<SpedizioneMbe[]>('mbe_spedizioni?select=tracking_mbe,riferimento,data_spedizione,corriere,tracking_corriere,colli_mbe,colli_corriere,mittente,destinatario,bozza&abbinamento=neq.abbinata&order=tracking_mbe.asc&limit=1001');
  const nuove=new Set(recenti.map(s=>s.tracking_mbe));
  const spedizioni=[...recenti,...pendenti.filter(s=>!nuove.has(s.tracking_mbe))];
  // Continue monitoring older undelivered shipments, without assuming creation = pickup.
  const precedenti=await righeDb<{tracking_mbe:string}[]>('mbe_spedizioni?select=tracking_mbe&or=(stato.is.null,stato.neq.DELIVERED)&order=tracking_mbe.asc&limit=1001');
  const ids=[...new Set([...spedizioni.map(s=>s.tracking_mbe),...precedenti.map(s=>s.tracking_mbe)])];
  if(ids.length>1000)throw new ErroreMbe('Oltre 1000 spedizioni da controllare: verificare il registro prima di ampliare il periodo.');
  const tracking=await client.tracking(ids);
  return await rpcMbe<{esito:string;importate:number;controllate:number}>('termina_sincronizzazione_mbe',{p_lease:lease,p_spedizioni:spedizioni,p_tracking:tracking});
 }catch(e){
  const messaggio=e instanceof ErroreMbe?e.message:'Sincronizzazione MBE non completata. Nessuna importazione parziale; verificare il collegamento e riprovare.';
  await rpcMbe('termina_sincronizzazione_mbe',{p_lease:lease,p_spedizioni:[],p_tracking:[],p_errore:messaggio}).catch(()=>{});
  throw new ErroreMbe(messaggio);
 }
}

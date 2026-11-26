import Link from 'next/link';
import {redirect} from 'next/navigation';
import {BarraOperatore} from '../components/IdentitaOperatore';
import {getOperatoreAttivo} from '../operatore';
import {dataIT,leggiRegistro,resi,stati,type Evento,type Reso} from './registro';
import {registraEsito} from './actions';
export const dynamic='force-dynamic';
type Ricerca={id?:string;q?:string;filtro?:string;errore?:string};
const campo='block w-full rounded border border-slate-400 p-2';
function FormEsito({r}:{r:Reso}) {
 const chiuso=['escluso','reso','decaduta'].includes(r.stato);
 const azioni=chiuso ? ['rettifica',...(r.stato==='decaduta'&&!r.comunicazione?['comunicata']:[])] :
 ['verifica','presa','reso','assistenza','accordo','montaggio','spedizione','attiva',...(r.riesame?['decaduta']:[])];
 const nomi:Record<string,string>={...stati,accordo:'Rinvia verifica alla data concordata',spedizione:'Registra data di spedizione',attiva:'Riprendi solleciti ordinari',comunicata:'Registra la comunicazione effettuata',rettifica:'Riapri per rettifica'};
 return <details className="mt-4"><summary className="cursor-pointer font-bold">Registra esito</summary>
 <form action={registraEsito} className="mt-3 grid max-w-2xl gap-3">
 <input type="hidden" name="id" value={r.id}/><input type="hidden" name="revisione" value={r.revisione}/>
 <label>Esito<select className={campo} name="tipo" required defaultValue=""><option value="" disabled>Seleziona esito</option>{azioni.map(a=><option value={a} key={a}>{nomi[a]}</option>)}</select></label>
 <label>Motivazione o riscontro<textarea className={campo} required name="nota"/></label>
 <label>Data del montaggio, spedizione, comunicazione o prossima verifica<input className={campo} type="date" name="data"/></label>
 <label>Riferimento presa GLS<input className={campo} name="presa"/></label>
 {r.riesame && <label>Clausola applicata alla fornitura, per la decisione sulla garanzia<input className={campo} name="clausola"/></label>}
 {r.decisione && !r.comunicazione && <><label>Canale usato<select className={campo} name="canale">{['WhatsApp','Email','PEC','Raccomandata'].map(c=><option key={c}>{c}</option>)}</select></label>
 <label>Copia del messaggio inviato<textarea className={campo} name="testo"/></label><label>Riferimento messaggio o ricevuta<input className={campo} name="prova"/></label></>}
 <button className="rounded bg-blue-900 p-2 font-semibold text-white">Registra nello storico</button></form></details>;
}
export default async function Registro({searchParams}:{searchParams:Promise<Ricerca>}) {
 const op=await getOperatoreAttivo(); if(!op) redirect('/');
 const p=await searchParams, singolo=p.id && /^[0-9a-f-]{36}$/i.test(p.id)?p.id:null;
 let righe:Reso[]=[], eventi:Evento[]=[], errore=false;
 try {
  righe=await resi(singolo?{id:'eq.'+singolo}:p.filtro==='riesame'?{riesame:'eq.true'}:{});
  if(singolo) eventi=await leggiRegistro<Evento>('resi_scambio_eventi',new URLSearchParams({reso_id:'eq.'+singolo,order:'data_evento.desc,id.desc'}));
 } catch {errore=true;}
 const q=(p.q||'').trim().toLocaleLowerCase('it');
 return <main className="min-h-screen bg-slate-50"><BarraOperatore operatore={op}/><div className="mx-auto max-w-5xl space-y-4 p-6">
 <Link href="/" className="underline">Dashboard</Link><h1 className="text-3xl font-bold">Resi Programma Scambio</h1>
 <form className="flex gap-3"><input aria-label="Cerca per fattura, cliente, targa o componente" className={campo} name="q" defaultValue={q} placeholder="Fattura, cliente, targa o componente"/><button>Cerca</button></form>
 <nav className="flex gap-4 underline"><Link href="/resi">Tutti</Link><Link href="/resi?filtro=riesame">Verifica a sei mesi</Link></nav>
 {errore && <p role="alert">Registro non disponibile.</p>}{p.errore && <p role="alert">Modifica non registrata. Verificare lo stato aggiornato e i campi richiesti per questo esito.</p>}
 {righe.filter(r=>[r.fattura,r.cliente,r.veicolo,r.componente].join(' ').toLowerCase().includes(q)).map(r=><article key={r.id} className="space-y-2 rounded-xl border bg-white p-5">
 <h2 className="text-lg font-bold"><Link className="underline" href={'/resi?id='+r.id}>{r.cliente} · {r.fattura} · {r.veicolo}</Link></h2>
 <p>{r.componente} · {stati[r.stato]}{r.riesame && <strong> · Verifica a sei mesi</strong>}</p>
 <p>Spedizione {dataIT(r.spedizione)} · Ultimo invio {dataIT(r.ultimo_invio)} · Prossima scadenza {dataIT(r.prossima)} · Sei mesi {dataIT(r.sei_mesi)}</p>
 <p>{r.nota}</p>{r.presa && <p>Presa GLS {r.presa}</p>}
 {r.unico_tentativo && <p className="font-bold">Invio in verifica · controllare la ricevuta prima di riprovare</p>}
 {r.decisione && <p className="rounded bg-amber-100 p-3"><strong>{stati.decaduta}</strong> · {r.decisione.nota} · {r.decisione.clausola} · {r.decisione.operatore} · {dataIT(r.decisione.registrata_at)}<br/>{r.comunicazione?'Cliente informato il '+dataIT(r.comunicazione.data)+' via '+r.comunicazione.canale:'Comunicazione da registrare'}</p>}
 {singolo && <><p>Fonte spedizione o verifica: {r.fonte}</p>{r.pratica_id&&<Link className="underline" href={'/pratica/'+r.pratica_id}>Apri pratica</Link>}
 <FormEsito r={r}/><h3 className="font-bold">Storico della fornitura</h3>{eventi.map(e=><details key={e.id}><summary>{dataIT(e.data_evento)} · {e.autore} · {e.tipo}</summary><dl>{Object.entries(e.dettagli).map(([k,v])=><div key={k}><dt className="inline font-semibold">{k} </dt><dd className="inline whitespace-pre-wrap">{String(v)}</dd></div>)}</dl></details>)}</>}
 </article>)}</div></main>;
}

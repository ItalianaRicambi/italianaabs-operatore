import Link from 'next/link';
import {resi,stati} from './registro';
export async function AvvisoResi({pratica,veicolo}:{pratica?:string;veicolo?:string|null}) {
 let filtri:Record<string,string>={select:'id',riesame:'eq.true'};
 if(pratica) {
   const targa=(veicolo||'').toUpperCase().replace(/[^A-Z0-9]/g,'');
   filtri=targa ? {or:`(pratica_id.eq.${pratica},veicolo.eq.${targa})`} : {pratica_id:'eq.'+pratica};
 }
 const righe=await resi(filtri).catch(()=>null);
 if(!righe) return <p role="alert" className="p-3">Registro resi temporaneamente non disponibile. <Link href="/resi" className="underline">Apri registro</Link></p>;
 if(pratica) {
   if(!righe.length) return null;
   return <aside className="rounded-lg border border-amber-400 bg-amber-50 p-3">
    {righe.map(r=><p key={r.id}><Link className="font-semibold underline" href={'/resi?id='+r.id}>
     Programma Scambio · {r.fattura} · {r.veicolo} · {r.componente}</Link> — {stati[r.stato]}
     {r.riesame && ' · Verifica a sei mesi'}{r.decisione && <> · {r.decisione.nota} · {r.comunicazione?'Cliente informato':'Comunicazione da registrare'}</>}
     {r.pratica_id!==pratica && ' · Verificare che la richiesta riguardi questa fornitura'}</p>)}
   </aside>;
  }
  return <aside className={'border-b px-6 py-3 '+(righe.length?'bg-amber-100 text-amber-950':'bg-white text-blue-900')}>
   <Link className="font-semibold underline" href={righe.length?'/resi?filtro=riesame':'/resi'}>Resi Programma Scambio{righe.length?' · '+righe.length+' da verificare a sei mesi':''}</Link>
  </aside>;
}

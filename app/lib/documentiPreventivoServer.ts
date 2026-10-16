import 'server-only';
import { connessioneGlsDb } from './glsServer';
import type { OpzioneOfferta } from './offerte';
export type DocumentoPreventivoAuto = {
 id:string; nome_file:string; targa:string; file_url:string|null; data_offerta:string; ricevuto_at:string;
 pratica_id:string|null; stato:'da_abbinare'|'pronto'|'da_verificare'|'inviato'; motivo:string|null;
 opzioni:OpzioneOfferta[];
};
export async function leggiDocumentiPreventivo(praticaId?:string) {
 if(praticaId && !/^[0-9a-f-]{36}$/i.test(praticaId)) throw new Error('Pratica non valida');
 const {url,headers}=connessioneGlsDb();
 const filtro=praticaId?`&pratica_id=eq.${encodeURIComponent(praticaId)}`:'';
 const r=await fetch(`${url}/rest/v1/documenti_preventivo_auto?select=id,nome_file,targa,file_url,data_offerta,ricevuto_at,pratica_id,stato,motivo,opzioni:contenuto->opzioni&stato=neq.inviato${filtro}&order=data_offerta.desc&limit=200`,{headers,cache:'no-store'});
 if(!r.ok) throw new Error('Registro preventivi non disponibile');
 return r.json() as Promise<DocumentoPreventivoAuto[]>;
}

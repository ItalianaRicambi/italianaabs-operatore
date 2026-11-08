import test from 'node:test';
import assert from 'node:assert/strict';
import { abbinaFic, type PraticaFic } from './abbinamentiFic.ts';
import type {DocumentoFic} from './fattureInCloud.ts';
const d:DocumentoFic={id:1,tipo:'proforma',data:'2026-11-01',numero:'1',cliente:'Officina',partitaIva:'IT12345678901',codiceFiscale:'',oggetto:'Targa AB123CD',note:'',importo:100,valuta:'EUR',righe:[],pagamenti:[]};
const p:PraticaFic={id:'test',numero_pratica:42,targa:'AB 123 CD',nome_cliente:'Officina',created_at:'2026-10-01',tipo_flusso:'commerciale',clienti:{partita_iva:'12345678901',codice_fiscale:''}};
test('targa e identità fiscale concordanti producono solo una proposta',()=>{
  const a=abbinaFic(d,[p]); assert.equal(a.stato,'univoco'); assert.equal(d.tipo,'proforma');
});
test('nome/codice soli, anagrafica mancante e conflitti non bastano',()=>{
  assert.equal(abbinaFic({...d,oggetto:'Officina codice 123'},[p]).stato,'assente');
  assert.equal(abbinaFic(d,[{...p,clienti:null}]).stato,'assente');
  assert.equal(abbinaFic({...d,codiceFiscale:'AAAA'},[{...p,clienti:{...p.clienti!,codice_fiscale:'BBBB'}}]).stato,'assente');
});
test('ricorrenze e documenti con più targhe sono ambigui',()=>{
  assert.equal(abbinaFic(d,[p,{...p,id:'two',numero_pratica:43}]).stato,'ambiguo');
  assert.equal(abbinaFic({...d,oggetto:'AB123CD XY456ZW'},[p]).stato,'ambiguo');
});
test('riferimento pratica esplicito risolve le ricorrenze senza confondere numeri parziali',()=>{
  assert.equal(abbinaFic({...d,note:'Pratica n. 42'},[p,{...p,id:'two',numero_pratica:43}]).stato,'univoco');
  assert.equal(abbinaFic({...d,note:'Pratica 420'},[p]).stato,'assente');
});
test('assistenza e pratiche posteriori al documento non sono associate',()=>{
  assert.equal(abbinaFic(d,[{...p,tipo_flusso:'assistenza'}]).stato,'assente');
  assert.equal(abbinaFic(d,[{...p,created_at:'2026-11-02'}]).stato,'assente');
});
test('pratiche test e duplicati archiviati non sono proposti',()=>{
  assert.equal(abbinaFic(d,[{...p,archiviata_test:'true'}]).stato,'assente');
  assert.equal(abbinaFic(d,[{...p,archiviata_duplicato:'true'}]).stato,'assente');
});

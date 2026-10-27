import test from 'node:test';
import assert from 'node:assert/strict';
import {normalizzaEventoPreventivo} from './normalizzaPreventivo.ts';
const base={external_id:'drive-file',nome_file:'FV444PR.pdf',data_offerta:'2026-10-16T10:00:00Z'};
test('il suffisso copia Drive non modifica la targa',()=>{
 for(const nome_file of ['FV444PR.pdf','FV444PR (1).pdf','FV444PR (23).PDF']) assert.equal(normalizzaEventoPreventivo({...base,nome_file,targa:'FV444PR'}).targa,'FV444PR');
});
test('nome e targa discordanti restano errore',()=>{
 assert.throws(()=>normalizzaEventoPreventivo({...base,targa:'FV555PR'}));
});
test('sigla Paese delimitata separata dalla targa, anche nelle copie Drive',()=>{
 for(const [targa,paese] of [['LU71264','CH'],['CRQ5022','US'],['20NJ05','P'],['7741DNV','E'],['199TU6674','TN']]) {
  for(const nome_file of [`${targa} (${paese}).pdf`,`${targa} (${paese}) (2).pdf`,`${targa} _${paese}_.pdf`]) {
   assert.equal(normalizzaEventoPreventivo({...base,nome_file,targa}).targa,targa);
  }
 }
 assert.equal(normalizzaEventoPreventivo({...base,nome_file:'AB123CH.pdf',targa:'AB123CH'}).targa,'AB123CH');
 assert.throws(()=>normalizzaEventoPreventivo({...base,nome_file:'LU71264 (CH).pdf',targa:'LU71265'}));
});

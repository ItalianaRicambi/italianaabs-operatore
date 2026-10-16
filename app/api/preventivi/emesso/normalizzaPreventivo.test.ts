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

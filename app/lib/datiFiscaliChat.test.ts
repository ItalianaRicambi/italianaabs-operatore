import test from 'node:test';
import assert from 'node:assert/strict';
import { datiFiscaliDaChat } from './datiFiscaliChat.ts';
test('i dati fiscali su più righe non vengono confusi con il luogo di ritiro', () => {
  const r = datiFiscaliDaChat([{id:1,testo:'- cognome; Cliente Prova\\n- codice fiscale:TSTFSC80A01F952A\\n- indirizzo di fatturazione: via Esempio n.16 Pisticci (Mt) 75015\\n- email:cliente@example.invalid\\n- indirizzo di ritiro: AUTOFFICINA STRADA STATALE 407 - 75012 BERNALDA'}]);
  assert.equal(r.dati.indirizzo_fatturazione, 'via Esempio n.16');
  assert.equal(r.dati.cap, '75015'); assert.equal(r.dati.comune, 'Pisticci'); assert.equal(r.dati.provincia, 'MT');
});
test('codice fiscale seguito da nome e indirizzo in una riga può essere precompilato', () => {
  const r = datiFiscaliDaChat([{id:1,testo:'TSTFSC80A01F952A Cliente Prova Lgo Esempio 15 Roma 00123'}]);
  assert.equal(r.dati.denominazione, 'Cliente Prova'); assert.equal(r.dati.comune, 'Roma'); assert.equal(r.dati.cap, '00123');
});
test('località prima del CAP e comune dopo il CAP restano distinti', () => {
  const r = datiFiscaliDaChat([{id:1,testo:'Immagine anagrafica: OFFICINA TEST, P.IVA 12345678901, CF TSTFSC80A01F952A, Via Esempio 6, Località Prova, 09074 Ghilarza (OR), email test@example.invalid.'}]);
  // Una riga mista con dati dopo il comune resta da verificare; non si inventa un indirizzo.
  assert.equal(r.dati.comune, undefined); assert.equal(r.dati.denominazione, 'OFFICINA TEST');
});
test('messaggi successivi non cancellano i dati e valori discordanti non vengono scelti arbitrariamente', () => {
  const r = datiFiscaliDaChat([{id:1,testo:'codice fiscale: TSTFSC80A01F952A\nemail:uno@example.invalid'},
    {id:2,testo:'Grazie'}, {id:3,testo:'Email:due@example.invalid'}]);
  assert.equal(r.dati.codice_fiscale, 'TSTFSC80A01F952A'); assert.equal(r.dati.email, undefined);
  assert.ok(r.conflitti.includes('email'));
});

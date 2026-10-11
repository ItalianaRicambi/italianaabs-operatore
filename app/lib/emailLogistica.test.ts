import test from 'node:test';
import assert from 'node:assert/strict';
import { messaggioPresa, emailSingola, esitoErroreSmtp } from './emailLogistica.ts';

const base = { riferimento: 'P3 9260993058', data_ritiro: '2026-10-12', revisione: 1 };
test('oggi e domani seguono Roma, anche al cambio di giorno e all’ora legale', () => {
  const sera = new Date('2026-10-11T22:30:00Z');
  assert.match(messaggioPresa(base, sera).text, /oggi, 12\/10\/2026/);
  assert.match(messaggioPresa(base, new Date('2026-10-11T10:00:00Z')).text, /domani, 12\/10\/2026/);
  assert.match(messaggioPresa({ ...base, data_ritiro: '2026-10-25' }, new Date('2026-10-24T22:30:00Z')).text, /oggi, 25\/10\/2026/);
});
test('data futura esplicita, istruzioni in grassetto e firma logistica', () => {
  const m = messaggioPresa({ ...base, data_ritiro: '2026-10-15' }, new Date('2026-10-11T10:00:00Z'));
  assert.match(m.text, /giornata di 15\/10\/2026/);
  assert.match(m.html, /<strong>un bigliettino con la targa del veicolo<\/strong>/);
  assert.match(m.html, /<strong>imballare bene<\/strong>/);
  assert.match(m.html, /<strong>il pezzo deve arrivare in officina nudo<\/strong>/);
  assert.match(m.text, /Ufficio logistico/); assert.doesNotMatch(m.text, /Scotti Norberto/);
});
test('correzione esplicita senza inventare una seconda presa', () => {
  const m = messaggioPresa({ ...base, revisione: 2 }, new Date('2026-10-11T10:00:00Z'));
  assert.match(m.subject, /^Aggiornamento presa/); assert.match(m.text, /sostituisce le precedenti/);
});
test('dati scaduti, date inesistenti e HTML nel codice non generano avvisi', () => {
  for (const variazione of [{ data_ritiro: '2026-10-10' }, { data_ritiro: '2026-02-30' }, { riferimento: 'P3 <img src=x>' }])
    assert.throws(() => messaggioPresa({ ...base, ...variazione }, new Date('2026-10-11T10:00:00Z')));
});
test('un solo indirizzo, senza destinatari multipli o injection degli header', () => {
  assert.equal(emailSingola('cliente@example.org'), true);
  for (const e of ['a@example.org,b@example.org', 'Mario <a@example.org>', 'a@example.org\r\nBcc: b@example.org', 'a@example.org; b@example.org']) assert.equal(emailSingola(e), false);
});
test('timeout dopo DATA e disconnessione senza fase nota non si riprovano automaticamente', () => {
  assert.equal(esitoErroreSmtp({ code: 'ETIMEDOUT', command: 'DATA' }), 'esito_incerto');
  assert.equal(esitoErroreSmtp({ code: 'ECONNECTION' }), 'esito_incerto');
  assert.equal(esitoErroreSmtp({ code: 'EAUTH' }), 'errore');
  assert.equal(esitoErroreSmtp({ code: 'ETIMEDOUT', command: 'CONN' }), 'errore');
  assert.equal(esitoErroreSmtp({ responseCode: 550, command: 'DATA' }), 'errore');
});

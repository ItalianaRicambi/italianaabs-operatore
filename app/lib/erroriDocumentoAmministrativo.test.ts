import test from 'node:test';
import assert from 'node:assert/strict';
import { messaggioErroreDocumento } from './erroriDocumentoAmministrativo.ts';
const rpc = (message: string, code = 'P0001') => new Error(`Operazione non riuscita (400): ${JSON.stringify({ code, message, details: 'DATI PRIVATI', hint: 'SEGRETO' })}`);

test('il rifiuto fiscale indica il problema senza esporre dettagli SQL', () => {
  const m = messaggioErroreDocumento(rpc('Il destinatario fiscale non coincide con il cliente già collegato'));
  assert.match(m, /diverso dal cliente fiscale collegato/);
  assert.match(m, /nessun dato salvato/);
  assert.doesNotMatch(m, /DATI PRIVATI|SEGRETO/);
});
test('lo stato incoerente è distinto da un anagrafica incompleta', () => {
  assert.match(messaggioErroreDocumento(rpc('La nuova anagrafica può essere creata solo per un ordine da fatturare')), /fatturazione non allineata/);
  assert.match(messaggioErroreDocumento(rpc('Anagrafica fiscale incompleta o da verificare')), /anagrafica fiscale esistente/);
});
test('timeout, risposte malformate e messaggi non noti non affermano rollback né espongono dati', () => {
  for (const e of [new Error('timeout SEGRETO'), rpc('DATI PRIVATI'), rpc('Targa documento diversa dalla pratica', 'XX000'), new Error('Operazione non riuscita (400): {SEGRETO}'), null]) {
    const m = messaggioErroreDocumento(e);
    assert.match(m, /Salvataggio non confermato/);
    assert.doesNotMatch(m, /nessun dato salvato|SEGRETO|DATI PRIVATI/);
  }
});

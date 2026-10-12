import test from 'node:test';
import assert from 'node:assert/strict';
import { salvaCorrezioneScelta } from './correzioneScelta.ts';

const pratica = '11111111-1111-4111-8111-111111111111';
const opzione = '22222222-2222-4222-8222-222222222222';
function form(id = '') {
  const dati = new FormData();
  for (const [k, v] of Object.entries({ pratica_id: pratica, opzione_id: id, stato: 'confermata', nota: 'Confermiamo l’offerta numero 2' })) dati.set(k, v);
  return dati;
}

test('conferma senza alternativa: risposta leggibile, nessuna scrittura e nota conservata', async () => {
  const dati = form();
  const esito = await salvaCorrezioneScelta(dati, 'Operatore 1', async () => { assert.fail('Non deve scrivere'); });
  assert.equal(esito.ok, false);
  assert.match(esito.messaggio, /seleziona un’alternativa verificata/);
  assert.equal(dati.get('nota'), 'Confermiamo l’offerta numero 2');
});

test('la scelta valida salva alternativa, evidenza e identità operatore', async () => {
  const esito = await salvaCorrezioneScelta(form(opzione), 'Operatore 2', async dati => {
    assert.deepEqual(dati, { p_pratica_id: pratica, p_opzione_id: opzione, p_stato: 'confermata',
      p_nota: 'Confermiamo l’offerta numero 2', p_operatore: 'Operatore 2' });
    return { ok: true };
  });
  assert.equal(esito.ok, true);
});

test('il rifiuto del database e risposte inattese non diventano successi né errori di pagina', async () => {
  const rifiutata = await salvaCorrezioneScelta(form(opzione), 'Operatore 1', async () => {
    throw new Error('Operazione non riuscita (400): Selezionare una alternativa verificata');
  });
  assert.equal(rifiutata.ok, false);
  assert.match(rifiutata.messaggio, /seleziona un’alternativa verificata/);
  for (const risposta of [null, { ok: false }, {}]) {
    assert.equal((await salvaCorrezioneScelta(form(opzione), 'Operatore 1', async () => risposta)).ok, false);
  }
  const errore = await salvaCorrezioneScelta(form(opzione), 'Operatore 1', async () => { throw new Error('dettaglio riservato'); });
  assert.equal(errore.ok, false);
  assert.doesNotMatch(errore.messaggio, /riservato/);
});

test('una soluzione ancora da chiarire può essere annotata senza confermarla', async () => {
  const dati = form(); dati.set('stato', 'da_chiarire');
  assert.equal((await salvaCorrezioneScelta(dati, 'Operatore 1', async parametri => {
    assert.equal(parametri.p_opzione_id, null);
    assert.equal(parametri.p_stato, 'da_chiarire'); return { ok: true };
  })).ok, true);
});

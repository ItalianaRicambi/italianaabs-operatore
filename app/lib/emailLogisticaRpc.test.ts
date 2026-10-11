import test from 'node:test';
import assert from 'node:assert/strict';
import { leggiRispostaEmailRpc } from './emailLogisticaRpc.ts';

test('il salvataggio void accettato da PostgREST non diventa un errore', async () => {
  assert.equal(await leggiRispostaEmailRpc(new Response(null, { status: 204 })), undefined);
});

test('le RPC con dati conservano oggetti, booleani e null', async () => {
  for (const valore of [{ configurata: true }, true, false, null]) {
    assert.deepEqual(await leggiRispostaEmailRpc(Response.json(valore)), valore);
  }
});

test('un rifiuto DB non espone il corpo della risposta', async () => {
  await assert.rejects(leggiRispostaEmailRpc(new Response('argomento sensibile', { status: 400 })),
    { message: 'Operazione email logistica non riuscita.' });
});

test('una risposta inattesa resta un errore e non espone il contenuto', async () => {
  await assert.rejects(leggiRispostaEmailRpc(new Response('argomento sensibile')),
    { message: 'Risposta email logistica non valida.' });
});

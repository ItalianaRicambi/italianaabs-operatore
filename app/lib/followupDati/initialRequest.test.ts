import { strict as assert } from 'node:assert';
import { test } from 'node:test';
import { prepareFiscalRequest, prepareTechnicalRequest, technicalRequestFromNote } from './initialRequest.ts';

test('uses the same exact technical request at preparation and discovery', () => {
  const reasons = ['targa', 'codice_o_immagine_componente', 'stato_spie'];
  const initial = prepareTechnicalRequest(reasons);
  assert.deepEqual(initial?.fields, ['targa','foto']);
  assert.deepEqual(technicalRequestFromNote(`Dati mancanti: ${reasons.join(', ')}.`), initial);
  assert.equal(prepareTechnicalRequest(['stato_spie']), null);
  assert.equal(prepareTechnicalRequest(['targa','diagnosi_discordante_da_verificare_operatore']), null);
  assert.equal(technicalRequestFromNote('Dati non verificati'), null);
});

test('only the exact administrative request and recognized missing fields are eligible', () => {
  const exact = "Grazie, abbiamo registrato l'accettazione del preventivo. Per preparare la fattura ci servono ancora: CAP, PEC. Può inviarceli qui?";
  assert.deepEqual(prepareFiscalRequest(exact,['cap','pec']), {phase:'fatturazione',exactText:exact,fields:['cap','sdi_o_pec']});
  assert.equal(prepareFiscalRequest('Può inviare i dati?', ['cap']), null);
  assert.equal(prepareFiscalRequest(exact,['verifica_anagrafica']), null);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { leggiDocumentoAmministrativo } from './documentiAmministrativi.ts';

const documento = (tipo = 'Fattura') => `${tipo} nr. 10/2026\nData: 09/10/2026\nSpettabile\nCLIENTE DI PROVA\nCF: TSTFSC80A01F952A\nVia Cliente 10\n00123 Roma (RM)\nITALIA\nItaliana Ricambi di Scotti Norberto\nP.IVA: 02439670031\nVia Romana 63\n28047 Oleggio (NO)\nTarga: AB123CD\nTotale dovuto € 402,30`;
test('la fattura usa i dati del destinatario e la data del documento, non quelli del fornitore', () => {
  const d = leggiDocumentoAmministrativo(documento(), 'AB123CD');
  assert.equal(d.tipo, 'fattura'); assert.equal(d.data, '2026-10-09'); assert.equal(d.importo, 402.3);
  assert.equal(d.cliente.denominazione, 'CLIENTE DI PROVA');
  assert.equal(d.cliente.codice_fiscale, 'TSTFSC80A01F952A'); assert.equal(d.cliente.partita_iva, null);
  assert.equal(d.cliente.indirizzo_fatturazione, 'Via Cliente 10'); assert.equal(d.cliente.cap, '00123');
});
test('la pro-forma rimane un documento distinto da una fattura', () => {
  assert.equal(leggiDocumentoAmministrativo(documento('Pro Forma'), 'AB123CD').tipo, 'proforma');
});
test('i dati svizzeri conservano il prefisso fiscale e il CAP di quattro cifre', () => {
  const testo = documento().replace('CF: TSTFSC80A01F952A', 'P.IVA: CHE-123.456.789').replace('00123 Roma (RM)\nITALIA', '6048 Horw (LUCERNA)\nSVIZZERA');
  const c = leggiDocumentoAmministrativo(testo, 'AB123CD').cliente;
  assert.equal(c.partita_iva, 'CHE-123.456.789'); assert.equal(c.cap, '6048'); assert.equal(c.paese, 'CH');
});
test('le intestazioni ripetute sono accettate solo quando coincidono', () => {
  assert.equal(leggiDocumentoAmministrativo(documento() + '\n' + documento(), 'AB123CD').numero, '10/2026');
  assert.throws(() => leggiDocumentoAmministrativo(documento() + '\n' + documento().replace('10/2026', '11/2026'), 'AB123CD'));
});
test('targa diversa, più targhe, data impossibile e intestatario incompleto non sono importati', () => {
  for (const t of [documento().replace('AB123CD', 'XY999ZZ'), documento() + '\nTarga: XY999ZZ',
    documento().replace('09/10/2026', '31/02/2026'), documento().replace('Via Cliente 10\n', ''),
    documento().replace('CF: TSTFSC80A01F952A\n', '')]) assert.throws(() => leggiDocumentoAmministrativo(t, 'AB123CD'));
});

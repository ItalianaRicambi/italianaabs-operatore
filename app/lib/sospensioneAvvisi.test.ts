import assert from 'node:assert/strict';
import test from 'node:test';
import { avvisoOrdine } from './avvisiOrdini.ts';
import { ordineConfermatoAperto, prontaPerFatturazione } from './fatturazione.ts';
import { correggiCodaOperativa } from './codeOperative.ts';
import { filtraOggi, prossimaAzione } from './oggi.ts';

const sospesa = {
  id: 'regressione-sospensione', tipo_flusso: 'commerciale',
  stato_commerciale: 'ordine_acquisito', stato_fatturazione: 'da_fatturare',
  stato_completezza: 'completa_da_preventivare', stato_amministrativo: 'dati_mancanti',
  stato_richiesta_amministrativa: 'inviata', cliente_id: null,
  blocco_classificazione_operatore: true,
  coda: 'ORDINE ACQUISITO - DA FATTURARE', priorita: 3,
  dati_raw: { sospensione_fatturazione_operatore: { attiva: true },
    fic_anagrafica: { stato: 'identita_mancante' } },
};
const giorno = '2026-11-10';

test('EM81240 / EG891YE: sospensione e dati richiesti escludono avviso, lavoro e fatturazione', () => {
  for (const targa of ['EM81240', 'EG891YE']) {
    const p = { ...sospesa, targa };
    const prima = structuredClone(p);
    assert.equal(avvisoOrdine(p), null);
    assert.equal(prontaPerFatturazione(p), false);
    assert.equal(ordineConfermatoAperto(p), true);
    assert.equal(correggiCodaOperativa(p).coda, 'ORDINE ACQUISITO - IN ATTESA DATI CLIENTE');
    assert.equal(prossimaAzione(p, giorno).titolo, 'Attendere i dati fiscali');
    assert.deepEqual(filtraOggi([p], 'oggi', giorno), []);
    assert.deepEqual(filtraOggi([p], 'oggi_urgenti', giorno), []);
    assert.deepEqual(filtraOggi([p], 'oggi_attesa', giorno), [p]);
    assert.deepEqual(p, prima);
  }
});

test('dati completi o nuovo controllo FIC non scavalcano la sospensione; lo sblocco ripristina avviso', () => {
  const p = { ...sospesa, stato_amministrativo: 'pronto_fatturazione', cliente_id: 'cliente-test',
    dati_raw: { ...sospesa.dati_raw, fic_anagrafica: { stato: 'riconosciuto' } } };
  assert.equal(avvisoOrdine(p), null);
  assert.equal(prontaPerFatturazione(p), false);
  assert.equal(prossimaAzione(p, giorno).stato, 'in_attesa');
  const riabilitata = { ...p, dati_raw: { ...p.dati_raw, sospensione_fatturazione_operatore: { attiva: false } } };
  assert.equal(avvisoOrdine(riabilitata)?.pronto, true);
  assert.equal(prontaPerFatturazione(riabilitata), true);
  assert.equal(prossimaAzione(riabilitata, giorno).titolo, 'Preparare la fatturazione');
});

test('la sospensione fiscale non nasconde attività logistiche o assistenze indipendenti', () => {
  const p = { ...sospesa, attivita_operative: [{ tipo: 'ritiro_lavorazione', stato: 'da_gestire', priorita: 'urgente' }] };
  assert.equal(avvisoOrdine(p), null);
  assert.equal(prossimaAzione(p, giorno).titolo, 'Organizzare il ritiro');
  assert.equal(prossimaAzione(p, giorno).urgente, true);
  const assistenza = { ...sospesa, assistenze_rientro: [{ stato: 'verifica_tecnica', priorita: 'urgente' }] };
  assert.equal(prossimaAzione(assistenza, giorno).area, 'assistenza');
  assert.equal(prossimaAzione(assistenza, giorno).urgente, true);
});

test('ordini incompleti non sospesi e altri blocchi mantengono gli avvisi', () => {
  const p = { ...sospesa, dati_raw: {} };
  assert.ok(avvisoOrdine(p));
  assert.ok(avvisoOrdine({ ...p, blocco_operatore: true }));
  assert.ok(avvisoOrdine({ ...p, offerta_da_verificare: true }));
});

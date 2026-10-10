import assert from 'node:assert/strict';
import test from 'node:test';
import { codiceGls, leggiDettaglioGls, statoGlsAttuale, presaPrenotata } from './esitiGls.ts';

const testo = `DETTAGLIO RITIRO
Contratto:\t6178 Italiana Ricambi Di Scotti
N. Ritiro:\tP3 9260993058\tData Ritiro:\t12/10/2026\tDDT:
Sede Richiedente:\tP3 – Novara\tMittente:\tDebdoubi Abdellatif – Capannori – Lu
Sede Effettuante:\tLU – Lucca\tDestinatario:\tMonika Bednarska – Lobau – De
ESITO RITIRO
Data e Ora\tLuogo\tStato\tNote
09/10/2026 15:10\tNovara\tRitiro Inserito\t
Torna a elenco spedizioni`;
test('importa dettaglio verificato: codice completo, cliente e orario italiano', () => {
 const r = leggiDettaglioGls(testo, 'P39260993058', '2026-10-12');
 assert.equal(r.mittente, 'Debdoubi Abdellatif – Capannori – Lu');
 assert.equal(r.destinatario, 'Monika Bednarska – Lobau – De');
 assert.deepEqual(r.eventi, [{ at: '2026-10-09T13:10:00.000Z', luogo: 'Novara', stato: 'Ritiro Inserito', note: '' }]);
 assert.equal(codiceGls('P3 9260993058'), r.riferimento);
});
test('codice e data incoerenti, date impossibili e liste senza storico sono rifiutati', () => {
 assert.throws(() => leggiDettaglioGls(testo, 'P3 9660043007', '2026-10-12'));
 assert.throws(() => leggiDettaglioGls(testo, 'P3 9260993058', '2026-10-13'));
 assert.throws(() => leggiDettaglioGls(testo.replaceAll('12/10/2026', '31/02/2026'), 'P3 9260993058', '2026-02-31'));
 assert.throws(() => leggiDettaglioGls('P39260993058 12/10/2026 Debdoubi Non effettuato', 'P3 9260993058', '2026-10-12'));
});
test('tracking della spedizione conserva il riferimento della presa originaria', () => {
 const r = leggiDettaglioGls(testo.replace('N. Ritiro:\tP3 9260993058\tData Ritiro:', 'N. Spedizione:\tMT 260054680\tData Partenza:').replaceAll('ESITO RITIRO','ESITO SPEDIZIONE').replace('Ritiro Inserito','Ritiro Effettuato'), 'P3 9660043007', '2026-10-09');
 assert.equal(r.riferimento, 'P3 9660043007'); assert.equal(r.numero_spedizione, 'MT 260054680');
 assert.equal(r.eventi[0].stato, 'Ritiro Effettuato');
});
test('prenotazione scaduta senza esito resta da verificare e non diventa mancato ritiro', () => {
 assert.equal(statoGlsAttuale({stato:'prenotata',data_ritiro:'2026-10-12'}, new Date('2026-10-10T10:00:00Z')), 'prenotata');
 assert.equal(statoGlsAttuale({stato:'prenotata',data_ritiro:'2026-10-12'}, new Date('2026-10-12T23:00:00Z')), 'da_verificare');
 assert.equal(statoGlsAttuale({stato:'effettuata',data_ritiro:'2026-10-12'}, new Date('2026-10-13T10:00:00Z')), 'effettuata');
 assert.equal(presaPrenotata({tipo:'ritiro_lavorazione',stato:'programmata',data_ritiro_prevista:'2026-10-12',metadati:{gls:{stato:'non_effettuata'}}}), false);
});

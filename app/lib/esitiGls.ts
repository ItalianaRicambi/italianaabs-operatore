export type StatoPresaGls = 'prenotata' | 'effettuata' | 'non_effettuata' | 'annullata' | 'da_verificare';
export type EventoGls = { at: string; luogo: string; stato: string; note: string };
export type EsitoGls = {
 id: string; fonte: string; fonte_id: string; contratto: string; riferimento: string; data_ritiro: string;
 mittente: string; destinatario: string; destinazione: string; numero_spedizione: string | null;
 eventi: EventoGls[]; testo: string; stato: StatoPresaGls; motivo: string | null; evento_at: string | null;
 ritirato_at: string | null; verificata_at: string; esito_abbinamento: string;
 pratica_id: string | null; attivita_id: string | null; numero_pratica?: number | null; targa?: string | null; tipo_ritiro?: string | null;
};
export const NOMI_ESITO_GLS: Record<StatoPresaGls, string> = {
 prenotata: 'Presa prenotata', effettuata: 'Presa effettuata', non_effettuata: 'Presa non effettuata',
 annullata: 'Presa annullata', da_verificare: 'Esito da verificare',
};
export const NOMI_ABBINAMENTO_GLS: Record<string, string> = {
 abbinata: 'Abbinata alla pratica', da_abbinare: 'Pratica da abbinare', abbinamento_ambiguo: 'Più pratiche: verifica operatore',
 mittente_da_verificare: 'Mittente da verificare', destinazione_da_verificare: 'Destinazione da verificare',
 episodio_precedente: 'Ritiro di un episodio precedente', ritiro_da_classificare: 'Motivo del ritiro da classificare',
 ritiro_chiuso_operatore: 'Ritiro già chiuso dall’operatore', data_da_verificare: 'Data diversa dalla prenotazione',
 controllo_precedente: 'Controllo precedente: dati attuali conservati', prenotazione_da_verificare: 'Prenotazione da verificare',
};
export function giornoRoma(at = new Date()) {
 return new Intl.DateTimeFormat('sv-SE', { timeZone: 'Europe/Rome' }).format(at);
}
export function statoGlsAttuale(esito: Pick<EsitoGls, 'stato' | 'data_ritiro'>, at = new Date()): StatoPresaGls {
 return esito.stato === 'prenotata' && esito.data_ritiro < giornoRoma(at) ? 'da_verificare' : esito.stato;
}
export type MetadatiGls = { gls?: { stato: StatoPresaGls; motivo?: string | null; verificata_at?: string } };
export function etichettaPresa(a: { stato: string; data_ritiro_prevista?: string | null; metadati?: MetadatiGls }) {
 if (a.metadati?.gls) return NOMI_ESITO_GLS[statoGlsAttuale({ stato: a.metadati.gls.stato, data_ritiro: a.data_ritiro_prevista || '' })];
 return a.stato === 'programmata' ? 'Presa prenotata' : 'Da prenotare / verificare';
}
export function presaPrenotata(a: { tipo: string; stato: string; data_ritiro_prevista?: string | null; metadati?: MetadatiGls }) {
 return a.tipo.startsWith('ritiro_') && a.stato === 'programmata' && (!a.metadati?.gls || etichettaPresa(a) === NOMI_ESITO_GLS.prenotata);
}
export function codiceGls(value: string) {
 const c = value.toUpperCase().replace(/[^A-Z0-9]/g, '');
 if (!/^[A-Z][A-Z0-9]\d{6,15}$/.test(c)) throw new Error('Codice di presa GLS non valido.');
 return `${c.slice(0, 2)} ${c.slice(2)}`;
}
function dataIt(value: string) {
 const match = /^(\d{2})\/(\d{2})\/(\d{4})$/.exec(value);
 if (!match) throw new Error('Data GLS non leggibile.');
 const [, g, m, a] = match, date = new Date(Date.UTC(+a, +m - 1, +g));
 if (date.getUTCFullYear() !== +a || date.getUTCMonth() !== +m - 1 || date.getUTCDate() !== +g || +a < 2020 || +a > 2100) throw new Error('Data GLS non valida.');
 return `${a}-${m}-${g}`;
}
function oraRoma(date: string, time: string) {
 const iso = dataIt(date), [h, m] = time.split(':').map(Number);
 if (h > 23 || m > 59) throw new Error('Ora GLS non valida.');
 const d = new Date(`${iso}T${time}:00Z`);
 const offset = new Intl.DateTimeFormat('en', { timeZone: 'Europe/Rome', timeZoneName: 'shortOffset' }).formatToParts(d).find(p => p.type === 'timeZoneName')?.value;
 const ore = Number(offset?.match(/GMT\+(\d+)/)?.[1]);
 if (!ore) throw new Error('Fuso orario GLS non leggibile.');
 return new Date(d.getTime() - ore * 3600000).toISOString();
}

/** Importazione verificata dell'operatore: mai dedurre una presa dalla sola lista. */
export function leggiDettaglioGls(testo: string, riferimento: string, dataRitiro: string) {
 if (testo.length > 100000 || !/ESITO\s+(RITIRO|SPEDIZIONE)/i.test(testo)) throw new Error('Incolla il dettaglio GLS con lo storico degli eventi.');
 const contratto = testo.match(/Contratto\s*:\s*(\d+)/i)?.[1];
 const codiceLetto = testo.match(/N\.\s*Ritiro\s*:\s*([A-Z][A-Z0-9]\s*\d{6,15})/i)?.[1];
 if (codiceLetto && codiceGls(codiceLetto) !== codiceGls(riferimento)) throw new Error('Il dettaglio GLS indica un altro codice di presa.');
 const dataLetta = testo.match(/Data\s+Ritiro\s*:\s*(\d{2}\/\d{2}\/\d{4})/i)?.[1];
 if (dataLetta && dataIt(dataLetta) !== dataRitiro) throw new Error('La data inserita è diversa dal dettaglio GLS.');
 if (!/^\d{4}-\d{2}-\d{2}$/.test(dataRitiro)) throw new Error('Inserisci la data della presa.');
 const [anno, mese, giorno] = dataRitiro.split('-'); dataIt(`${giorno}/${mese}/${anno}`);
 const mittente = testo.split(/\bMittente\s*:/i).at(-1)?.split(/Sede\s+(?:Effettuante|Destinatario)\s*:/i)[0]?.trim();
 const destinatario = testo.split(/\bDestinatario\s*:/i).at(-1)?.split(/ESITO\s+(?:RITIRO|SPEDIZIONE)/i)[0]?.trim();
 if (!contratto || !/\bMittente\s*:/i.test(testo) || !/\bDestinatario\s*:/i.test(testo) || !mittente || !destinatario) throw new Error('Mancano contratto, mittente o destinatario nel dettaglio GLS.');
 const storico = testo.split(/ESITO\s+(?:RITIRO|SPEDIZIONE)/i)[1].split(/Torna a elenco spedizioni|Cerca il tuo ritiro/i)[0];
 const eventi: EventoGls[] = [];
 for (const line of storico.split(/\r?\n/)) {
  const match = /^\s*(\d{2}\/\d{2}\/\d{4})\s+(\d{2}:\d{2})\s+(.+)$/.exec(line);
  if (!match) continue;
  const [, date, time, rest] = match;
  let cells = rest.split(/\t+/).map(c => c.trim());
  if (cells.length < 2) {
   const boundary = rest.search(/\b(Ritiro|Merce non presente|Cliente assente|Spedizione|Partita|Arrivata|Consegnata)\b/i);
   if (boundary < 1) throw new Error('Separazione delle colonne GLS non leggibile: copia la tabella completa.');
   cells = [rest.slice(0, boundary).trim(), rest.slice(boundary).trim()];
  }
  eventi.push({ at: oraRoma(date, time), luogo: cells[0], stato: cells[1], note: cells.slice(2).join(' ') });
 }
 if (!eventi.length) throw new Error('Lo storico GLS non contiene eventi leggibili con data e ora.');
 return { contratto, riferimento: codiceGls(riferimento), data_ritiro: dataRitiro, mittente, destinatario, eventi,
  numero_spedizione: testo.match(/N\.\s*Spedizione\s*:\s*([A-Z][A-Z0-9]\s*\d{6,15})/i)?.[1] || null, testo };
}

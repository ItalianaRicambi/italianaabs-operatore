export const MITTENTE_LOGISTICA = 'spedizioni@italianaabs.com';
export const MAIL_COLLAUDO_LOGISTICA = 'paolo.ardizzoia78@gmail.com';

export type AvvisoPresa = { id: string; token: string; destinatario: string; riferimento: string; data_ritiro: string; revisione: number };

export function emailSingola(valore: string): boolean {
  return valore.length <= 254 && /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$/.test(valore);
}

export function messaggioPresa(presa: Pick<AvvisoPresa, 'riferimento' | 'data_ritiro' | 'revisione'>, adesso = new Date()) {
  const data = presa.data_ritiro;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(data) || new Date(`${data}T12:00:00Z`).toISOString().slice(0, 10) !== data) throw new Error('Data ritiro non valida');
  if (!/^P3[ -]?\d{6,15}$/.test(presa.riferimento)) throw new Error('Codice presa GLS non valido');
  const oggi = new Intl.DateTimeFormat('sv-SE', { timeZone: 'Europe/Rome', year: 'numeric', month: '2-digit', day: '2-digit' }).format(adesso);
  if (data < oggi) throw new Error('Data ritiro trascorsa');
  const domani = new Date(`${oggi}T12:00:00Z`); domani.setUTCDate(domani.getUTCDate() + 1);
  const giorno = data === oggi ? 'oggi, ' : data === domani.toISOString().slice(0, 10) ? 'domani, ' : '';
  const dataIt = data.split('-').reverse().join('/');
  const aggiornamento = presa.revisione > 1;
  const apertura = aggiornamento ? 'abbiamo aggiornato la prenotazione della presa con GLS' : 'abbiamo prenotato la presa con GLS';
  const paragrafi = [
    'Buongiorno,',
    `${apertura} per la giornata di ${giorno}${dataIt}, cod. ${presa.riferimento} (da riportare all’esterno della scatola).`,
    ...(aggiornamento ? ['Questa comunicazione sostituisce le precedenti informazioni sulla prenotazione della stessa presa.'] : []),
    'Vi ricordiamo di voler mettere, all’interno della scatola, un bigliettino con la targa del veicolo.',
    'Ci raccomandiamo di voler imballare bene il prodotto onde evitare rotture accidentali durante il trasporto.',
    'Ci raccomandiamo inoltre di voler smontare eventuali staffe, supporti o simili: il pezzo deve arrivare in officina nudo.',
    'Vi ricordiamo che non ci assumiamo alcuna responsabilità per danni al prodotto causati da imballi inadeguati e/o per eventuali perdite di supporti, staffe ed affini.',
    `Ufficio logistico\nItaliana Ricambi - ItalianaABS\nRitiri e spedizioni\n${MITTENTE_LOGISTICA}\nhttps://www.italianaabs.com`,
  ];
  const escape = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  const html = paragrafi.map(p => `<p>${escape(p).replace(/\n/g, '<br>')}</p>`).join('')
    .replace('un bigliettino con la targa del veicolo', '<strong>un bigliettino con la targa del veicolo</strong>')
    .replace('imballare bene', '<strong>imballare bene</strong>')
    .replace('il pezzo deve arrivare in officina nudo', '<strong>il pezzo deve arrivare in officina nudo</strong>');
  return { subject: `${aggiornamento ? 'Aggiornamento presa' : 'Presa prenotata'} GLS — ${dataIt} — ${presa.riferimento}`, text: paragrafi.join('\n\n'), html };
}

// Solo un rifiuto SMTP esplicito, o un errore sicuramente precedente a DATA,
// consente di riprovare. Un timeout dopo DATA può aver consegnato il messaggio.
export function esitoErroreSmtp(errore: unknown): 'errore' | 'esito_incerto' {
  const e = errore as { responseCode?: number; code?: string; command?: string };
  if (e.responseCode && e.responseCode >= 400 && e.responseCode <= 599) return 'errore';
  if (['EAUTH', 'EDNS', 'ETLS'].includes(e.code || '') || /^(CONN|EHLO|HELO|STARTTLS|AUTH|MAIL FROM|RCPT TO)/.test(e.command || '')) return 'errore';
  return 'esito_incerto';
}

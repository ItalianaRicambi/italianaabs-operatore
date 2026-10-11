import 'server-only';
import nodemailer from 'nodemailer';
import { connessioneGlsDb } from './glsServer';
import { MITTENTE_LOGISTICA, MAIL_COLLAUDO_LOGISTICA, messaggioPresa, esitoErroreSmtp, type AvvisoPresa } from './emailLogistica';

export type ConfigLogistica = { abilitata: boolean; configurata: boolean; test_at: string | null; test_message_id: string | null; password?: string | null };
export type NotificaLogistica = { id: string; pratica_id: string; attivita_id: string; revisione: number; riferimento: string; data_ritiro: string; destinatario: string | null; stato: string; motivo: string | null; tentativi: number; inviata_at: string | null; message_id: string | null; created_at: string };

export async function rpcEmail<T>(nome: string, dati: Record<string, unknown> = {}): Promise<T> {
  const { url, headers } = connessioneGlsDb();
  const response = await fetch(`${url}/rest/v1/rpc/${nome}`, { method: 'POST', headers, body: JSON.stringify(dati), cache: 'no-store', signal: AbortSignal.timeout(10000) });
  // Non propagare risposte DB che potrebbero contenere argomenti sensibili.
  if (!response.ok) throw new Error('Operazione email logistica non riuscita.');
  return response.json() as Promise<T>;
}

export function leggiConfigEmail(segreti = false) { return rpcEmail<ConfigLogistica>('configurazione_email_logistica', { p_segreti: segreti }); }

export async function leggiNotificheEmail(): Promise<NotificaLogistica[]> {
  const { url, headers } = connessioneGlsDb();
  const response = await fetch(`${url}/rest/v1/notifiche_email_logistica?select=id,pratica_id,attivita_id,revisione,riferimento,data_ritiro,destinatario,stato,motivo,tentativi,inviata_at,message_id,created_at&order=created_at.desc,id.asc&limit=200`, { headers, cache: 'no-store' });
  if (!response.ok) throw new Error('Registro email non disponibile.');
  return response.json();
}

function trasporto(password: string) {
  return nodemailer.createTransport({ host: 'mail.italianaabs.com', port: 587, secure: false, requireTLS: true,
    auth: { user: MITTENTE_LOGISTICA, pass: password },
    tls: { rejectUnauthorized: true, minVersion: 'TLSv1.2' },
    connectionTimeout: 8000, greetingTimeout: 8000, socketTimeout: 12000, dnsTimeout: 8000,
    logger: false, debug: false, disableFileAccess: true, disableUrlAccess: true,
  });
}

const from = { name: 'ItalianaABS - Italiana Ricambi', address: MITTENTE_LOGISTICA };

export async function collaudaSmtpLogistica(password: string) {
  const smtp = trasporto(password);
  try {
    await smtp.verify();
    const esito = await smtp.sendMail({ from, replyTo: MITTENTE_LOGISTICA, to: MAIL_COLLAUDO_LOGISTICA,
      subject: 'TEST SPEDIZIONI — collaudo automatismi logistici',
      text: `Buongiorno,\n\nquesta è una prova interna dell’invio dalla dashboard. Non avvia pratiche, ordini o ritiri.\n\nUfficio logistico\nItaliana Ricambi - ItalianaABS\nRitiri e spedizioni\n${MITTENTE_LOGISTICA}\nhttps://www.italianaabs.com`,
    });
    if (!esito.accepted.length || esito.rejected.length) throw new Error('Messaggio non accettato.');
    return esito.messageId;
  } finally { smtp.close(); }
}

export async function processaEmailLogistica() {
  const config = await leggiConfigEmail(true);
  if (!config.abilitata || !config.password) return { abilitata: false, elaborate: 0 };
  const smtp = trasporto(config.password);
  let elaborate = 0;
  try {
    for (let i = 0; i < 2; i++) {
      const avviso = await rpcEmail<AvvisoPresa | null>('prendi_email_logistica');
      if (!avviso) break;
      let stato: 'inviata' | 'errore' | 'esito_incerto' = 'inviata';
      let motivo = 'Messaggio accettato dal server SMTP; consegna al destinatario non verificata.';
      let messaggio;
      try { messaggio = messaggioPresa(avviso); }
      catch { stato = 'errore'; motivo = 'Data o codice non validi al momento dell’invio.'; }
      if (messaggio) {
        try {
          const risultato = await smtp.sendMail({ from, replyTo: MITTENTE_LOGISTICA, to: { address: avviso.destinatario, name: '' },
            envelope: { from: MITTENTE_LOGISTICA, to: [avviso.destinatario] },
            messageId: `<${avviso.id}@italianaabs.com>`, ...messaggio });
          if (!risultato.accepted.length || risultato.rejected.length) { stato = 'errore'; motivo = 'Destinatario rifiutato dal server SMTP.'; }
        } catch (e) {
          stato = esitoErroreSmtp(e);
          motivo = stato === 'errore' ? 'Invio rifiutato o connessione SMTP non riuscita. Verificare e riprovare.' : 'Conferma SMTP mancante. Verificare il Message-ID prima di qualsiasi nuovo invio.';
        }
      }
      // Fuori dal catch SMTP: un errore DB dopo l’accettazione non deve
      // trasformarsi in un retry. Il lease scaduto diventa esito_incerto.
      const salvato = await rpcEmail<boolean>('esito_email_logistica', { p_id: avviso.id, p_token: avviso.token, p_stato: stato, p_motivo: motivo });
      if (!salvato) throw new Error('Esito invio non registrato.');
      elaborate++;
    }
    return { abilitata: true, elaborate };
  } finally { smtp.close(); }
}

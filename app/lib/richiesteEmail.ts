import { createHash, timingSafeEqual } from 'node:crypto';

export const CASELLA_INFO = 'info@italianaabs.com';
export const CASELLA_ORDINI = 'ordini@italianaabs.com';
export type EmailOriginale = { mailbox: string; sender: string; subject: string; content: string; conversation_id: string; fingerprint: string };
export function autorizzazioneEmail(ricevuto: string | null, segreto: string | undefined) {
  if (!ricevuto || !segreto) return false;
  const a = Buffer.from(ricevuto), b = Buffer.from(segreto);
  return a.length === b.length && timingSafeEqual(a, b);
}
export function normalizzaEmail(value: unknown): EmailOriginale {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Email non valida');
  const v = value as Record<string, unknown>;
  for (const k of ['mailbox','sender','subject','content','conversation_id']) if (typeof v[k] !== 'string' || (v[k] as string).includes('{{trigger.')) throw new Error('Dati originali email mancanti');
  const mailbox = (v.mailbox as string).trim().toLowerCase(), sender = (v.sender as string).trim().toLowerCase();
  const subject = (v.subject as string).trim(), content = v.content as string, conversation_id = (v.conversation_id as string).trim();
  if (![CASELLA_INFO, CASELLA_ORDINI].includes(mailbox) || !/^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/.test(sender) || sender.length > 254) throw new Error('Casella o mittente non valido');
  if (!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(conversation_id)) throw new Error('Conversazione non valida');
  if (subject.length > 2000 || content.length > 250000) throw new Error('Email troppo grande');
  const fingerprint = createHash('sha256').update(JSON.stringify([mailbox,sender,conversation_id,subject,content])).digest('hex');
  return { mailbox,sender,subject,content,conversation_id,fingerprint };
}
export function testoEmail(e: EmailOriginale) {
  // Conserviamo l'originale nel registro. L'estrazione lavora su testo leggibile,
  // senza eseguire HTML e senza scaricare URL dichiarati dal mittente.
  const corrente = e.content.split(/<blockquote\b|<div\b[^>]*class=["'][^"']*gmail_quote/i)[0];
  const testo = corrente.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi,'').replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi,'').replace(/<(?:br|\/p|\/div)\b[^>]*>/gi,'\n').replace(/<[^>]*>/g,' ').replace(/&nbsp;/gi,' ').replace(/&amp;/gi,'&').replace(/&lt;/gi,'<').replace(/&gt;/gi,'>');
  return testo.split(/\n\s*(?:(?:Il|On) .{0,180}(?:ha scritto|wrote):|(?:Da|From):|[-_]{3,}\s*(?:Messaggio originale|Original Message|Forwarded message))/i)[0].split('\n').filter(l=>!/^\s*>/.test(l)).join('\n');
}
export function esclusioneEmail(e: EmailOriginale) {
  if (/^(?:re:\s*)?test(?:\s|[-—:])/i.test(e.subject) && /collaudo|prova interna|caso simulato/i.test(e.content)) return 'Collaudo interno: nessuna pratica operativa.';
  if (/^(mailer-daemon|postmaster)@/i.test(e.sender)) return 'Notifica tecnica di posta: da consultare nel registro.';
  return null;
}
export function payloadEmail(e: EmailOriginale) {
  const text = testoEmail(e), utile = `${e.subject}\n${text}`;
  // Una risposta con la sola targa integra l'identità della richiesta: non
  // sostituisce il guasto già descritto con l'oggetto e la firma dell'email.
  const righeUtili=text.split('\n').map(r=>r.trim()).filter(r=>r && !/^inviato da (?:iphone|ipad|android)|^sent from my /i.test(r));
  const soloTarga=righeUtili.length===1 && /^(?:targa\s*(?:del veicolo\s*)?[:=\-]?\s*)?[A-Z]{2}[\s-]?\d{3}[\s-]?[A-Z]{2}[.!]?$/i.test(righeUtili[0]);
  const targhe = [
    ...[...utile.matchAll(/\btarga\s*(?:del veicolo\s*)?[:=\-]?\s*([A-Z]{2}[\s-]?\d{3}[\s-]?[A-Z]{2})\b/gi)].map(m=>m[1]),
    ...[...text.matchAll(/^\s*([A-Z]{2}[\s-]?\d{3}[\s-]?[A-Z]{2})[.!]?\s*$/gmi)].map(m=>m[1]),
  ].map(t=>t.replace(/[\s-]/g,'').toUpperCase());
  const targa = new Set(targhe).size === 1 ? targhe[0] : null;
  const dtc = [...new Set([...utile.matchAll(/\b[PCBU]\d{4}(?:[-:]?[A-F0-9]{2})?\b/gi)].map(m=>m[0].toUpperCase()))];
  const testoConLink=testoEmail({...e,content:e.content.replace(/<(?:a|img)\b[^>]*\b(?:href|src)=["'](https:\/\/[^"']+)["'][^>]*>/gi,' $1 ')});
  const urls = [...new Set([...testoConLink.matchAll(/https:\/\/[^\s<>"']+/gi)].map(m=>m[0].replace(/[).,;]+$/,'')))].filter(u=>/\.(?:png|jpe?g|webp|pdf)(?:\?|$)/i.test(u));
  const allegatiIndicati = /\ballegat[oi]\b|\bin allegato\b|\bfoto\b/i.test(utile);
  // La casella ordini contiene anche notifiche automatiche: una email non
  // attesta pagamento né consenso cliente. Shopify alimenta la coda separata.
  const operativo = e.mailbox === CASELLA_INFO && !!text.trim() && /\b(?:abs|esp|ecu|tcu|centralina|preventivo|riparazione|garanzia|rientro|reso|ordine|confermo|confermiamo|accetto|accettiamo|ritiro|fattura|spedizione)\b/i.test(utile);
  const garanzia = /\bgaranzia\b/i.test(utile), assistenza = garanzia || /\b(?:rientro|reso|assistenza|post[- ]?vendita|problema dopo|dopo (?:installazione|riparazione))\b/i.test(utile);
  return { operativo, allegatiIndicati, body: {
    channel:'email', conversation_id:e.conversation_id, email_mittente:e.sender,
    nome_cliente:e.sender, email_cliente:e.sender, email_oggetto:e.subject,
    ultimo_messaggio_cliente:text, descrizione_guasto:soloTarga?null:utile.slice(0,30000),
    targa, dtc, allegati:urls, dati_completi:false,
    tipo_flusso:assistenza?'assistenza':'commerciale', tipo_assistenza:garanzia?'garanzia':assistenza?'altro':null,
    email_allegati_da_verificare:allegatiIndicati && !urls.length,
    email_fonte_originale:true, email_fingerprint:e.fingerprint,
    allegati_descrizioni:allegatiIndicati && !urls.length ? ['Allegati indicati nella email: il trigger non trasmette i file. Verificare la conversazione originale in Keplero.'] : [],
  } };
}
export function linkConversazioneEmail(id: string) {
  return `https://console.keplero.ai/dashboard/027160a9-3c91-490c-92f7-d0236aff8352/conversations?sessionId=${encodeURIComponent(id)}`;
}

/** /live restituisce la pratica dentro result; alcuni esiti sono diretti. */
export function praticaDaEsitoEmail(value: unknown): string | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const r=value as Record<string,unknown>;
  const interno=r.result && typeof r.result==='object' && !Array.isArray(r.result) ? r.result as Record<string,unknown> : {};
  const valori=[r.pratica_id,interno.pratica_id].filter((v):v is string=>typeof v==='string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(v));
  return new Set(valori.map(v=>v.toLowerCase())).size===1 ? valori[0].toLowerCase() : null;
}

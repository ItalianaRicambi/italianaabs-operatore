import type { DocumentoFic } from './fattureInCloud.ts';
import type { DocumentoAmministrativo } from './documentiAmministrativi.ts';
import type { OriginaleK } from './originaliKeplero.ts';

export type IdentitaFic = { partita_iva?: string | null; codice_fiscale?: string | null; email?: string | null; telefono?: string | null };
export const fiscale = (v: unknown) => String(v || '').toUpperCase().replace(/[^A-Z0-9]/g,'').replace(/^IT(?=\d{11}$)/,'');
export const telefono = (v: unknown) => String(v || '').replace(/\D/g,'').replace(/^00/,'').replace(/^39(?=\d{9,11}$)/,'');
const email = (v: unknown) => String(v || '').trim().toLowerCase();
export function identitaFiscaleCompleta(i: IdentitaFic) {
  return /^\d{11}$/.test(fiscale(i.partita_iva)) || /^(?:\d{11}|[A-Z]{6}[0-9LMNPQRSTUV]{2}[ABCDEHLMPRST][0-9LMNPQRSTUV]{2}[A-Z][0-9LMNPQRSTUV]{3}[A-Z])$/.test(fiscale(i.codice_fiscale));
}
export function queryClienteFic(i: IdentitaFic) {
  const parti: string[] = [];
  const iva = fiscale(i.partita_iva), cf = fiscale(i.codice_fiscale), tel = telefono(i.telefono), e = email(i.email);
  if (iva.length >= 5) parti.push(`vat_number = '${iva}'`, `vat_number = 'IT${iva}'`);
  if (cf.length >= 5) parti.push(`tax_code = '${cf}'`);
  if (tel.length >= 8) parti.push(`phone contains '${tel.slice(-6)}'`);
  if (/^[A-Za-z0-9._+@-]{3,254}$/.test(e)) parti.push(`email = '${e}'`);
  return parti.join(' or ');
}
export function clientiCompatibili(i: IdentitaFic, rows: Record<string,unknown>[]) {
  const iva = fiscale(i.partita_iva), cf = fiscale(i.codice_fiscale), tel = telefono(i.telefono), e = email(i.email);
  return rows.filter(c => {
    const cv = fiscale(c.vat_number), cc = fiscale(c.tax_code);
    if ((iva && cv && iva !== cv) || (cf && cc && cf !== cc)) return false;
    return Boolean((iva && iva === cv) || (cf && cf === cc) || (e && e === email(c.email)) ||
      (tel.length >= 8 && String(c.phone || '').split(/[/;,|\n]+/).some(t => telefono(t) === tel)));
  });
}
export function urlPdfChat(m: OriginaleK): string | null {
  const o = m.originale, meta = o.metadata as Record<string,unknown> | undefined, wa = o.whatsapp_message as Record<string,unknown> | undefined;
  if (m.direzione !== 'uscita' || m.tipo !== 'file' || !((o.sender_type === 'user' && meta?.origin === 'whatsapp_coexistence') || ['delivered','read'].includes(String(wa?.status)))) return null;
  if (!m.testo.startsWith('attachment:')) return null;
  try {
    const u = new URL(m.testo.slice(11));
    if (u.protocol !== 'https:' || u.hostname !== 'v2.api.keplero.ai' || u.port || u.username || u.password || u.search || u.hash || !u.pathname.startsWith('/v2/session-attachments/') || !/\.pdf$/i.test(decodeURIComponent(u.pathname))) return null;
    return u.href;
  } catch { return null; }
}
export function fatturaCorrisponde(pdf: DocumentoAmministrativo, fic: DocumentoFic) {
  const iva = fiscale(pdf.cliente.partita_iva), cf = fiscale(pdf.cliente.codice_fiscale);
  const vi = fiscale(fic.partitaIva), ci = fiscale(fic.codiceFiscale);
  const testo = [fic.oggetto,fic.note,...fic.righe.flatMap(r=>[r.nome,r.descrizione])].join('\n');
  const targhe = [...testo.matchAll(/\bTarga\s*:\s*([A-Z0-9]+)/gi)].map(m=>fiscale(m[1]));
  return pdf.tipo === 'fattura' && fic.tipo === 'invoice' && fic.valuta === 'EUR' && pdf.numero.replace(/\s/g,'') === fic.numero.replace(/\s/g,'')
    && pdf.data === fic.data && fic.importo != null && Math.abs(pdf.importo - fic.importo) < 0.005
    && !((iva && vi && iva !== vi) || (cf && ci && cf !== ci)) && Boolean((iva && iva === vi) || (cf && cf === ci))
    && new Set(targhe).size === 1 && targhe[0] === pdf.targa;
}

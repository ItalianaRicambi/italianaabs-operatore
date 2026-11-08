import 'server-only';
import { creaClientFic, ErroreFic, validaConfigFic } from './fattureInCloud';

function configurazione() {
  return validaConfigFic({ token: process.env.FIC_ACCESS_TOKEN || '', companyId: process.env.FIC_COMPANY_ID || '',
    partitaIva: '02439670031' });
}
export function ficConfigurato(): boolean { try { configurazione(); return true; } catch { return false; } }
export function clientFic() { return creaClientFic(configurazione()); }
export function messaggioErroreFic(e: unknown): string {
  return e instanceof ErroreFic ? e.message : 'Consultazione non disponibile. Riprova più tardi.';
}

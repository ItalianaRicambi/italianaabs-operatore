import 'server-only';
import {rpcOriginaliK} from '../originaliKepleroServer';
import type {Calendar} from './policy';

/** Un'unica lettura DB per copertura, chiusure e cutover. La funzione SQL di
 * dispatch verifica di nuovo lo stesso calendario all'acquisizione e all'invio.
 * Nessuna estensione implicita al 2027 o fallback a giorni tutti lavorativi.
 */
export async function readFollowupConfiguration():Promise<{calendar:Calendar;enabledAfter:string|null}>{
 const c=await rpcOriginaliK<{
  enabled:boolean;transportVerified:boolean;acceptRequestsAfter:string|null;
  calendar:Calendar;
 }>('configurazione_followup_dati');
 if(!c||!c.calendar||typeof c.calendar.confirmedThrough!=='string'||!Array.isArray(c.calendar.closures)){
  throw new Error('followup_calendar_unconfirmed');
 }
 return {calendar:c.calendar,enabledAfter:c.enabled===true&&c.transportVerified===true?c.acceptRequestsAfter:null};
}

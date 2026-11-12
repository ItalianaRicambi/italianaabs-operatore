import {midnightInRome, romeDay, validDay} from './policy.ts';

const dayMs = 86_400_000;
const weekdays = ['domenica', 'lunedi', 'martedi', 'mercoledi', 'giovedi', 'venerdi', 'sabato'];
const months = ['gennaio', 'febbraio', 'marzo', 'aprile', 'maggio', 'giugno', 'luglio', 'agosto', 'settembre', 'ottobre', 'novembre', 'dicembre'];
const numbers = ['zero', 'un[ao]?', 'due', 'tre', 'quattro', 'cinque', 'sei', 'sette', 'otto', 'nove', 'dieci'];
const relative = String.raw`(?:fra|tra) (\d{1,2}|${numbers.slice(1).join('|')}) (giorn[oi]|settiman[ae])`;
const weekday = String.raw`(?:entro )?(?:${weekdays.join('|')})(?: prossim[oa])?`;
const date = String.raw`(?:entro (?:il )?|il )?(?:\d{1,2}/\d{1,2}(?:/\d{4})?|\d{1,2} (?:${months.join('|')})(?: \d{4})?)`;
const timing = `(${relative}|(?:entro )?(?:domani|dopodomani)|(?:la )?settimana prossima|la prossima settimana|entro (?:(?:la fine della |la )?prossima settimana|(?:la )?settimana prossima)|${weekday}|${date})`;

const verb = '(?:mando|invio|inoltro|comunico|trasmetto|mandero|inviero|comunichero|trasmettero|faccio avere)';
const item = "(?:tutto|(?:i |le |la |il |l')?(?:codici(?: (?:di )?guasto| dtc| identificativi)?|dtc|diagnosi|esito della diagnosi|dati(?: (?:fiscali|di fatturazione))?|documenti|foto|targa|partita iva|codice fiscale|codice sdi|pec))";
const promise = `(?:(?:vi |le |ti )${verb} ${item}|(?:(?:ve |te )?(?:li|le|lo|la) )${verb}|(?:vi |ti )(?:aggiorno|faccio sapere|faro sapere|faccio sapere qualcosa))`;
const appointment = "(?:(?:vado|passo|andro) (?:dal meccanico|in officina|dal commercialista) (?:e (?:poi )?)?)?";
const trailing = new RegExp(`^(?:${promise}|sentiamoci|ricontattatemi) ${timing}$`, 'u');
const leading = new RegExp(`^${timing}[ ,]+${appointment}(?:${promise}|sentiamoci|ricontattatemi)$`, 'u');
const appointmentThen = new RegExp(`^${appointment}${timing}[ ,]+(?:e (?:poi )?|poi )?${promise}$`, 'u');
const relativeMatch = new RegExp(`^${relative}$`, 'u');
const undatedTime = '(?:(?:non )?appena (?:riesco|posso|possibile|ho novita)|quando (?:riesco|posso|ho novita))';
const undatedPromise = new RegExp(`^(?:${undatedTime}[ ,]+${promise}|${promise} ${undatedTime})$`, 'u');

export type CustomerDeferral = {
  notBefore: string;
  messages: {id: string; fingerprint: string}[];
  conversationFingerprint: string;
};

function addDays(day: string, count: number): string {
  return new Date(Date.parse(day) + count * dayMs).toISOString().slice(0, 10);
}

/** Recognize a commitment only if the whole message is understood. */
export function customerTiming(text: string, sentAt: number): number | 'undated' | null {
  if (!Number.isFinite(sentAt) || text.length > 300) return null;
  const normalized = text.normalize('NFD').replace(/\p{M}/gu, '').toLowerCase()
    .replace(/’/g, "'").trim().replace(/\s+/gu, ' ').replace(/[.!]+$/u, '');
  const phrase = (leading.exec(normalized) ?? trailing.exec(normalized) ?? appointmentThen.exec(normalized))?.[1];
  if (!phrase) return undatedPromise.test(normalized) ? 'undated' : null;

  const sentDay = romeDay(sentAt);
  const duration = relativeMatch.exec(phrase);
  if (duration) {
    const count = /^\d/u.test(duration[1]) ? Number(duration[1])
      : numbers.findIndex(number => new RegExp(`^${number}$`, 'u').test(duration[1]));
    return count > 0 ? sentAt + count * (duration[2].startsWith('settiman') ? 7 : 1) * dayMs : null;
  }

  const sentWeekday = new Date(sentDay).getUTCDay();
  if (phrase.includes('settimana')) {
    // A generic "next week" means one week from the customer's message.
    if (!phrase.startsWith('entro ')) return sentAt + 7 * dayMs;
    return midnightInRome(addDays(sentDay, 14 - (sentWeekday + 6) % 7));
  }

  const target = phrase.replace(/^entro /u, '').replace(/ prossim[oa]$/u, '');
  if (target === 'domani' || target === 'dopodomani') {
    return midnightInRome(addDays(sentDay, target === 'domani' ? 2 : 3));
  }

  const targetWeekday = weekdays.indexOf(target);
  if (targetWeekday >= 0) {
    const distance = (targetWeekday - sentWeekday + 7) % 7;
    return midnightInRome(addDays(sentDay, 1 + (distance || (phrase.includes('prossim') ? 7 : 0))));
  }

  const [dateDay, month, year = sentDay.slice(0, 4)] = target.replace(/^il /u, '').split(/[/ ]/u);
  const monthNumber = /^\d/u.test(month) ? month : String(months.indexOf(month) + 1);
  const targetDay = `${year}-${monthNumber.padStart(2, '0')}-${dateDay.padStart(2, '0')}`;
  return validDay(targetDay) && targetDay >= sentDay ? midnightInRome(addDays(targetDay, 1)) : null;
}

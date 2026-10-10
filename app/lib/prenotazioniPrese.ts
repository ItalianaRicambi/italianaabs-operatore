export type DatiPresa = {
  corriere: string | null;
  riferimento: string | null;
  data_ritiro: string | null;
  errore: string | null;
};

function dataValida(anno: number, mese: number, giorno: number) {
  const data = new Date(Date.UTC(anno, mese - 1, giorno));
  return anno >= 2020 && anno <= 2100 && data.getUTCFullYear() === anno &&
    data.getUTCMonth() === mese - 1 && data.getUTCDate() === giorno;
}

/** Legge solo date esplicite e riferimenti etichettati, senza dedurre la prenotazione. */
export function leggiPrenotazionePresa(testo: string): DatiPresa {
  const t = testo.replace(/\u00a0/g, " ");
  const corriere = /\bGLS\b/i.test(t) ? "GLS" : null;
  const date = new Set<string>();
  let dataNonValida = false;
  for (const match of t.matchAll(/\b(\d{1,2})[/.](\d{1,2})[/.](\d{4})\b|\b(\d{4})-(\d{2})-(\d{2})\b/g)) {
    const [anno, mese, giorno] = match[4]
      ? [Number(match[4]), Number(match[5]), Number(match[6])]
      : [Number(match[3]), Number(match[2]), Number(match[1])];
    if (!dataValida(anno, mese, giorno)) { dataNonValida = true; continue; }
    date.add(`${anno}-${String(mese).padStart(2, "0")}-${String(giorno).padStart(2, "0")}`);
  }
  const codici = new Set<string>();
  const pattern = /\b(?:codice|cod\.?|riferimento|numero\s+(?:(?:di|della)\s+)?(?:presa|ritiro|prenotazione))\s*(?:[:=-]\s*)?(?:\([^)]{0,150}\)\s*)?((?:[A-Z]{1,3}\d?\s*[-/]?\s*)?\d{6,15})\b/gi;
  for (const match of t.matchAll(pattern)) {
    codici.add(match[1].trim().toUpperCase().replace(/\s+/g, " "));
  }
  const data_ritiro = date.size === 1 && !dataNonValida ? [...date][0] : null;
  const riferimento = codici.size === 1 ? [...codici][0] : null;
  const errore = !corriere ? "Corriere GLS non identificato nel testo."
    : !/\b(presa|ritiro|corriere|prenotazione|prenotato|prenotata)\b/i.test(t) ? "Il testo non identifica una presa del corriere."
    : dataNonValida ? "La data indicata non è valida."
    : date.size > 1 ? "Sono presenti più date: verifica quella della presa."
    : !data_ritiro ? "Manca la data completa della presa (giorno/mese/anno)."
    : codici.size > 1 ? "Sono presenti più codici: verifica quello della presa."
    : !riferimento ? "Manca un codice di presa riconoscibile."
    : null;
  return { corriere, riferimento, data_ritiro, errore };
}

export function dataPresaIt(value: string) {
  const [anno, mese, giorno] = value.slice(0, 10).split("-");
  return `${giorno}/${mese}/${anno}`;
}

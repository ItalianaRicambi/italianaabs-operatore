export type PraticaMensile = {
  preventivo_inviato_at: string | null;
  stato_fatturazione: string;
  data_fattura: string | null;
  ordine_acquisito_at: string | null;
};

const FORMATO_MESE = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Europe/Rome",
  year: "numeric",
  month: "2-digit",
});

const FORMATO_ETICHETTA = new Intl.DateTimeFormat("it-IT", {
  timeZone: "Europe/Rome",
  month: "long",
  year: "numeric",
});

export function chiaveMeseRoma(data: string | Date | null) {
  if (!data) return null;

  const istante = data instanceof Date ? data : new Date(data);
  if (Number.isNaN(istante.getTime())) return null;

  const parti = FORMATO_MESE.formatToParts(istante);
  const anno = parti.find((parte) => parte.type === "year")?.value;
  const mese = parti.find((parte) => parte.type === "month")?.value;

  return anno && mese ? `${anno}-${mese}` : null;
}

export function mesiDashboard(ora = new Date()) {
  const corrente = chiaveMeseRoma(ora);
  if (!corrente) {
    throw new Error("Data corrente non valida");
  }

  const [anno, mese] = corrente.split("-").map(Number);
  const precedenteDate = new Date(Date.UTC(anno, mese - 2, 15, 12));
  const precedente = chiaveMeseRoma(precedenteDate);

  if (!precedente) {
    throw new Error("Impossibile calcolare il mese precedente");
  }

  return {
    corrente,
    precedente,
    etichettaCorrente: etichettaMese(corrente),
    etichettaPrecedente: etichettaMese(precedente),
  };
}

function etichettaMese(chiave: string) {
  const [anno, mese] = chiave.split("-").map(Number);
  const data = new Date(Date.UTC(anno, mese - 1, 15, 12));
  const etichetta = FORMATO_ETICHETTA.format(data);
  return etichetta.charAt(0).toUpperCase() + etichetta.slice(1);
}

export function dataFatturaEffettiva(pratica: PraticaMensile) {
  if (pratica.stato_fatturazione !== "fatturato") return null;
  return pratica.data_fattura ?? pratica.ordine_acquisito_at;
}

export function haPreventivoNelMese(
  pratica: PraticaMensile,
  mese: string
) {
  return chiaveMeseRoma(pratica.preventivo_inviato_at) === mese;
}

export function haFatturaNelMese(pratica: PraticaMensile, mese: string) {
  return chiaveMeseRoma(dataFatturaEffettiva(pratica)) === mese;
}

export function filtroMensileSolaLettura(filtro: string) {
  return ["preventivi_mese_precedente", "fatture_mese_precedente"].includes(
    filtro
  );
}


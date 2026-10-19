export const SERVIZI = {
  RI: "Riparazione idraulica", RE: "Riparazione elettronica", RC: "Revisione completa",
  PS: "Programma Scambio", PSMI: "Programma Scambio Made in Italy",
} as const;
export type Servizio = keyof typeof SERVIZI;

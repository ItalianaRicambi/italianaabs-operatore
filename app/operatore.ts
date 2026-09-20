import "server-only";

import { createHmac, timingSafeEqual } from "node:crypto";
import { cookies } from "next/headers";

export const COOKIE_OPERATORE = "italianaabs_operatore";

export const OPERATORI = [
  "Operatore 1",
  "Operatore 2",
  "Operatore 3",
  "Operatore 4",
] as const;

export type Operatore = (typeof OPERATORI)[number];

const ID_OPERATORE: Record<Operatore, string> = {
  "Operatore 1": "1",
  "Operatore 2": "2",
  "Operatore 3": "3",
  "Operatore 4": "4",
};

const OPERATORE_DA_ID: Record<string, Operatore> = {
  "1": "Operatore 1",
  "2": "Operatore 2",
  "3": "Operatore 3",
  "4": "Operatore 4",
};

export function operatoreValido(value: unknown): value is Operatore {
  return OPERATORI.includes(value as Operatore);
}

function firma(idOperatore: string, segreto: string): string {
  return createHmac("sha256", segreto)
    .update(`italianaabs:${idOperatore}`)
    .digest("base64url");
}

function stringheUgualiSicure(a: string, b: string): boolean {
  const bufferA = Buffer.from(a);
  const bufferB = Buffer.from(b);

  if (bufferA.length !== bufferB.length) {
    return false;
  }

  return timingSafeEqual(bufferA, bufferB);
}

export function creaSessioneOperatore(operatore: Operatore): string | null {
  const segreto = process.env.OPERATORE_SESSION_SECRET;

  if (!segreto || segreto.length < 32) {
    return null;
  }

  const idOperatore = ID_OPERATORE[operatore];
  return `${idOperatore}.${firma(idOperatore, segreto)}`;
}

function leggiSessioneOperatore(value: string | undefined): Operatore | null {
  const segreto = process.env.OPERATORE_SESSION_SECRET;

  if (!value || !segreto || segreto.length < 32) {
    return null;
  }

  const [idOperatore, firmaRicevuta, parteExtra] = value.split(".");
  const operatore = OPERATORE_DA_ID[idOperatore];

  if (!operatore || !firmaRicevuta || parteExtra) {
    return null;
  }

  const firmaAttesa = firma(idOperatore, segreto);

  return stringheUgualiSicure(firmaRicevuta, firmaAttesa)
    ? operatore
    : null;
}

export async function getOperatoreAttivo(): Promise<Operatore | null> {
  const cookieStore = await cookies();
  const valore = cookieStore.get(COOKIE_OPERATORE)?.value;

  return leggiSessioneOperatore(valore);
}

export async function richiediOperatoreAttivo(): Promise<Operatore> {
  const operatore = await getOperatoreAttivo();

  if (!operatore) {
    throw new Error(
      "Sessione operatore non valida. Tornare alla Dashboard ed effettuare nuovamente l’accesso."
    );
  }

  return operatore;
}

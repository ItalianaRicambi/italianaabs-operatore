import "server-only";

import { cookies } from "next/headers";

export const COOKIE_OPERATORE = "italianaabs_operatore";

export const OPERATORI = [
  "Operatore 1",
  "Operatore 2",
  "Operatore 3",
  "Operatore 4",
] as const;

export type Operatore = (typeof OPERATORI)[number];

export function operatoreValido(value: unknown): value is Operatore {
  return OPERATORI.includes(value as Operatore);
}

export async function getOperatoreAttivo(): Promise<Operatore | null> {
  const cookieStore = await cookies();
  const valore = cookieStore.get(COOKIE_OPERATORE)?.value;

  return operatoreValido(valore) ? valore : null;
}

export async function richiediOperatoreAttivo(): Promise<Operatore> {
  const operatore = await getOperatoreAttivo();

  if (!operatore) {
    throw new Error(
      "Sessione operatore non selezionata. Tornare alla Dashboard e scegliere l’operatore."
    );
  }

  return operatore;
}


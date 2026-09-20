"use server";

import { createHash, timingSafeEqual } from "node:crypto";
import { cookies } from "next/headers";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import {
  COOKIE_OPERATORE,
  creaSessioneOperatore,
  operatoreValido,
  type Operatore,
} from "./operatore";

type StatoAccesso = {
  errore: string | null;
};

function nomeVariabilePin(operatore: Operatore): string {
  return `OPERATORE_${operatore.slice(-1)}_PIN`;
}

function valoriUgualiSicuri(a: string, b: string): boolean {
  const hashA = createHash("sha256").update(a).digest();
  const hashB = createHash("sha256").update(b).digest();
  return timingSafeEqual(hashA, hashB);
}

export async function selezionaOperatore(
  _statoPrecedente: StatoAccesso,
  formData: FormData
): Promise<StatoAccesso> {
  const operatore = String(formData.get("operatore") || "").trim();
  const pin = String(formData.get("pin") || "").trim();

  if (!operatoreValido(operatore)) {
    return { errore: "Seleziona un operatore." };
  }

  const pinAtteso = process.env[nomeVariabilePin(operatore)];

  if (!pinAtteso) {
    return {
      errore: "PIN non configurato. Contattare l’amministratore della Dashboard.",
    };
  }

  if (!pin || !valoriUgualiSicuri(pin, pinAtteso)) {
    await new Promise((resolve) => setTimeout(resolve, 700));
    return { errore: "PIN non corretto. Riprova." };
  }

  const valoreSessione = creaSessioneOperatore(operatore);

  if (!valoreSessione) {
    return {
      errore: "Sessione non configurata. Contattare l’amministratore della Dashboard.",
    };
  }

  const cookieStore = await cookies();

  cookieStore.set({
    name: COOKIE_OPERATORE,
    value: valoreSessione,
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "strict",
    path: "/",
  });

  revalidatePath("/", "layout");
  redirect("/");
}

export async function cambiaOperatore() {
  const cookieStore = await cookies();
  cookieStore.delete(COOKIE_OPERATORE);
  revalidatePath("/", "layout");
  redirect("/");
}

"use server";

import { cookies } from "next/headers";
import { revalidatePath } from "next/cache";
import {
  COOKIE_OPERATORE,
  operatoreValido,
} from "./operatore";

export async function selezionaOperatore(formData: FormData) {
  const operatore = String(formData.get("operatore") || "").trim();

  if (!operatoreValido(operatore)) {
    throw new Error("Operatore non valido");
  }

  const cookieStore = await cookies();

  cookieStore.set({
    name: COOKIE_OPERATORE,
    value: operatore,
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax",
    path: "/",
  });

  revalidatePath("/", "layout");
}

export async function cambiaOperatore() {
  const cookieStore = await cookies();
  cookieStore.delete(COOKIE_OPERATORE);
  revalidatePath("/", "layout");
}


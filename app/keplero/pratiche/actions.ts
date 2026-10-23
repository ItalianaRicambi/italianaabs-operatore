"use server";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { getOperatoreAttivo } from "../../operatore";
import { rpcOriginaliK } from "../../lib/originaliKepleroServer";

export async function prendiInCaricoLavoroK(dati: FormData) {
  const op = await getOperatoreAttivo(); if (!op) throw new Error("Accesso richiesto");
  const chiave = String(dati.get("chiave") || ""), versione = Number(dati.get("versione"));
  if (chiave.length > 200 || !Number.isSafeInteger(versione) || versione < 1) throw new Error("Riferimento non valido");
  await rpcOriginaliK("prendi_in_carico_lavoro_k", { p_chiave: chiave, p_operatore: op, p_versione: versione });
  revalidatePath("/keplero/pratiche"); revalidatePath("/");
}
export async function verificaEsitoFonteK(dati: FormData) {
  const op = await getOperatoreAttivo(); if (!op) throw new Error("Accesso richiesto");
  const fonte = String(dati.get("fonte") || ""), chiave = String(dati.get("chiave") || ""), impronta = String(dati.get("impronta") || ""), nota = String(dati.get("nota") || "").trim();
  if (!["live", "originale", "documento", "richiesta"].includes(fonte) || chiave.length > 200 || impronta.length > 300 || nota.length < 10 || nota.length > 2000) throw new Error("Riferimento e motivazione richiesti");
  await rpcOriginaliK("verifica_esito_fonte_k", { p_fonte: fonte, p_chiave: chiave, p_impronta: impronta, p_nota: nota, p_operatore: op });
  revalidatePath("/keplero/pratiche"); revalidatePath("/");
  const pratica = String(dati.get("pratica") || ""), sessione = String(dati.get("sessione") || "");
  const q = new URLSearchParams({ salvato: "1" });
  if (/^[a-f0-9-]{36}$/i.test(pratica)) q.set("pratica", pratica);
  else if (/^[a-f0-9-]{36}$/i.test(sessione)) q.set("sessione", sessione);
  const scheda = String(dati.get("scheda") || "");
  if (!pratica && !sessione && /^(live|originale|documento|richiesta):.{1,190}$/.test(scheda)) q.set("scheda", scheda);
  redirect(`/keplero/pratiche?${q}`);
}

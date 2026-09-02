"use server";

import { revalidatePath } from "next/cache";

const AZIONI_CONSENTITE = new Set([
  "assistenza_in_gestione",
  "assistenza_attesa_cliente",
  "assistenza_attesa_rientro",
  "assistenza_risolta",
  "commerciale_dati_mancanti",
  "commerciale_dati_verificati",
  "commerciale_preventivo_inviato",
  "commerciale_ordine_acquisito",
  "commerciale_fatturata",
]);

function getSupabase() {
  const url = process.env.SUPABASE_URL;
  const secretKey = process.env.SUPABASE_SECRET_KEY;

  if (!url || !secretKey) {
    throw new Error("Variabili Supabase non configurate");
  }

  return { url, secretKey };
}

async function chiamaRpc(nome: string, body: Record<string, unknown>) {
  const { url, secretKey } = getSupabase();

  const response = await fetch(`${url}/rest/v1/rpc/${nome}`, {
    method: "POST",
    headers: {
      apikey: secretKey,
      Authorization: `Bearer ${secretKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
    cache: "no-store",
  });

  if (!response.ok) {
    const dettaglio = await response.text();
    throw new Error(
      `Operazione non riuscita (${response.status}): ${dettaglio}`
    );
  }

  return response.json();
}

export async function applicaAzioneOperatore(formData: FormData) {
  const praticaId = String(formData.get("pratica_id") || "").trim();
  const azione = String(formData.get("azione") || "").trim();
  const nota = String(formData.get("nota") || "").trim();

  if (!/^[0-9a-f-]{36}$/i.test(praticaId)) {
    throw new Error("ID pratica non valido");
  }

  if (!AZIONI_CONSENTITE.has(azione)) {
    throw new Error("Azione non consentita");
  }

  await chiamaRpc("applica_azione_operatore", {
    p_pratica_id: praticaId,
    p_azione: azione,
    p_nota: nota || null,
  });

  revalidatePath("/");
  revalidatePath(`/pratica/${praticaId}`);
}

export async function verificaCodiceOperatore(formData: FormData) {
  const praticaId = String(formData.get("pratica_id") || "").trim();
  const codice = String(formData.get("codice") || "").trim();
  const esito = String(formData.get("esito") || "").trim();

  if (!/^[0-9a-f-]{36}$/i.test(praticaId)) {
    throw new Error("ID pratica non valido");
  }

  if (!codice) {
    throw new Error("Codice non valido");
  }

  if (!["confermato", "scartato"].includes(esito)) {
    throw new Error("Esito non consentito");
  }

  await chiamaRpc("verifica_codice_operatore", {
    p_pratica_id: praticaId,
    p_codice: codice,
    p_esito: esito,
  });

  revalidatePath("/");
  revalidatePath(`/pratica/${praticaId}`);
}

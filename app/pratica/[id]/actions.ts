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

  const url = process.env.SUPABASE_URL;
  const secretKey = process.env.SUPABASE_SECRET_KEY;

  if (!url || !secretKey) {
    throw new Error("Variabili Supabase non configurate");
  }

  const response = await fetch(
    `${url}/rest/v1/rpc/applica_azione_operatore`,
    {
      method: "POST",
      headers: {
        apikey: secretKey,
        Authorization: `Bearer ${secretKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        p_pratica_id: praticaId,
        p_azione: azione,
        p_nota: nota || null,
      }),
      cache: "no-store",
    }
  );

  if (!response.ok) {
    const dettaglio = await response.text();
    throw new Error(
      `Aggiornamento pratica non riuscito (${response.status}): ${dettaglio}`
    );
  }

  revalidatePath("/");
  revalidatePath(`/pratica/${praticaId}`);
}

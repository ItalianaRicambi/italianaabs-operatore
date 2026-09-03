"use server";

import { revalidatePath } from "next/cache";

const AZIONI_CONSENTITE = new Set([
  // Assistenza già esistente
  "assistenza_in_gestione",
  "assistenza_attesa_cliente",
  "assistenza_attesa_rientro",
  "assistenza_risolta",

  // Commerciale già esistente
  "commerciale_dati_mancanti",
  "commerciale_dati_verificati",
  "commerciale_preventivo_inviato",
  "commerciale_ordine_acquisito",
  "commerciale_fatturata",

  // Nuove azioni operatore
  "operatore_non_assistenza",
  "commerciale_richiesta_verifica",
  "commerciale_rifiuta_lavorazione",

  // Logistica / ritiri
  "logistica_ritiro_richiesto",
  "logistica_ritiro_programmato",
  "logistica_ritirato",
  "logistica_annulla_ritiro",
]);

const STATI_COMMERCIALI_CORREGGIBILI = new Set([
  "da_preventivare",
  "preventivo_inviato",
  "ordine_acquisito",
  "fatturata",
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

async function leggiPratica(praticaId: string) {
  const { url, secretKey } = getSupabase();

  const response = await fetch(
    `${url}/rest/v1/pratiche?id=eq.${encodeURIComponent(praticaId)}&select=*`,
    {
      headers: {
        apikey: secretKey,
        Authorization: `Bearer ${secretKey}`,
      },
      cache: "no-store",
    }
  );

  if (!response.ok) {
    const dettaglio = await response.text();
    throw new Error(
      `Lettura pratica non riuscita (${response.status}): ${dettaglio}`
    );
  }

  const righe = (await response.json()) as Array<Record<string, unknown>>;

  if (!righe.length) {
    throw new Error("Pratica non trovata");
  }

  return righe[0];
}

async function aggiornaPratica(
  praticaId: string,
  modifiche: Record<string, unknown>
) {
  const { url, secretKey } = getSupabase();

  const response = await fetch(
    `${url}/rest/v1/pratiche?id=eq.${encodeURIComponent(praticaId)}&select=*`,
    {
      method: "PATCH",
      headers: {
        apikey: secretKey,
        Authorization: `Bearer ${secretKey}`,
        "Content-Type": "application/json",
        Prefer: "return=representation",
      },
      body: JSON.stringify(modifiche),
      cache: "no-store",
    }
  );

  if (!response.ok) {
    const dettaglio = await response.text();
    throw new Error(
      `Aggiornamento pratica non riuscito (${response.status}): ${dettaglio}`
    );
  }

  const righe = (await response.json()) as Array<Record<string, unknown>>;

  if (!righe.length) {
    throw new Error("La pratica non è stata aggiornata");
  }

  return righe[0];
}

async function registraCorrezioneStato(
  praticaId: string,
  statoPrima: Record<string, unknown>,
  statoDopo: Record<string, unknown>,
  nota: string
) {
  const { url, secretKey } = getSupabase();

  const response = await fetch(`${url}/rest/v1/azioni_operatore`, {
    method: "POST",
    headers: {
      apikey: secretKey,
      Authorization: `Bearer ${secretKey}`,
      "Content-Type": "application/json",
      Prefer: "return=minimal",
    },
    body: JSON.stringify({
      pratica_id: praticaId,
      azione: "operatore_correzione_stato",
      nota,
      stato_prima: statoPrima,
      stato_dopo: statoDopo,
    }),
    cache: "no-store",
  });

  if (!response.ok) {
    const dettaglio = await response.text();
    throw new Error(
      `Registrazione storico non riuscita (${response.status}): ${dettaglio}`
    );
  }
}

export async function correggiStatoCommercialeOperatore(formData: FormData) {
  const praticaId = String(formData.get("pratica_id") || "").trim();
  const stato = String(formData.get("stato") || "").trim();
  const notaOperatore = String(formData.get("nota") || "").trim();

  if (!/^[0-9a-f-]{36}$/i.test(praticaId)) {
    throw new Error("ID pratica non valido");
  }

  if (!STATI_COMMERCIALI_CORREGGIBILI.has(stato)) {
    throw new Error("Stato commerciale non consentito");
  }

  const prima = await leggiPratica(praticaId);
  const adesso = new Date().toISOString();

  const modifiche: Record<string, unknown> = {
    tipo_flusso: "commerciale",
    fonte_classificazione: "operatore",
    blocco_classificazione_operatore: true,
    stato_assistenza: "non_applicabile",
    stato_completezza: "completa_da_preventivare",
    motivo_incompletezza: null,
    nota_incompletezza: null,
  };

  let etichetta = "";

  if (stato === "da_preventivare") {
    modifiche.stato_commerciale = "da_preventivare";
    modifiche.stato_fatturazione = "non_applicabile";
    modifiche.preventivo_inviato_at = null;
    modifiche.ordine_acquisito_at = null;
    modifiche.data_fattura = null;
    etichetta = "Da preventivare";
  } else if (stato === "preventivo_inviato") {
    modifiche.stato_commerciale = "preventivo_inviato";
    modifiche.stato_fatturazione = "non_applicabile";
    modifiche.preventivo_inviato_at = prima.preventivo_inviato_at || adesso;
    modifiche.ordine_acquisito_at = null;
    modifiche.data_fattura = null;
    etichetta = "Preventivo inviato";
  } else if (stato === "ordine_acquisito") {
    modifiche.stato_commerciale = "ordine_acquisito";
    modifiche.stato_fatturazione = "da_fatturare";
    modifiche.preventivo_inviato_at = prima.preventivo_inviato_at || adesso;
    modifiche.ordine_acquisito_at = prima.ordine_acquisito_at || adesso;
    modifiche.data_fattura = null;
    etichetta = "Ordine acquisito / da fatturare";
  } else if (stato === "fatturata") {
    modifiche.stato_commerciale = "ordine_acquisito";
    modifiche.stato_fatturazione = "fatturato";
    modifiche.preventivo_inviato_at = prima.preventivo_inviato_at || adesso;
    modifiche.ordine_acquisito_at = prima.ordine_acquisito_at || adesso;
    modifiche.data_fattura = prima.data_fattura || adesso;
    etichetta = "Fatturata";
  }

  const dopo = await aggiornaPratica(praticaId, modifiche);

  const nota = notaOperatore
    ? `Correzione manuale stato: ${etichetta}. ${notaOperatore}`
    : `Correzione manuale stato: ${etichetta}.`;

  await registraCorrezioneStato(praticaId, prima, dopo, nota);

  revalidatePath("/");
  revalidatePath(`/pratica/${praticaId}`);
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

  await chiamaRpc("applica_azione_operatore_estesa", {
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

export async function aggiungiCodiceOperatore(formData: FormData) {
  const praticaId = String(formData.get("pratica_id") || "").trim();
  const codice = String(formData.get("codice") || "").trim();
  const tipoCodice = String(formData.get("tipo_codice") || "Altro").trim();
  const note = String(formData.get("note") || "").trim();

  if (!/^[0-9a-f-]{36}$/i.test(praticaId)) {
    throw new Error("ID pratica non valido");
  }

  if (!codice) {
    throw new Error("Inserire il codice corretto");
  }

  await chiamaRpc("aggiungi_codice_operatore", {
    p_pratica_id: praticaId,
    p_codice: codice,
    p_tipo_codice: tipoCodice || "Altro",
    p_note: note || null,
  });

  revalidatePath("/");
  revalidatePath(`/pratica/${praticaId}`);
}

import assert from "node:assert/strict";
import test from "node:test";
import { NextRequest } from "next/server";
import { POST } from "../app/api/keplero/live/route";

const pratica = "00000000-0000-4000-8000-000000000001";
const sessione = "00000000-0000-4000-8000-000000000002";
const baseKey = `conversation:${sessione}`;
const temporaryKey = `${baseKey}:veicolo:test001`;

// Simula il contratto reale: l'attivazione elimina la chiave provvisoria,
// mentre conferma, contesti e ricevuta richiedono un collegamento valido.
async function richiesta(options: {
  nuova?: boolean; conferma?: boolean; erroreRicevuta?: boolean;
  erroreAttivazione?: boolean; attivazioneDiscordante?: boolean;
} = {}) {
  const nuova = options.nuova !== false;
  let linkedKey = nuova ? temporaryKey : baseKey;
  const calls: string[] = [];
  const originalFetch = globalThis.fetch;
  const originalEnv = { ...process.env };
  const originalError = console.error;
  process.env.KEPLERO_WEBHOOK_SECRET = "test-only";
  process.env.SUPABASE_URL = "https://database.invalid";
  process.env.SUPABASE_SECRET_KEY = "test-only";
  console.error = () => {};
  globalThis.fetch = async (input, init) => {
    const url = String(input);
    assert.ok(url.startsWith("https://database.invalid/rest/v1/"));
    const name = url.split("/").pop()!;
    calls.push(name);
    const body = JSON.parse(String(init?.body || "{}"));
    if (name === "prepara_instradamento_keplero") {
      return Response.json({ external_key: linkedKey, nuova_pratica: nuova, usa_conversation_id: false });
    }
    if (name === "upsert_keplero_live") {
      assert.equal(body.p_external_key, linkedKey);
      return Response.json({ pratica_id: pratica });
    }
    if (name === "attiva_pratica_conversazione_keplero") {
      assert.equal(body.p_external_key, baseKey);
      assert.equal(body.p_pratica_id, pratica);
      if (options.erroreAttivazione) return Response.json({ error: "test" }, { status: 500 });
      linkedKey = baseKey;
      return Response.json({ attiva: true, external_key: baseKey,
        pratica_id: options.attivazioneDiscordante ? sessione : pratica });
    }
    if (["esito_ordine_contestuale_keplero", "conferma_ordine_da_keplero",
      "contesto_offerta_keplero", "contesto_rientro_keplero", "esito_registrazione_commerciale_k"].includes(name)) {
      if (body.p_external_key !== linkedKey) {
        return Response.json({ error: "Collegamento live non valido" }, { status: 400 });
      }
      assert.equal(body.p_pratica_id, pratica);
    }
    if (name === "esito_registrazione_commerciale_k") {
      if (options.erroreRicevuta) return Response.json({ error: "test" }, { status: 500 });
      return Response.json({ versione_contratto: "2026-10-23-esiti-v1", pratica_id: pratica,
        ricevuta: true, ordine_registrato: false, preventivo_inviato: false,
        stato_commerciale: "raccolta_dati", stato_fatturazione: "non_applicabile",
        istruzione: "Richiesta registrata; ordine non acquisito." });
    }
    if (name === "conferma_ordine_da_keplero") {
      // La prova originale resta sotto la chiave di ingresso fino alla conferma.
      assert.equal(body.p_external_key, nuova ? temporaryKey : baseKey);
      return Response.json({ aggiornato: false, motivo: "offerta_non_letta" });
    }
    if (name === "esito_ordine_contestuale_keplero") return Response.json({ confermato: false });
    if (name === "contesto_offerta_keplero") return Response.json({ scelta: null });
    if (name === "contesto_rientro_keplero") return Response.json({ ritiro: null });
    if (name === "contesto_cliente_keplero") return Response.json({ stato: "nuovo" });
    if (name === "prepara_richiesta_dati_amministrativi") return Response.json({ necessaria: false });
    throw new Error(`Chiamata inattesa: ${name}`);
  };
  try {
    const response = await POST(new NextRequest("https://dashboard.invalid/api/keplero/live", {
      method: "POST", headers: { "x-keplero-secret": "test-only", "content-type": "application/json",
        "X-Keplero-SessionId": sessione },
      body: JSON.stringify({ targa: "TEST001", channel: "whatsapp",
        ultimo_messaggio_cliente: options.conferma ? "Accetto il preventivo" : "Vorrei un preventivo" }),
    }));
    return { status: response.status, body: await response.json(), calls, linkedKey };
  } finally {
    globalThis.fetch = originalFetch;
    console.error = originalError;
    for (const name of ["KEPLERO_WEBHOOK_SECRET", "SUPABASE_URL", "SUPABASE_SECRET_KEY"]) {
      if (originalEnv[name] === undefined) delete process.env[name];
      else process.env[name] = originalEnv[name];
    }
  }
}

test("nuova pratica: ricevuta verificata prima di sostituire il collegamento temporaneo", async () => {
  const r = await richiesta();
  assert.equal(r.status, 200);
  assert.equal(r.body.ok, true);
  assert.equal(r.body.external_key, baseKey);
  assert.equal(r.linkedKey, baseKey);
  assert.equal(r.calls.at(-1), "attiva_pratica_conversazione_keplero");
  assert.equal(r.body.riconoscimento_ordine.registrato, false);
});

test("conferma esplicita: conserva la chiave della prova e non inventa un ordine", async () => {
  const r = await richiesta({ conferma: true });
  assert.equal(r.status, 200);
  assert.ok(r.calls.includes("conferma_ordine_da_keplero"));
  assert.equal(r.body.riconoscimento_ordine.rilevato, true);
  assert.equal(r.body.riconoscimento_ordine.registrato, false);
});

test("pratica esistente: nessuna attivazione e stessa chiave in risposta", async () => {
  const r = await richiesta({ nuova: false });
  assert.equal(r.status, 200);
  assert.equal(r.body.external_key, baseKey);
  assert.ok(!r.calls.includes("attiva_pratica_conversazione_keplero"));
});

test("ricevuta fallita: nessun falso successo e collegamento provvisorio conservato", async () => {
  const r = await richiesta({ erroreRicevuta: true });
  assert.equal(r.status, 500);
  assert.equal(r.body.ok, false);
  assert.equal(r.linkedKey, temporaryKey);
  assert.ok(!r.calls.includes("attiva_pratica_conversazione_keplero"));
});

test("attivazione fallita o discordante: nessun falso successo", async () => {
  for (const options of [{ erroreAttivazione: true }, { attivazioneDiscordante: true }]) {
    const r = await richiesta(options);
    assert.equal(r.status, 500);
    assert.equal(r.body.ok, false);
  }
});

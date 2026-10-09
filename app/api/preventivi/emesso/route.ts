import { timingSafeEqual } from "node:crypto";
import { NextRequest, NextResponse } from "next/server";

import { normalizzaEventoPreventivo } from "./normalizzaPreventivo";
import { esitoRegistrazionePreventivo } from "./esitoRegistrazione";
import { createHash } from "node:crypto";
import { leggiOffertaDaPdf, leggiOffertaDaTesto, normalizzaOpzioni, type LetturaOfferta } from "../../../lib/offerte";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function segretiUguali(a: string, b: string) {
  const left = Buffer.from(a);
  const right = Buffer.from(b);
  return left.length === right.length && timingSafeEqual(left, right);
}

export async function POST(request: NextRequest) {
  try {
    const secret = process.env.PREVENTIVI_WEBHOOK_SECRET;
    const supplied =
      request.headers.get("x-preventivi-secret") ||
      request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ||
      "";

    if (!secret) {
      return NextResponse.json(
        { ok: false, error: "PREVENTIVI_WEBHOOK_SECRET non configurata" },
        { status: 500 }
      );
    }

    if (!supplied || !segretiUguali(supplied, secret)) {
      return NextResponse.json(
        { ok: false, error: "Non autorizzato" },
        { status: 401 }
      );
    }

    const url = process.env.SUPABASE_URL;
    const secretKey = process.env.SUPABASE_SECRET_KEY;

    if (!url || !secretKey) {
      return NextResponse.json(
        { ok: false, error: "Variabili Supabase non configurate" },
        { status: 500 }
      );
    }

    const rawBody = await request.text();
    if (Buffer.byteLength(rawBody, "utf8") > 4.25 * 1024 * 1024) return NextResponse.json({ ok: false, error: "Documento superiore a 3 MB" }, { status: 413 });
    const payload = JSON.parse(rawBody) as Record<string, unknown>;
    const evento = normalizzaEventoPreventivo(payload);
    let lettura: LetturaOfferta;
    let fonte = "pdf";
    try {
      if (typeof payload.pdf_base64 === "string") {
        lettura = await leggiOffertaDaPdf(new Uint8Array(Buffer.from(payload.pdf_base64, "base64")), evento.targa);
      } else if (typeof payload.testo_pdf === "string") {
        lettura = leggiOffertaDaTesto(payload.testo_pdf, evento.targa);
        fonte = "testo_pdf";
      } else if (Array.isArray(payload.opzioni)) {
        const opzioni = normalizzaOpzioni(payload.opzioni);
        lettura = { opzioni, impronta: createHash("sha256").update(JSON.stringify(opzioni)).digest("hex"), testo: "", errore: null, validita_giorni: null };
        fonte = "dati_preventivo";
      } else {
        lettura = { opzioni: [], impronta: createHash("sha256").update(`assente:${evento.externalId}:${evento.inviatoAt}`).digest("hex"), testo: "", errore: typeof payload.errore_lettura_pdf === "string" ? payload.errore_lettura_pdf.slice(0, 500) : "Il collegamento Drive ha trasmesso il link senza il PDF: lettura delle alternative da completare", validita_giorni: null };
      }
    } catch (error) {
      lettura = { opzioni: [], impronta: createHash("sha256").update(String(payload.pdf_base64 || payload.testo_pdf || JSON.stringify(payload.opzioni))).digest("hex"), testo: "", errore: error instanceof Error ? error.message : "Lettura non riuscita", validita_giorni: null };
    }

    const response = await fetch(
      `${url}/rest/v1/rpc/registra_preventivo_con_offerta`,
      {
        method: "POST",
        headers: {
          apikey: secretKey,
          Authorization: `Bearer ${secretKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          p_external_id: evento.externalId,
          p_nome_file: evento.nomeFile,
          p_targa: evento.targa,
          p_file_url: evento.fileUrl,
          p_data_offerta: evento.dataOfferta,
          p_inviato_at: evento.inviatoAt,
          p_contenuto: { ...lettura, fonte },
        }),
        cache: "no-store",
      }
    );

    const raw = await response.text();

    if (!response.ok) {
      console.error("ERRORE REGISTRAZIONE PREVENTIVO EMESSO", {
        supabase_status: response.status,
        supabase_response: raw,
        external_id: evento.externalId,
        targa: evento.targa,
      });

      return NextResponse.json(
        {
          ok: false,
          error: `Registrazione Supabase ${response.status}`,
          detail: raw,
        },
        { status: 500 }
      );
    }

    let result: unknown = raw;
    try {
      result = JSON.parse(raw);
    } catch {
      // Mantiene la risposta testuale se PostgREST non restituisce JSON.
    }

    const esito = esitoRegistrazionePreventivo(result);
    if (!esito.ok) {
      console.error("PREVENTIVO NON REGISTRATO", {
        external_id: evento.externalId,
        targa: evento.targa,
        esito: esito.error,
      });
    }
    return NextResponse.json(
      { ok: esito.ok, ...(esito.error ? { error: esito.error } : {}), result },
      { status: esito.status }
    );
  } catch (error) {
    const messaggio =
      error instanceof Error ? error.message : "Errore sconosciuto";

    return NextResponse.json(
      { ok: false, error: messaggio },
      { status: 400 }
    );
  }
}

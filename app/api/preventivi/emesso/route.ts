import { timingSafeEqual } from "node:crypto";
import { NextRequest, NextResponse } from "next/server";

import { normalizzaEventoPreventivo } from "./normalizzaPreventivo";

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

    const evento = normalizzaEventoPreventivo(
      (await request.json()) as Record<string, unknown>
    );

    const response = await fetch(
      `${url}/rest/v1/rpc/registra_preventivo_emesso_auto`,
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

    return NextResponse.json({ ok: true, result });
  } catch (error) {
    const messaggio =
      error instanceof Error ? error.message : "Errore sconosciuto";

    return NextResponse.json(
      { ok: false, error: messaggio },
      { status: 400 }
    );
  }
}

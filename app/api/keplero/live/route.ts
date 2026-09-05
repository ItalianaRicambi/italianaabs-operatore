import { createHash } from "node:crypto";
import { NextRequest, NextResponse } from "next/server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type Body = Record<string, unknown>;

function testo(value: unknown) {
  if (value === null || value === undefined) return "";
  return String(value).trim();
}

function bool(value: unknown) {
  if (typeof value === "boolean") return value;

  const v = testo(value).toLowerCase();

  return ["1", "true", "vero", "si", "sì", "yes", "completo"].includes(v);
}

function lista(value: unknown) {
  if (Array.isArray(value)) {
    return value.map(testo).filter(Boolean);
  }

  const raw = testo(value);

  if (!raw) return [];

  return raw
    .split(/\r?\n|;|\||,/g)
    .map((v) => v.trim())
    .filter(Boolean);
}

function normalizzaTarga(value: unknown) {
  return testo(value)
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "");
}

function normalizzaCodice(value: string) {
  return value
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, "");
}

function uuidValido(value: string) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    value
  );
}

function primo(body: Body, ...keys: string[]) {
  for (const key of keys) {
    const value = body[key];

    if (
      value !== undefined &&
      value !== null &&
      testo(value) !== ""
    ) {
      return value;
    }
  }

  return null;
}

function externalKey(body: Body, conversationId: string) {
  if (uuidValido(conversationId)) {
    return `conversation:${conversationId}`;
  }

  const channel =
    testo(primo(body, "channel", "canale")) || "keplero";

  const telefono =
    testo(primo(body, "telefono", "phone", "whatsapp"));

  const targa =
    normalizzaTarga(primo(body, "targa", "plate"));

  const nome =
    testo(primo(body, "nome_cliente", "cliente", "nome"));

  // Fallback stabile nella stessa giornata.
  // Se Keplero espone il conversation_id, verrà usato quello.
  const giorno = new Date().toISOString().slice(0, 10);

  const base = [
    channel,
    telefono,
    targa,
    nome,
    giorno,
  ].join("|");

  const hash = createHash("sha256")
    .update(base)
    .digest("hex")
    .slice(0, 32);

  return `fallback:${hash}`;
}

export async function POST(request: NextRequest) {
  try {
    /*
     * ============================================================
     * AUTORIZZAZIONE KEPLERO
     * ============================================================
     */

    const secret = process.env.KEPLERO_WEBHOOK_SECRET;

    const supplied =
      request.headers.get("x-keplero-secret") ||
      request.headers
        .get("authorization")
        ?.replace(/^Bearer\s+/i, "");

    if (!secret) {
      return NextResponse.json(
        {
          ok: false,
          error: "KEPLERO_WEBHOOK_SECRET non configurata",
        },
        {
          status: 500,
        }
      );
    }

    if (!supplied || supplied !== secret) {
      return NextResponse.json(
        {
          ok: false,
          error: "Non autorizzato",
        },
        {
          status: 401,
        }
      );
    }

    /*
     * ============================================================
     * LETTURA PAYLOAD KEPLERO
     * ============================================================
     */

    const body = (await request.json()) as Body;

    const conversationId = testo(
      primo(
        body,
        "conversation_id",
        "keplero_conversation_id",
        "session_id",
        "conversationId"
      )
    );

    const targa = normalizzaTarga(
      primo(body, "targa", "plate")
    );

    /*
     * ============================================================
     * CODICI IDENTIFICATIVI
     *
     * La targa non deve mai essere salvata come codice ABS.
     * ============================================================
     */

    const codiciOriginali = lista(
      primo(
        body,
        "codici_identificativi",
        "codici",
        "device_codes"
      )
    );

    const codici = codiciOriginali
      .filter(
        (codice) =>
          !targa ||
          normalizzaCodice(codice) !== targa
      )
      .map((codice) => ({
        codice,
        fonte: "keplero_live",
        verificato: false,
      }));

    /*
     * ============================================================
     * DTC
     * ============================================================
     */

    const dtc = lista(
      primo(
        body,
        "dtc",
        "codici_guasto",
        "error_codes"
      )
    );

    /*
     * ============================================================
     * ALLEGATI
     * ============================================================
     */

    const allegati = lista(
      primo(
        body,
        "allegati",
        "attachments",
        "attachment_urls"
      )
    ).map((url) => ({
      url,
      nome: "Allegato Keplero",
      tipo: "Allegato",
      timestamp: new Date().toISOString(),
    }));

    /*
     * ============================================================
     * TIPO FLUSSO
     * ============================================================
     */

    let tipoFlusso = testo(
      primo(
        body,
        "tipo_flusso",
        "flusso",
        "request_type"
      )
    ).toLowerCase();

    if (
      !["commerciale", "assistenza"].includes(tipoFlusso)
    ) {
      const assistenzaHint = [
        testo(primo(body, "tipo_assistenza")),
        testo(primo(body, "descrizione_guasto")),
        testo(
          primo(
            body,
            "ultimo_messaggio_cliente",
            "messaggio"
          )
        ),
      ]
        .join(" ")
        .toLowerCase();

      tipoFlusso =
        /(garanzia|post[- ]?vendita|post[- ]?riparazione|post[- ]?scambio|problema dopo|assistenza|rientro|reso|codifica|montaggio)/i.test(
          assistenzaHint
        )
          ? "assistenza"
          : "commerciale";
    }

    const tipoAssistenza =
      testo(primo(body, "tipo_assistenza")) ||
      "altro";

    const priorita =
      testo(
        primo(
          body,
          "priorita_assistenza",
          "priorita"
        )
      ).toLowerCase() || "normale";

    /*
     * ============================================================
     * SUPABASE
     * ============================================================
     */

    const url = process.env.SUPABASE_URL;
    const secretKey = process.env.SUPABASE_SECRET_KEY;

    if (!url || !secretKey) {
      return NextResponse.json(
        {
          ok: false,
          error: "Variabili Supabase non configurate",
        },
        {
          status: 500,
        }
      );
    }

    /*
     * ============================================================
     * CHIAVE STABILE DELLA CONVERSAZIONE
     * ============================================================
     */

    const key = externalKey(body, conversationId);

    /*
     * ============================================================
     * CORPO RPC
     * ============================================================
     */

    const datiCompleti = bool(
      primo(
        body,
        "dati_completi",
        "completo",
        "richiesta_completa"
      )
    );

    const rpcBody = {
      p_external_key: key,

      p_conversation_id:
        uuidValido(conversationId)
          ? conversationId
          : null,

      p_channel:
        testo(
          primo(
            body,
            "channel",
            "canale"
          )
        ) || "keplero",

      p_nome_cliente:
        testo(
          primo(
            body,
            "nome_cliente",
            "cliente",
            "nome"
          )
        ) || null,

      p_telefono:
        testo(
          primo(
            body,
            "telefono",
            "phone",
            "whatsapp"
          )
        ) || null,

      p_targa:
        targa || null,

      p_marca_veicolo:
        testo(
          primo(
            body,
            "marca_veicolo",
            "marca"
          )
        ) || null,

      p_modello_veicolo:
        testo(
          primo(
            body,
            "modello_veicolo",
            "modello"
          )
        ) || null,

      p_tipo_componente:
        testo(
          primo(
            body,
            "tipo_componente",
            "componente"
          )
        ) || "ABS",

      p_descrizione_guasto:
        testo(
          primo(
            body,
            "descrizione_guasto",
            "problema",
            "riepilogo_operativo",
            "richiesta"
          )
        ) || null,

      p_ultimo_messaggio_cliente:
        testo(
          primo(
            body,
            "ultimo_messaggio_cliente",
            "messaggio_cliente",
            "messaggio"
          )
        ) || null,

      p_tipo_flusso:
        tipoFlusso,

      p_tipo_assistenza:
        tipoAssistenza,

      p_priorita_assistenza:
        priorita,

      p_dati_completi:
        datiCompleti,

      p_motivo_incompletezza:
        testo(
          primo(
            body,
            "motivo_incompletezza",
            "dati_mancanti",
            "nota_incompletezza"
          )
        ) || null,

      p_codici:
        codici,

      p_dtc:
        dtc,

      p_allegati:
        allegati,

      p_payload:
        body,
    };

    /*
     * ============================================================
     * CHIAMATA RPC
     * ============================================================
     */

    const response = await fetch(
      `${url}/rest/v1/rpc/upsert_keplero_live`,
      {
        method: "POST",

        headers: {
          apikey: secretKey,
          Authorization: `Bearer ${secretKey}`,
          "Content-Type": "application/json",
        },

        body: JSON.stringify(rpcBody),

        cache: "no-store",
      }
    );

    const raw = await response.text();

    /*
     * ============================================================
     * DIAGNOSTICA ERRORI SUPABASE
     *
     * IMPORTANTE:
     * questa parte serve a far comparire finalmente nei Logs Vercel
     * il vero errore restituito da Supabase.
     * ============================================================
     */

    if (!response.ok) {
      console.error(
        "ERRORE UPSERT KEPLERO LIVE",
        {
          supabase_status: response.status,

          supabase_response: raw,

          external_key: key,

          conversation_id:
            conversationId || null,

          tipo_flusso:
            tipoFlusso,

          tipo_assistenza:
            tipoAssistenza,

          priorita_assistenza:
            priorita,

          dati_completi:
            datiCompleti,

          numero_codici:
            codici.length,

          numero_dtc:
            dtc.length,

          numero_allegati:
            allegati.length,
        }
      );

      return NextResponse.json(
        {
          ok: false,
          error: `Supabase ${response.status}`,
          detail: raw,
        },
        {
          status: 500,
        }
      );
    }

    /*
     * ============================================================
     * RISPOSTA SUPABASE
     * ============================================================
     */

    let data: unknown = raw;

    try {
      data = JSON.parse(raw);
    } catch {
      // Se Supabase restituisce testo anziché JSON,
      // conserviamo semplicemente il contenuto originale.
    }

    /*
     * ============================================================
     * RISPOSTA POSITIVA A KEPLERO
     * ============================================================
     */

    return NextResponse.json({
      ok: true,

      message:
        "Pratica sincronizzata con Dashboard Operatore",

      result:
        data,

      external_key:
        key,

      codici_accettati:
        codici.length,

      codici_esclusi_perche_targa:
        codiciOriginali.length - codici.length,
    });
  } catch (error) {
    /*
     * ============================================================
     * ERRORE IMPREVISTO ENDPOINT
     * ============================================================
     */

    console.error(
      "ERRORE GENERALE /api/keplero/live",
      error
    );

    return NextResponse.json(
      {
        ok: false,

        error:
          error instanceof Error
            ? error.message
            : "Errore sconosciuto",
      },
      {
        status: 500,
      }
    );
  }
}

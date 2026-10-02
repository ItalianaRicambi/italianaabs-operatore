type FetchPaginatoOptions = {
  headers: Record<string, string>;
  pageSize?: number;
  retryDelayMs?: number;
};

function totaleDaContentRange(contentRange: string | null) {
  if (!contentRange) return null;

  const valore = contentRange.split("/")[1];
  if (!valore || valore === "*") return null;

  const totale = Number.parseInt(valore, 10);
  return Number.isFinite(totale) ? totale : null;
}

/**
 * Legge una risorsa PostgREST per intero, senza dipendere dal limite massimo
 * di righe configurato nel progetto Supabase (1.000 per impostazione standard).
 */
export async function fetchTutteLePagine<T>(
  url: string,
  { headers, pageSize = 1000, retryDelayMs = 1000 }: FetchPaginatoOptions
): Promise<T[]> {
  const righe: T[] = [];
  let offset = 0;

  while (true) {
    const opzioni: RequestInit = {
      headers: {
        ...headers,
        Prefer: "count=exact",
        Range: `${offset}-${offset + pageSize - 1}`,
        "Range-Unit": "items",
      },
      cache: "no-store",
    };
    let response = await fetch(url, opzioni);
    // Solo letture GET: ripete la stessa pagina senza duplicare i dati.
    // Gli altri errori di autenticazione restano errori, senza tentativi inutili.
    for (let tentativo = 0; tentativo < 3 && response.status === 401; tentativo++) {
      const errore = await response.clone().json().catch(() => null);
      if (errore?.code !== "PGRST303" || errore?.message !== "JWT issued at future") break;
      await new Promise((resolve) => setTimeout(resolve, retryDelayMs * 2 ** tentativo));
      response = await fetch(url, opzioni);
    }

    if (!response.ok) {
      const dettaglio = await response.text();
      throw new Error(`Errore Supabase ${response.status}: ${dettaglio}`);
    }

    const pagina = (await response.json()) as T[];
    righe.push(...pagina);

    const totale = totaleDaContentRange(response.headers.get("content-range"));
    offset += pagina.length;

    if (pagina.length === 0 || (totale !== null && offset >= totale)) {
      break;
    }
  }

  return righe;
}

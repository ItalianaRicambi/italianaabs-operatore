import assert from "node:assert/strict";
import test from "node:test";

import { fetchTutteLePagine } from "./supabaseRest.ts";

test("continua a paginare anche se Supabase restituisce meno righe del range richiesto", async (t) => {
  const originale = globalThis.fetch;
  const richieste: string[] = [];
  const dati = Array.from({ length: 1_118 }, (_, id) => ({ id }));

  globalThis.fetch = async (_input, init) => {
    const range = new Headers(init?.headers).get("range") ?? "0-999";
    richieste.push(range);
    const [da] = range.split("-").map(Number);
    const pagina = dati.slice(da, da + 500);
    const fine = pagina.length ? da + pagina.length - 1 : da;

    return new Response(JSON.stringify(pagina), {
      status: 200,
      headers: { "content-range": `${da}-${fine}/${dati.length}` },
    });
  };

  t.after(() => {
    globalThis.fetch = originale;
  });

  const risultato = await fetchTutteLePagine<{ id: number }>("https://test", {
    headers: { apikey: "test" },
  });

  assert.equal(risultato.length, 1_118);
  assert.deepEqual(richieste, ["0-999", "500-1499", "1000-1999"]);
});


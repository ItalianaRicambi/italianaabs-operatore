import assert from "node:assert/strict";
import test from "node:test";

import { fetchTutteLePagine } from "./supabaseRest.ts";

test("recupera un JWT futuro sulla seconda pagina senza perdere o duplicare righe", async (t) => {
  const originale = globalThis.fetch;
  const richieste: string[] = [];
  let fallito = false;
  globalThis.fetch = async (_input, init) => {
    const range = new Headers(init?.headers).get("range")!;
    richieste.push(range);
    if (range === "2-3" && !fallito) {
      fallito = true;
      return new Response(JSON.stringify({ code: "PGRST303", message: "JWT issued at future" }), { status: 401 });
    }
    return new Response(JSON.stringify(range === "0-1" ? [{id: 1}, {id: 2}] : [{id: 3}]),
      { headers: { "content-range": range === "0-1" ? "0-1/3" : "2-2/3" } });
  };
  t.after(() => { globalThis.fetch = originale; });
  const dati = await fetchTutteLePagine("https://test", { headers: {}, pageSize: 2, retryDelayMs: 0 });
  assert.deepEqual(dati, [{id: 1}, {id: 2}, {id: 3}]);
  assert.deepEqual(richieste, ["0-1", "2-3", "2-3"]);
});

test("si ferma dopo tre tentativi aggiuntivi se il JWT resta futuro", async (t) => {
  const originale = globalThis.fetch;
  let richieste = 0;
  globalThis.fetch = async () => {
    richieste++;
    return new Response(JSON.stringify({ code: "PGRST303", message: "JWT issued at future" }), { status: 401 });
  };
  t.after(() => { globalThis.fetch = originale; });
  await assert.rejects(fetchTutteLePagine("https://test", { headers: {}, retryDelayMs: 0 }), /JWT issued at future/);
  assert.equal(richieste, 4);
});

test("non ritenta una credenziale invalida", async (t) => {
  const originale = globalThis.fetch;
  let richieste = 0;
  globalThis.fetch = async () => {
    richieste++;
    return new Response(JSON.stringify({ code: "PGRST301", message: "Invalid JWT" }), { status: 401 });
  };
  t.after(() => { globalThis.fetch = originale; });
  await assert.rejects(fetchTutteLePagine("https://test", { headers: {}, retryDelayMs: 0 }), /Invalid JWT/);
  assert.equal(richieste, 1);
});

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

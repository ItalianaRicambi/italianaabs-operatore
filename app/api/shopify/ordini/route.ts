import { firmaShopifyValida, NEGOZIO_SHOPIFY, normalizzaOrdineShopify } from '../../../lib/ordiniShopify';
import { registraOrdineShopify } from '../../../lib/ordiniShopifyServer';
export const runtime = 'nodejs';
export const maxDuration = 30;
export async function POST(request: Request) {
  const secret = process.env.SHOPIFY_WEBHOOK_SECRET;
  if (!secret || secret.length < 32) return Response.json({ ok: false, errore: 'Collegamento Shopify non configurato' }, { status: 503 });
  if (request.headers.get('x-shopify-shop-domain') !== NEGOZIO_SHOPIFY || !['orders/create','orders/updated','orders/paid','orders/cancelled'].includes(request.headers.get('x-shopify-topic') || '')) return Response.json({ ok: false }, { status: 401 });
  // Limitare anche i flussi senza Content-Length, prima di allocare l'intero payload.
  const reader = request.body?.getReader();
  if (!reader) return Response.json({ ok: false }, { status: 400 });
  const chunks: Uint8Array[] = []; let size = 0;
  try {
    for (;;) { const chunk = await reader.read(); if (chunk.done) break; size += chunk.value.byteLength;
      if (size > 1_000_000) { await reader.cancel(); return Response.json({ ok: false }, { status: 413 }); } chunks.push(chunk.value); }
  } catch { return Response.json({ ok: false }, { status: 400 }); }
  const body = Buffer.concat(chunks);
  if (!firmaShopifyValida(body, request.headers.get('x-shopify-hmac-sha256'), secret)) return Response.json({ ok: false }, { status: 401 });
  let ordine;
  try { ordine = normalizzaOrdineShopify(JSON.parse(body.toString('utf8'))); }
  catch { return Response.json({ ok: false, errore: 'Dati ordine incompleti o non validi' }, { status: 422 }); }
  try { const esito = await registraOrdineShopify(ordine); return Response.json({ ok: true, ...esito }); }
  catch { return Response.json({ ok: false, errore: 'Ordine non registrato: riprovare la consegna' }, { status: 503 }); }
}

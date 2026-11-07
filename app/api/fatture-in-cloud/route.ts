import { getOperatoreAttivo } from '../../operatore';
import { clientFic, messaggioErroreFic } from '../../lib/fattureInCloudServer';
import { ErroreFic, validaRicercaFic } from '../../lib/fattureInCloud';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';
export const maxDuration = 60;
const headers = { 'Cache-Control': 'private, no-store', 'X-Content-Type-Options': 'nosniff' };

export async function GET(request: Request) {
  if (!await getOperatoreAttivo()) return Response.json({ errore: 'Accesso operatore richiesto.' }, { status: 401, headers });
  try {
    const q = new URL(request.url).searchParams;
    if (q.get('azione') === 'verifica') return Response.json({ azienda: await clientFic().verifica() }, { headers });
    const filtro = validaRicercaFic(Object.fromEntries(q));
    return Response.json(await clientFic().cerca(filtro), { headers });
  } catch (e) {
    const status = e instanceof ErroreFic && e.codice === 'parametri' ? 400 : 503;
    return Response.json({ errore: messaggioErroreFic(e) }, { status, headers });
  }
}

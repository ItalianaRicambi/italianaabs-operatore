import { rpcEmail, processaEmailLogistica } from '../../../lib/emailLogisticaServer';

export const runtime = 'nodejs';
export const maxDuration = 60;

export async function POST(request: Request) {
  const auth = request.headers.get('authorization') || '';
  if (!/^Bearer [a-zA-Z0-9-]{64,100}$/.test(auth)) return Response.json({ errore: 'Non autorizzato' }, { status: 401 });
  try {
    if (!await rpcEmail<boolean>('autorizza_worker_email_logistica', { p_token: auth.slice(7) })) return Response.json({ errore: 'Non autorizzato' }, { status: 401 });
    return Response.json(await processaEmailLogistica());
  } catch { return Response.json({ errore: 'Servizio email temporaneamente non disponibile.' }, { status: 503 }); }
}

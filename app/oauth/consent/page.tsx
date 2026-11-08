import { configMcpFic } from '../../lib/ficMcpAuth';
import { authorizationIdValido } from '../../lib/ficOAuthConsent';
import Consent from './Consent';
export const dynamic='force-dynamic';
export default async function PaginaConsenso({searchParams}:{searchParams:Promise<Record<string,string|string[]|undefined>>}) {
  const c=configMcpFic(), q=await searchParams;
  const url=process.env.SUPABASE_URL, key=process.env.FIC_AUTH_PUBLISHABLE_KEY;
  const redirects=(process.env.FIC_MCP_REDIRECT_URIS||'').split(',').map(x=>x.trim()).filter(Boolean);
  if(!c||!url||!key||!key.startsWith('sb_publishable_')||!redirects.length) return <main className="mx-auto max-w-lg p-10"><h1 className="text-2xl font-bold">Collegamento ChatGPT</h1><p className="mt-4">L’accesso privato è in configurazione. Nessun documento è accessibile da questa pagina.</p></main>;
  if(!authorizationIdValido(q.authorization_id)) return <main className="p-10">Avvia il collegamento dall’app privata in ChatGPT.</main>;
  return <Consent url={url} publishableKey={key} clientId={c.clientId} authorizationId={q.authorization_id} redirects={redirects}/>;
}

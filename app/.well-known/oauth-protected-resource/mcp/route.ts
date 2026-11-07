import { discoveryMcpFic, metadataMcpFic } from '../../../lib/ficMcpAuth';
export const dynamic='force-dynamic';
export function GET() {
  const c=discoveryMcpFic();
  return Response.json(c?metadataMcpFic(c):{errore:'OAuth non configurato.'}, {status:c?200:503,headers:{'Cache-Control':'no-store'}});
}

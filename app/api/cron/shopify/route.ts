import { timingSafeEqual } from 'node:crypto';
import { sincronizzaShopify } from '../../../lib/shopifySyncServer';
export const runtime='nodejs';
export const dynamic='force-dynamic';
export const maxDuration=240;
export async function GET(request:Request) {
 const secret=process.env.CRON_SECRET, auth=request.headers.get('authorization');
 if(!secret || secret.length<32 || !auth) return new Response('Unauthorized',{status:401});
 const expected=Buffer.from('Bearer '+secret), actual=Buffer.from(auth);
 if(actual.length!==expected.length || !timingSafeEqual(actual,expected)) return new Response('Unauthorized',{status:401});
 try { const r=await sincronizzaShopify(); return Response.json(r,{status:r.ok?200:503,headers:{'Cache-Control':'no-store'}}); }
 catch { return Response.json({ok:false,errore:'Registro Shopify non disponibile'},{status:503}); }
}

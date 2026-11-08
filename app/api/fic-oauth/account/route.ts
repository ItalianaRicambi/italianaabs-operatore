import { createClient } from '@supabase/supabase-js';
import { configMcpFic } from '../../../lib/ficMcpAuth';
export const dynamic='force-dynamic';
export async function POST(req:Request) {
  const c=configMcpFic(),url=process.env.SUPABASE_URL,key=process.env.FIC_AUTH_PUBLISHABLE_KEY;
  const h={'Cache-Control':'private, no-store'};
  if(!c||!url||!key) return Response.json({ok:false},{status:503,headers:h});
  const auth=req.headers.get('authorization')||'';
  if(!auth.startsWith('Bearer ')||auth.length>16000) return Response.json({ok:false},{status:401,headers:h});
  try {
    const client=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});
    const {data,error}=await client.auth.getUser(auth.slice(7));
    const ok=!error&&!!data.user?.email_confirmed_at&&c.users.includes(data.user.id);
    return Response.json({ok},{status:ok?200:403,headers:h});
  }catch{return Response.json({ok:false},{status:503,headers:h});}
}

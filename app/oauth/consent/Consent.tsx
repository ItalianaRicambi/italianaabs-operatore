'use client';
import { useState } from 'react';
import { createClient, type OAuthAuthorizationDetails } from '@supabase/supabase-js';
import { scopeConsensoValido } from '../../lib/ficOAuthConsent';
export default function Consent({url,publishableKey,clientId,authorizationId,redirects}:{url:string;publishableKey:string;clientId:string;authorizationId:string;redirects:string[]}) {
  const [client]=useState(()=>createClient(url,publishableKey,{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}}));
  const [details,setDetails]=useState<OAuthAuthorizationDetails|null>(null),[errore,setErrore]=useState(''),[busy,setBusy]=useState(false);
  const ritorna=(uri:string)=>{
    const u=new URL(uri);
    // Callback ufficiali ChatGPT; qualsiasi nuovo client richiede aggiornare la configurazione.
    if(u.protocol!=='https:' || u.username || u.password || !['chatgpt.com','chat.openai.com'].includes(u.hostname)
      || !redirects.includes(u.origin+u.pathname)) throw new Error('Callback non autorizzato');
    window.location.assign(u.href);
  };
  async function login(e:React.FormEvent<HTMLFormElement>) {
    e.preventDefault();setBusy(true);setErrore('');
    const form=e.currentTarget, data=new FormData(form);
    try {
      const result=await client.auth.signInWithPassword({email:String(data.get('email')),password:String(data.get('password'))});
      form.reset();
      if(result.error||!result.data.session) throw new Error();
      const access=await fetch('/api/fic-oauth/account',{method:'POST',headers:{Authorization:`Bearer ${result.data.session.access_token}`}});
      if(!access.ok) {await client.auth.signOut();throw new Error();}
      const {data:auth,error}=await client.auth.oauth.getAuthorizationDetails(authorizationId);
      if(error||!auth) throw new Error();
      if('redirect_url' in auth) {ritorna(auth.redirect_url);return;}
      if(auth.client.id!==clientId || !scopeConsensoValido(auth.scope) || !redirects.includes(auth.redirect_uri)) throw new Error();
      setDetails(auth);
    }catch {setErrore('Accesso non completato. Verifica l’account autorizzato oppure riavvia il collegamento da ChatGPT.');}
    finally{setBusy(false);}
  }
  async function decidi(approva:boolean) {
    setBusy(true);setErrore('');
    try {
      const {data,error}=approva?await client.auth.oauth.approveAuthorization(authorizationId,{skipBrowserRedirect:true}):await client.auth.oauth.denyAuthorization(authorizationId,{skipBrowserRedirect:true});
      if(error||!data) throw new Error(); ritorna(data.redirect_url);
    }catch{setErrore('Autorizzazione non completata. Riavvia il collegamento da ChatGPT.');setBusy(false);}
  }
  return <main className="min-h-screen bg-slate-50 px-5 py-12 text-slate-950"><div className="mx-auto max-w-lg rounded-2xl border bg-white p-8 shadow-sm">
    <p className="text-sm font-bold text-blue-800">Italiana Ricambi</p><h1 className="mt-2 text-2xl font-bold">Collega Fatture in Cloud a ChatGPT</h1>
    <p className="mt-4">ChatGPT potrà cercare e leggere fatture, preventivi, ordini e proforma dell’azienda. Non potrà creare o modificare documenti.</p>
    {!details?<form onSubmit={login} className="mt-6 space-y-4">
      <p className="text-sm text-slate-600">Accedi con l’account abilitato per questa integrazione.</p>
      <label className="block">E-mail<input name="email" type="email" autoComplete="username" required className="mt-1 block w-full rounded border p-2"/></label>
      <label className="block">Password<input name="password" type="password" autoComplete="current-password" required className="mt-1 block w-full rounded border p-2"/></label>
      <button disabled={busy} className="rounded bg-blue-800 px-5 py-2 font-bold text-white disabled:opacity-50">{busy?'Accesso…':'Accedi'}</button>
    </form>:<section className="mt-6"><h2 className="font-bold">Autorizza {details.client.name}</h2>
      <p className="mt-2 text-sm">Account: {details.user.email}. Il collegamento comprende l’identificazione dell’account e la consultazione dei documenti aziendali.</p>
      <div className="mt-5 flex gap-3"><button disabled={busy} onClick={()=>decidi(true)} className="rounded bg-blue-800 px-5 py-2 font-bold text-white">Autorizza lettura</button>
      <button disabled={busy} onClick={()=>decidi(false)} className="rounded border px-5 py-2">Nega</button></div></section>}
    {errore&&<p role="alert" className="mt-4 text-red-800">{errore}</p>}
  </div></main>;
}

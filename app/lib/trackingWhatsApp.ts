export type PraticaTracking = {
  targa: string | null; telefono: string | null; ordine_id: string | null;
  numero_ordine: string | null; mbe: {master:string; corriere:string; corriere_stato:string; colli:string[]}[];
};
type Tracking = { number: string | null; url: string | null };
export type OrdineTracking = {
  id: string; name: string; test: boolean; cancelledAt: string | null;
  shippingAddress: {phone: string | null} | null;
  fulfillments: {status: string; trackingInfo: Tracking[]}[];
};

const chiarisci = 'Mi indica la targa del veicolo oppure il numero d’ordine? Così posso verificare la spedizione corretta.';
const verifica = 'Per questa spedizione serve una verifica dell’operatore.';
const vettori = new Set(['poste.it','www.poste.it','www.sda.it','www.mbe.it','www.dhl.com','www.dhl.de','www.ups.com','gls-group.com','gls-group.eu','gls-italy.com','www.gls-italy.com','www.brt.it','vas.brt.it','www.fedex.com']);

function telefono(value: string | null | undefined) {
  if (!value || !/^[+0-9 ()/.-]+$/.test(value)) return '';
  let cifre = value.replace(/\D/g,'');
  if (cifre.startsWith('00')) cifre=cifre.slice(2);
  else if (/^3\d{9}$/.test(cifre)) cifre='39'+cifre;
  return /^[1-9]\d{7,14}$/.test(cifre) ? cifre : '';
}

export function selezionaPratica(pratiche: PraticaTracking[], targa: string, numero: string) {
  const righe = pratiche.filter(p => (!targa || p.targa?.toUpperCase()===targa)
    && (!numero || p.numero_ordine===numero));
  return righe.length===1 ? righe[0] : null;
}

function risposta(stato: string, frase: string) {
  return {ok:true, stato_tracking:stato, message:frase, risposta_suggerita:frase};
}

export function trackingIncerto(haRiferimento: boolean) {
  return haRiferimento ? risposta('verifica_operatore',verifica) : risposta('chiedi_riferimento',chiarisci);
}

function linkMbe(codice: string) {
  return /^IT[A-Z0-9]{4}-[A-Z0-9]{2}-[A-Z0-9]{10}$/i.test(codice)
    ? 'https://www.mbe.it/IT/tracking?c='+codice : null;
}

export function risolviTracking(p: PraticaTracking, ordine: OrdineTracking | null, haRiferimento: boolean) {
  const mbe=p.mbe.map(m=>linkMbe(m.master));
  if (mbe.some(link=>!link)) return trackingIncerto(true);
  let link=mbe[0];
  if (p.ordine_id) {
    const tel=telefono(p.telefono);
    if (!ordine || ordine.id!=='gid://shopify/Order/'+p.ordine_id || ordine.name!==p.numero_ordine ||
        ordine.test!==false || ordine.cancelledAt!==null || !tel || tel!==telefono(ordine.shippingAddress?.phone))
      return trackingIncerto(true);
    if (ordine.fulfillments.length>=100) return trackingIncerto(true);
    const spedizioni=ordine.fulfillments.filter(f=>f.status==='SUCCESS');
    const codici=new Map<string,string>();
    for (const f of spedizioni) {
      if (!f.trackingInfo.length) return trackingIncerto(true);
      for (const t of f.trackingInfo) {
        if (!t.number || !t.url) return trackingIncerto(true);
        let u: URL;
        try { u=new URL(t.url); } catch { return trackingIncerto(true); }
        if (u.protocol!=='https:' || !vettori.has(u.hostname) || u.username || u.password || u.port) return trackingIncerto(true);
        codici.set(t.number,u.href);
      }
    }
    if (codici.size>1) return trackingIncerto(haRiferimento);
    const m=p.mbe[0];
    if (m && codici.size && ![m.master,m.corriere,m.corriere_stato,...m.colli].some(n=>codici.has(n)))
      return trackingIncerto(haRiferimento);
    if (codici.size===1) link=[...codici.values()][0];
  }
  if (mbe.length>1) return trackingIncerto(haRiferimento);
  if (!link) return trackingIncerto(true);
  return risposta('trovato','Può seguire la sua spedizione qui: '+link);
}

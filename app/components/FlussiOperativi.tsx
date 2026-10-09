import { correggiSceltaCliente, gestisciRitiroAssistenza, registraAlternativeOfferta } from "../pratica/[id]/actions";
import { NOMI_ASSISTENZA, NOMI_RITIRO, NOMI_SCELTA, type AlternativaOfferta, type AssistenzaRientro, type OffertaVersione, type SceltaCliente } from "../lib/flussiOperativi";

const data = (value: string) => new Date(value).toLocaleString("it-IT", { timeZone: "Europe/Rome" });
const euro = (value: number) => new Intl.NumberFormat("it-IT", { style: "currency", currency: "EUR" }).format(value);
const input = "w-full rounded-lg border border-slate-300 bg-white p-2 text-sm";
const button = "rounded-lg bg-slate-900 px-3 py-2 text-sm font-bold text-white";

export function OfferteEScelta({ praticaId, scelta, offerte, opzioni, preventivi, solaLettura }: {
 praticaId: string; scelta: SceltaCliente | null; offerte: OffertaVersione[]; opzioni: AlternativaOfferta[];
 preventivi: { id: string; file_url: string | null; inviato_at: string | null }[]; solaLettura: boolean;
}) {
 const ultima = offerte[0];
 return <section className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
  <h2 className="text-lg font-bold text-slate-950">Offerta e scelta del cliente</h2>
  {scelta ? <div className={`mt-3 rounded-xl p-3 ${scelta.stato === "confermata" ? "bg-green-100 text-green-950" : "bg-amber-100 text-amber-950"}`}>
   <p className="font-bold">{NOMI_SCELTA[scelta.stato] || scelta.stato}{scelta.servizio ? ` · ${scelta.servizio}` : ""}{scelta.importo != null ? ` · ${euro(scelta.importo)}` : ""}</p>
   <blockquote className="mt-2 text-sm">“{scelta.evidenza}”</blockquote>
   <p className="mt-2 text-xs">{data(scelta.richiesta_at)} · {scelta.fonte === "operatore" ? `Operatore ${scelta.operatore || ""}` : "Messaggio cliente tramite K"} · {scelta.versione ? `versione ${scelta.versione}` : "offerta da collegare"}</p>
   {scelta.protetta_operatore && <p className="mt-1 text-xs font-bold">Correzione operatore protetta</p>}
   {scelta.offerta_successiva && <p className="mt-2 font-bold">È presente un’offerta successiva: verificare la versione concordata.</p>}
   {scelta.prezzo_da_verificare && <p className="mt-2 font-bold">Il cliente segnala un pagamento diverso dal prezzo del preventivo. Verificare il prezzo concordato prima di usare questo importo.</p>}
  </div> : <p className="mt-3 text-sm text-slate-600">Nessuna preferenza o scelta registrata.</p>}
  {ultima ? <div className="mt-4">
   <p className="text-sm font-semibold">Ultima offerta · versione {ultima.versione} · {data(ultima.inviato_at)} {ultima.file_url && <a className="text-blue-700 underline" href={ultima.file_url} target="_blank" rel="noreferrer">Apri PDF</a>}</p>
   {ultima.stato === "da_verificare" && <p className="mt-2 rounded-lg bg-amber-50 p-3 text-sm text-amber-950">Offerta da verificare: {ultima.errore}</p>}
   <div className="mt-2 space-y-2">{opzioni.filter(o => o.offerta_id === ultima.id).map(o => <details key={o.id} className="rounded-lg border border-slate-200 p-3">
    <summary className="cursor-pointer text-sm font-bold">{o.numero_esplicito ? `Opzione ${o.numero} · ` : ""}{o.servizio} · {euro(o.importo)}{o.iva_inclusa === true ? " IVA inclusa" : o.iva_inclusa === false ? " + IVA" : " · IVA da verificare"}</summary>
    <p className="mt-2 whitespace-pre-wrap text-xs text-slate-600">{o.condizioni || o.descrizione}</p>
   </details>)}</div>
  </div> : <p className="mt-4 text-sm text-slate-600">Alternative del preventivo ancora da registrare.</p>}
  {!solaLettura && preventivi.length > 0 && <>
   <details className="mt-4"><summary className="cursor-pointer text-sm font-bold text-blue-800">Leggi un PDF o registra le alternative</summary>
    <form action={registraAlternativeOfferta} className="mt-3 space-y-3">
     <input type="hidden" name="pratica_id" value={praticaId} />
     <label className="block text-sm">Preventivo<select className={input} name="preventivo_id" required>{preventivi.map(p => <option key={p.id} value={p.id}>{p.inviato_at ? data(p.inviato_at) : "Preventivo"} · {p.id.slice(0, 8)}</option>)}</select></label>
     <label className="block text-sm">PDF originale, massimo 3 MB<input className={input} type="file" name="pdf" accept="application/pdf" /></label>
     <p className="text-xs text-slate-500">Per l’inserimento manuale, riporta numero e prezzo delle alternative del documento.</p>
     {Array.from({ length: 4 }, (_, i) => <div key={i} className="grid grid-cols-3 gap-2">
      <select className={input} name={`servizio_${i + 1}`} aria-label={`Servizio opzione ${i + 1}`}><option value="">Opzione {i + 1}</option>{["RI", "RE", "PS", "PSMI"].map(s => <option key={s}>{s}</option>)}</select>
      <input className={input} name={`importo_${i + 1}`} placeholder="Importo €" inputMode="decimal" aria-label={`Prezzo opzione ${i + 1}`} />
      <select className={input} name={`iva_${i + 1}`} aria-label={`IVA opzione ${i + 1}`}><option value="">IVA da verificare</option><option value="inclusa">IVA inclusa</option><option value="esclusa">IVA esclusa</option></select>
     </div>)}
     <textarea className={input} name="nota" placeholder="Condizioni o annotazioni del preventivo" />
     <button className={button}>Registra alternative</button>
    </form>
   </details>
   <details className="mt-4"><summary className="cursor-pointer text-sm font-bold text-blue-800">Correggi la scelta del cliente</summary>
    <form action={correggiSceltaCliente} className="mt-3 space-y-3">
     <input type="hidden" name="pratica_id" value={praticaId} />
     <select className={input} name="opzione_id" defaultValue={scelta?.opzione_id || ""}><option value="">Soluzione da chiarire</option>{opzioni.map(o => <option key={o.id} value={o.id}>{o.servizio} · {euro(o.importo)} · versione {offerte.find(q => q.id === o.offerta_id)?.versione} · opzione {o.numero}</option>)}</select>
     <select className={input} name="stato" defaultValue={scelta?.stato === "modifica_da_verificare" ? "da_chiarire" : scelta?.stato || "preferenza"}>{Object.entries(NOMI_SCELTA).filter(([k]) => k !== "modifica_da_verificare").map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
     <textarea className={input} name="nota" placeholder="Frase del cliente o motivo della correzione" required />
     <p className="text-xs text-slate-500">La correzione viene tracciata e protetta. Lo stato dell’ordine si gestisce nella sezione commerciale.</p>
     <button className={button}>Salva scelta verificata</button>
    </form>
   </details>
  </>}
 </section>;
}

export function GestioneRitiro({ praticaId, attivita, solaLettura }: { praticaId: string; solaLettura: boolean; attivita: {
 id: string; tipo: string; stato: string; operatore?: string | null; presa_in_carico_at?: string | null;
 riferimento_ritiro?: string | null; data_ritiro_prevista?: string | null;
 metadati?: { ritiro_gia_effettuato_segnalato?: boolean; evidenza_ritiro_effettuato?: string };
} }) {
 return <div className="mt-3">
  {attivita.operatore && <p className="text-sm font-bold">In carico a {attivita.operatore}</p>}
  {attivita.riferimento_ritiro && <p className="mt-1 text-sm">Prenotazione: {attivita.riferimento_ritiro} · {attivita.data_ritiro_prevista}</p>}
  {attivita.metadati?.ritiro_gia_effettuato_segnalato && <p className="mt-2 rounded-lg bg-amber-100 p-3 text-sm font-bold text-amber-950">Il cliente segnala un ritiro già prenotato o effettuato. Verificare prenotazione, tracking e ricezione prima di prenotare nuovamente. “{attivita.metadati.evidenza_ritiro_effettuato}”</p>}
  {!solaLettura && <form action={gestisciRitiroAssistenza} className="mt-3 space-y-2">
   <input type="hidden" name="pratica_id" value={praticaId} /><input type="hidden" name="attivita_id" value={attivita.id} />
   <select className={input} name="azione" aria-label="Azione sul ritiro"><option value="prendi_in_carico">Prendi in carico</option><option value="classifica">Classifica / correggi il ritiro</option><option value="programma">Registra prenotazione corriere</option><option value="verifica_prenotazione">Registra verifica prima di nuova prenotazione</option><option value="completa">Segna ritiro effettuato</option><option value="annulla">Annulla ritiro</option></select>
   <select className={input} name="tipo" defaultValue={attivita.tipo} aria-label="Tipo di ritiro">{Object.entries(NOMI_RITIRO).map(([k, v]) => <option key={k} value={k}>{v}</option>)}</select>
   <input className={input} name="origine_numero" type="number" min="1" placeholder="Numero pratica di origine, se da collegare (es. 1094)" />
   <div className="grid grid-cols-2 gap-2"><input className={input} name="riferimento" placeholder="Riferimento prenotazione GLS" /><input className={input} type="date" name="data_ritiro" aria-label="Data ritiro concordata" /></div>
   <textarea className={input} name="nota" placeholder="Motivazione, istruzioni o prova del ritiro effettuato" />
   <p className="text-xs text-slate-500">La prenotazione richiede riferimento e data. Segnare il pacco ritirato mantiene aperta l’eventuale assistenza.</p>
   <button className={button}>Registra operazione</button>
  </form>}
 </div>;
}

export function AssistenzeRientro({ praticaId, assistenze, solaLettura }: { praticaId: string; assistenze: AssistenzaRientro[]; solaLettura: boolean }) {
 if (!assistenze.length) return null;
 return <section className="rounded-2xl border border-red-300 bg-white p-5 shadow-sm">
  <h2 className="text-lg font-bold text-red-800">Rientri di assistenza / verifica in garanzia</h2>
  <p className="mt-1 text-xs text-slate-600">La copertura in garanzia viene valutata dal tecnico. Il ritiro e la chiusura dell’assistenza sono due passaggi distinti.</p>
  {assistenze.map(c => <div key={c.id} className="mt-4 rounded-xl border border-red-200 p-4">
   <p className="font-bold">{NOMI_ASSISTENZA[c.stato] || c.stato} · {c.chiusa_at ? "Conclusa" : "URGENTE"}</p>
   <p className="mt-1 text-xs">Aperta: {data(c.aperta_at)} · {c.operatore ? `Operatore ${c.operatore}` : "Da assegnare"}</p>
   <blockquote className="mt-2 text-sm text-slate-700">“{c.evidenza}”</blockquote>
   <p className="mt-2 text-xs">{c.pratica_origine_id ? "Ordine di origine collegato" : "Ordine di origine da collegare"}</p>
   {c.esito_tecnico && <p className="mt-2 whitespace-pre-wrap text-sm">Esito: {c.esito_tecnico}</p>}
   {!solaLettura && !c.chiusa_at && <form action={gestisciRitiroAssistenza} className="mt-3 space-y-2">
    <input type="hidden" name="pratica_id" value={praticaId} /><input type="hidden" name="assistenza_id" value={c.id} />
    <select className={input} name="azione" aria-label="Avanzamento assistenza"><option value="prendi_in_carico">Prendi in carico</option><option value="collega_origine">Collega ordine di origine</option>{["verifica_tecnica", "ritiro_da_prenotare", "ricevuto", "in_lavorazione", "esito_comunicato"].map(s => <option key={s} value={s}>{NOMI_ASSISTENZA[s]}</option>)}<option value="chiudi">Chiudi dopo esito comunicato</option></select>
    <input className={input} name="origine_numero" inputMode="numeric" placeholder="Numero pratica dell’ordine originale, per collegarlo" aria-label="Numero ordine originale" />
    <textarea className={input} name="nota" placeholder="Nota tecnica / esito comunicato al cliente" />
    <button className={button}>Aggiorna assistenza</button>
   </form>}
  </div>)}
 </section>;
}

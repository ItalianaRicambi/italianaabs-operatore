import type {Phase} from './policy.ts';

/** Testi Utility IT riletti nella console Keplero l'11/11/2026.
 * Nessuna generazione libera: la riconciliazione deve cercare il testo realmente
 * renderizzato dal template approvato, non un testo fornito dal revisore.
 */
export const approvedBodies:Record<Phase,string>={
 preventivo:'Buongiorno, la contattiamo da ItalianaABS per la richiesta di preventivo relativa alla pratica {{1}}. Per completare la valutazione ci mancano ancora: {{2}}. Può inviarci queste informazioni rispondendo qui? Se ha già risolto o non desidera proseguire, ce lo comunichi e chiuderemo la richiesta. Grazie.',
 fatturazione:'Buongiorno, la contattiamo da ItalianaABS per la pratica {{1}}, relativa al preventivo da lei accettato. Per predisporre la fattura mancano ancora: {{2}}. Può inviarci soltanto questi dati rispondendo qui? Se non desidera più proseguire, ce lo comunichi per aggiornare la pratica. Grazie.',
};
export function renderApprovedTemplate(phase:Phase,variables:[string,string]):string{
 if(!Object.hasOwn(approvedBodies,phase)||variables.length!==2||variables.some(v=>typeof v!=='string'||!v.trim())){
  throw new Error('followup_template_invalid');
 }
 // Callback: eventuali $& e $1 sono testo letterale, mai istruzioni di replace.
 return approvedBodies[phase].replace(/\{\{([12])\}\}/g,(_all,index)=>variables[Number(index)-1].replace(/\s+/g,' ').trim());
}

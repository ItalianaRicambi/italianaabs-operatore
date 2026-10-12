export type DatiFiscaliBozza = Record<string, string>;
export function datiFiscaliDaChat(messaggi: { id: number; testo: string | null }[]) {
  const valori = new Map<string, Map<string, string>>();
  const fonti: { id: number; testo: string }[] = [];
  function aggiungi(campo: string, valore?: string | null) {
    const v = valore?.trim(); if (!v) return;
    const m = valori.get(campo) || new Map<string, string>();
    m.set(v.toUpperCase().replace(/\s+/g, ' '), v); valori.set(campo, m);
  }
  for (const messaggio of messaggi) {
    const testo = (messaggio.testo || '').replace(/\\+n/g, '\n').replace(/\r/g, '');
    const cf = /\b[A-Z]{6}\d{2}[A-Z]\d{2}[A-Z]\d{3}[A-Z]\b/i.exec(testo)?.[0];
    const iva = /(?:P\.?\s*IVA|partita\s+iva)\s*[:;]?\s*(\d{11})\b/i.exec(testo)?.[1];
    if (!cf && !iva && !/indirizzo di fatturazione|\b(?:email|e-mail|PEC)\s*:/i.test(testo)) continue;
    fonti.push({ id: messaggio.id, testo });
    aggiungi('codice_fiscale', cf?.toUpperCase()); aggiungi('partita_iva', iva);
    const email = /(?:e-?mail|indirizzo email)\s*[:;]?\s*([A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,})/i.exec(testo)?.[1];
    aggiungi('email', email?.toLowerCase());
    aggiungi('pec', /\bPEC\s*[:;]?\s*([A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,})/i.exec(testo)?.[1]?.toLowerCase());
    aggiungi('denominazione', /(?:cognome|denominazione|ragione sociale)\s*[:;]\s*([^\n,]+)/i.exec(testo)?.[1]);
    aggiungi('denominazione', /Immagine anagrafica:\s*(.+?)\s*,?\s*(?:P\.?\s*IVA|CF)\b/i.exec(testo)?.[1]?.replace(/,\s*$/, ''));
    if (cf && testo.trim().toUpperCase().startsWith(cf.toUpperCase())) {
      aggiungi('denominazione', testo.slice(testo.toUpperCase().indexOf(cf.toUpperCase()) + cf.length).split(/\b(?:via|viale|piazza|lgo|largo|corso)\b/i)[0]);
    }
    for (const riga of testo.split('\n')) {
      if (/indirizzo (?:di )?(?:spedizione|ritiro|consegna)/i.test(riga)) continue;
      if (!cf && !iva && !/indirizzo di fatturazione/i.test(riga)) continue;
      const indirizzo = /\b((?:via|viale|piazza|lgo|largo|corso)\s+.*)/i.exec(riga)?.[1];
      if (!indirizzo) continue;
      const civico = /^(.+?\d+[A-Za-z]?)(?:[,\s]+)(.+)$/.exec(indirizzo);
      if (!civico) continue;
      const localita = /^(.*?)\b(\d{5})\b\s*(.*?)\s*\.?$/.exec(civico[2]);
      if (!localita) continue;
      const comuneTesto = (localita[3] || localita[1]).trim();
      const provincia = /\(([A-Z]{2})\)/i.exec(comuneTesto)?.[1]?.toUpperCase();
      const comune = comuneTesto.replace(/\([A-Z]{2}\)/gi, '').trim();
      if (!comune || /[,;:]|\d/.test(comune)) continue;
      aggiungi('indirizzo_fatturazione', civico[1] + (localita[3] && localita[1].trim() ? ', ' + localita[1].trim() : ''));
      aggiungi('cap', localita[2]); aggiungi('comune', comune); aggiungi('provincia', provincia);
    }
  }
  const dati: DatiFiscaliBozza = {}, conflitti: string[] = [];
  for (const [campo, candidati] of valori) {
    if (candidati.size === 1) dati[campo] = [...candidati.values()][0];
    else conflitti.push(campo);
  }
  return { dati, fonti, conflitti };
}

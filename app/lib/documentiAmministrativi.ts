import { createHash } from 'node:crypto';

export type ClienteDocumento = {
  denominazione: string; indirizzo_fatturazione: string; cap: string; comune: string;
  provincia: string | null; paese: string; partita_iva: string | null; codice_fiscale: string | null;
};
export type DocumentoAmministrativo = {
  tipo: 'fattura' | 'proforma'; numero: string; data: string; targa: string; importo: number;
  cliente: ClienteDocumento; impronta: string; testo_documento: string;
};
const normalizzaTarga = (s: string) => s.toUpperCase().replace(/[^A-Z0-9]/g, '');
function unico(valori: string[], nome: string) {
  const unici = [...new Set(valori)];
  if (unici.length !== 1) throw new Error(`${nome} assente o non univoco nel documento.`);
  return unici[0];
}

export function leggiDocumentoAmministrativo(raw: string, targaAttesa: string): DocumentoAmministrativo {
  const testo = raw.replace(/\r/g, '').replace(/\u00a0/g, ' ').trim();
  if (testo.length < 100 || testo.length > 200000) throw new Error('Documento non leggibile o troppo lungo.');
  const intestazioni = [...testo.matchAll(/^(Fattura|Pro\s+Forma)\s+nr\.\s*([^\n]+)/gim)];
  const tipo = unico(intestazioni.map(m => /^fattura$/i.test(m[1]) ? 'fattura' : 'proforma'), 'Tipo documento') as DocumentoAmministrativo['tipo'];
  const numero = unico(intestazioni.map(m => m[2].trim()), 'Numero documento');
  if (numero.length > 80) throw new Error('Numero documento troppo lungo.');
  const dataTesto = unico([...testo.matchAll(/^Data:\s*(\d{2}\/\d{2}\/\d{4})\s*$/gm)].map(m => m[1]), 'Data');
  const [giorno, mese, anno] = dataTesto.split('/');
  const data = `${anno}-${mese}-${giorno}`;
  if (new Date(`${data}T00:00:00Z`).toISOString().slice(0, 10) !== data) throw new Error('Data del documento non valida.');
  const targa = unico([...testo.matchAll(/\bTarga\s*:\s*([A-Z0-9]+)/gi)].map(m => normalizzaTarga(m[1])), 'Targa');
  if (!normalizzaTarga(targaAttesa) || targa !== normalizzaTarga(targaAttesa)) throw new Error('La targa del documento non coincide con la pratica.');
  // Il blocco del destinatario termina prima dei dati fiscali di Italiana Ricambi.
  const blocchi = [...testo.matchAll(/Spettabile\s*\n([\s\S]+?)\nItaliana Ricambi di Scotti Norberto/gi)].map(m => m[1].trim());
  const blocco = unico(blocchi, 'Destinatario');
  if (!/P\.IVA:\s*02439670031\b/.test(testo)) throw new Error('Il documento non identifica Italiana Ricambi come emittente.');
  const righe = blocco.split('\n').map(s => s.trim()).filter(Boolean);
  const iva = /^P\.IVA:\s*(.+)$/im.exec(blocco)?.[1].trim() || null;
  const cf = /^CF:\s*(.+)$/im.exec(blocco)?.[1].trim() || null;
  const inizioFiscali = righe.findIndex(s => /^(P\.IVA|CF):/.test(s));
  const indiceComune = righe.findIndex(s => /^\d{4,5}\s+/.test(s));
  const ubicazione = indiceComune >= 0 ? /^(\d{4,5})\s+(.+?)(?:\s*\(([^)]+)\))?$/.exec(righe[indiceComune]) : null;
  const paese = ({ ITALIA: 'IT', SVIZZERA: 'CH' } as Record<string, string>)[righe[indiceComune + 1]?.toUpperCase()];
  if (inizioFiscali < 1 || !ubicazione || !paese || (!iva && !cf)) throw new Error('Dati del destinatario incompleti o formato non riconosciuto. Verificare manualmente.');
  const indirizzo = righe.slice(inizioFiscali, indiceComune).filter(s => !/^(P\.IVA|CF):/.test(s)).join(', ');
  if (!indirizzo) throw new Error('Indirizzo di fatturazione assente.');
  const totale = unico([...testo.matchAll(/Totale dovuto\s*€\s*([\d.,]+)/gi)].map(m => m[1]), 'Totale');
  const importo = Number(totale.replace(/\./g, '').replace(',', '.'));
  if (!Number.isFinite(importo) || importo <= 0) throw new Error('Importo documento non valido.');
  return { tipo, numero, data, targa, importo, impronta: createHash('sha256').update(testo).digest('hex'), testo_documento: testo,
    cliente: { denominazione: righe.slice(0, inizioFiscali).join(' '), indirizzo_fatturazione: indirizzo,
      cap: ubicazione[1], comune: ubicazione[2].trim(), provincia: ubicazione[3] || null, paese,
      partita_iva: iva, codice_fiscale: cf } };
}

export async function leggiDocumentoAmministrativoPdf(bytes: Uint8Array, targa: string) {
  if (bytes.length > 3 * 1024 * 1024 || Buffer.from(bytes.subarray(0, 5)).toString() !== '%PDF-') throw new Error('Carica un PDF non superiore a 3 MB.');
  const { getDocumentProxy } = await import('unpdf');
  const pdf = await getDocumentProxy(bytes);
  try {
    if (pdf.numPages > 30) throw new Error('Il documento supera 30 pagine.');
    const pagine: string[] = [];
    for (let n = 1; n <= pdf.numPages; n++) {
      const pagina = await pdf.getPage(n);
      const contenuto = await pagina.getTextContent();
      pagine.push(contenuto.items.map(item => 'str' in item ? item.str + (item.hasEOL ? '\n' : ' ') : '').join(''));
      pagina.cleanup();
    }
    return leggiDocumentoAmministrativo(pagine.join('\n'), targa);
  } finally { await pdf.cleanup(); }
}

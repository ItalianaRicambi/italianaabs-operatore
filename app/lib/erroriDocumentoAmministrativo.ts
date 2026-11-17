// Solo messaggi applicativi noti: mai dettagli SQL, payload o credenziali.
const erroriNoti = new Map<string, string>([
  ['Il documento richiede un ordine commerciale attivo', 'La pratica non è un ordine commerciale attivo. Verifica lo stato prima di registrare il documento.'],
  ['Targa documento diversa dalla pratica', 'La targa del documento non coincide con la pratica: nessun dato salvato.'],
  ['Riferimenti documento incompleti o non validi', 'Numero, data, importo o impronta del documento non validi: nessun dato salvato.'],
  ['Anagrafica del documento incompleta', 'Il documento non contiene tutti i dati fiscali necessari: verifica destinatario e indirizzo. Nessun dato salvato.'],
  ['Anagrafica fiscale incompleta o da verificare', 'L’anagrafica fiscale esistente è incompleta o da verificare. Controllala nella sezione Cliente fiscale; nessun dato salvato.'],
  ['Più anagrafiche fiscali compatibili: verifica operatore richiesta', 'Sono presenti più anagrafiche fiscali compatibili. Risolvi il duplicato nella sezione Cliente fiscale; nessun dato salvato.'],
  ['Identificativi fiscali discordanti', 'Codice fiscale o partita IVA non coincidono con l’anagrafica esistente: nessun dato salvato.'],
  ['Il destinatario fiscale non coincide con il cliente già collegato', 'Il destinatario del documento è diverso dal cliente fiscale collegato. Verifica l’abbinamento: nessun dato salvato.'],
  ['Documento già registrato con un collegamento o importo diverso', 'Questo documento risulta già registrato con una pratica o un importo diverso. Verifica la registrazione esistente; nessun dato salvato.'],
  ['Per il documento storico collegare prima il cliente fiscale', 'La pratica risulta già fatturata: collega prima il cliente fiscale corretto. Nessun dato salvato.'],
  ['Ordine non disponibile per la registrazione del documento', 'Lo stato amministrativo dell’ordine impedisce la registrazione. Richiedi una verifica tecnica; nessun dato salvato.'],
  ['La nuova anagrafica può essere creata solo per un ordine da fatturare', 'Ordine acquisito, ma fatturazione non allineata. Richiedi una verifica tecnica; nessun dato salvato.'],
  ['Il cliente fiscale può essere collegato solo a un ordine da fatturare', 'Ordine acquisito, ma fatturazione non allineata. Richiedi una verifica tecnica; nessun dato salvato.'],
  ['Fattura non allineata: nessuna modifica applicata', 'La fattura non ha superato l’allineamento della pratica: nessun dato salvato. Richiedi una verifica tecnica.'],
]);

export function messaggioErroreDocumento(errore: unknown): string {
  const testo = errore instanceof Error ? errore.message : '';
  // chiamaRpc incapsula la risposta PostgREST in questo prefisso.
  const risposta = /^Operazione non riuscita \(\d{3}\): (\{[\s\S]*\})$/.exec(testo);
  if (risposta) {
    try {
      const dettagli = JSON.parse(risposta[1]);
      if (dettagli?.code === 'P0001' && typeof dettagli.message === 'string') {
        const noto = erroriNoti.get(dettagli.message);
        if (noto) return noto;
      }
    } catch { /* Risposta non valida: non esporre il corpo. */ }
  }
  // Timeout/revalidazione fallita: non sappiamo se il commit sia avvenuto.
  return 'Salvataggio non confermato. Ricarica la pratica e controlla i documenti registrati prima di riprovare. Se manca, riprova con lo stesso PDF: la verifica impedisce duplicati.';
}

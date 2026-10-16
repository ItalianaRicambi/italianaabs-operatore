# Acquisizione del PDF e prova di invio

Il collegamento Apps Script esistente continua a POSTare a `/api/preventivi/emesso`, con lo stesso segreto, documento e cartelle. Il backend registra ora il PDF in `documenti_preventivo_auto`, separatamente dal registro degli invii. HTTP 200 con `acquisito=true` attesta la conservazione del documento, anche quando la pratica è da abbinare: non attesta l'invio al cliente. Una copia `TARGA (1).pdf` conserva la targa originale.

Ogni contenuto conserva l'identificativo Drive e un'impronta; un retry identico non crea documenti o versioni duplicate. Un contenuto diverso dello stesso file resta una versione distinta. L'abbinamento usa targa esatta e cronologia della pratica; più episodi compatibili restano da abbinare. I blocchi dell'operatore non impediscono di vedere un documento collegato, ma continuano a proteggere lo stato e la classificazione. Non vengono inventati completezza, prezzi o consensi.

Le proposte lette appaiono nella pratica e nel registro riservato `/preventivi`, raggiungibile dalla Dashboard. Nessuna scrittura avviene durante l'apertura della pagina. I documenti non inviati non alimentano il riconoscimento delle scelte del cliente: soltanto una prova d'invio crea il preventivo inviato e la sua versione commerciale. I documenti con più alternative o lettura incoerente restano espliciti da verificare.

`conferma_invio_documento_preventivo` è accessibile esclusivamente al servizio. Il contratto interno richiede: messaggio originale in uscita effettivamente inviato, identificativo messaggio e conversazione, data originale, corrispondenza dell'impronta del contenuto del PDF. La conversazione deve coincidere con quella collegata alla pratica. L'identificativo della prova è univoco, la data non può precedere il documento o essere futura e una prova cliente in entrata viene rifiutata. Ordini e fasi successive non vengono retrocessi. Ogni versione Drive usa un'identità commerciale composta, distinta dalle vecchie importazioni per solo ID file.

È mantenuta la conferma manuale «Preventivo inviato»: lo storico dell'azione di un operatore autorizzato è la prova. Con un solo documento recente già collegato, il trigger registra anche le proposte, senza ricaricare il PDF. Più documenti candidati non vengono scelti arbitrariamente. Un invio verificato ma fermato dai blocchi commerciali conserva la prova e viene ritentato; non supera i blocchi.

I documenti pendenti del vecchio registro, con contenuto disponibile, vengono trasferiti alla nuova verifica senza cambiare lo stato delle pratiche. La vecchia riprova non li tratta più come automaticamente inviati. Gli invii storici già registrati rimangono invariati. La nuova riprova dell'abbinamento viene eseguita ogni cinque minuti nel database.

## Limite verificato il 16 ottobre 2026

La console Keplero WhatsApp espone «Messaggio ricevuto», ma non un evento «Messaggio inviato». La chiave API inserita il 15 ottobre risultava rifiutata (401); non è pervenuta una nuova risposta dell'assistenza alla richiesta di sostituzione. Non è attivo un processo che certifichi gli invii originali dalla chat. La funzione interna non viene esposta come webhook che accetta autodichiarazioni di invio, né viene chiamata sulla base del testo prodotto dall'assistente.

Prima di abilitare il recupero automatico servono la chiave funzionante e verifica del formato reale (autore/direzione, esito invio, timestamp, ID, destinatario e allegato). Poi il server deve recuperare e confrontare il PDF effettivo, non soltanto il nome. Il test deve includere due vetture nella stessa chat, PDF cliente in entrata, file omonimi con contenuti diversi, invio fallito, retry e messaggi arrivati durante la paginazione. Fino a tale collaudo la conferma manuale resta necessaria per lo stato «inviato», ma non per acquisire e leggere il PDF.

## Verifica

`supabase/tests/preventivi_documenti_e_prove_invio.sql` usa fixture annullate: preparazione senza invio, duplicati, direzione in entrata, conversazione errata, blocchi operatore, prova valida, prezzi, retry, ordine avanzato, ambiguità e conferma manuale. I test TypeScript verificano copie Drive, identità e risposte di acquisizione durabile.

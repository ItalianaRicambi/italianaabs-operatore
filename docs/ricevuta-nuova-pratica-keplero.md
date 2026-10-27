# Ricevuta delle nuove pratiche Keplero

L'attivazione di una nuova vettura sostituisce il collegamento temporaneo
con quello della conversazione. Il webhook proseguiva utilizzando la chiave
temporanea già eliminata: la ricevuta finale restituiva un errore benché
l'ingresso fosse già salvato. Anche i contesti e la verifica della conferma
richiedono quel collegamento e, per la prova, la chiave dell'evento originale.

La route ora completa conferma, contesti e ricevuta prima dell'attivazione.
Verifica poi che l'attivazione riguardi la pratica e la chiave attese e
restituisce la chiave attiva della conversazione. Un errore in uno dei due
passaggi non produce una risposta di successo. Nessun evento viene riscritto
e nessuno stato commerciale viene dedotto dal solo riconoscimento testuale.

Il test di integrazione invoca la route completa con un servizio simulato che
elimina davvero il collegamento temporaneo all'attivazione. Copre nuova
pratica, conferma senza offerta verificata, pratica esistente, ricevuta fallita,
attivazione fallita e risposta di attivazione discordante. Usa solo dati fittizi
e non accede a servizi esterni.

Esecuzione: `bash scripts/test-keplero-live-route.sh`.
Regressioni del riconoscimento: `node --test app/api/keplero/live/*.test.ts`.

Questa modifica risolve il collegamento invalido dopo l'attivazione. Non
certifica risolti i timeout dovuti a contesa sulle pratiche, né decide quale
pratica archiviare quando esistono duplicati corretti manualmente.

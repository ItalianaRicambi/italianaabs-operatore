# Riduzione del tempo trascorso con le pratiche bloccate

Il primo ciclo misurato dopo PR #41 durava 16,764 secondi: 8,896 nel controllo di
coerenza e 7,283 nel recupero dei flussi. Il recupero prende row lock sulle pratiche;
la transazione li conserva anche durante il controllo di coerenza successivo.

EXPLAIN ANALYZE ha rilevato scansioni dei medesimi eventi ripetute 396 volte nei
join dei controlli su dati fiscali e pagamento. I predicati sul testo vengono ora
materializzati una volta per evento. Su uno stesso snapshot reale la query di
lettura è passata da 6,809 a 0,980 secondi: 126 righe prima e dopo, zero differenze
con EXCEPT ALL bidirezionale. Non sono cambiati regex, finestra temporale, filtri
su pratiche fatturate/archiviate o fonti supplementari.

Il controllore calcola una sola volta l'insieme di candidati per aggiornare e
risolvere le segnalazioni. Le due scritture operano su chiavi disgiunte, in una sola
istruzione SQL. Una segnalazione assente dal nuovo insieme viene risolta; una
presente viene inserita, aggiornata o riaperta come prima.

La ricerca della pratica d'origine normalizza la targa eliminando separatori e
uniformando maiuscole. L'indice esistente sulla targa grezza non copre questa
espressione: il piano letto in produzione scansionava tutte le 1.802 pratiche.
Un indice sull'espressione esatta evita queste scansioni ripetute nel recupero dei
rientri. Non cambia il riconoscimento del veicolo né amplia gli abbinamenti.

## Collaudo

Il workflow Query manutenzione Keplero esegue PostgreSQL 17 isolato. Confronta la
query originale conservata come fixture con quella reale della migrazione usando
EXCEPT ALL su eventi con fiscali, pagamento, negazione, revoca, nulli, pratiche
archiviate/fatturate e finestre scadute. Gli helper non modificati sono stub
condivisi, quindi questo test riguarda l'equivalenza della riscrittura, non la
correttezza delle regole di classificazione. Il confronto aggiuntivo sui dati reali
copre gli helper effettivamente installati, senza scrivere dati cliente.

Verifica inoltre l'uso del nuovo indice e il controllore reale con candidati
strumentati: una sola valutazione per ciclo, aggiornamento, riapertura, risoluzione,
insieme vuoto ed errore. Rimangono attivi i test di concorrenza già introdotti.

## Limiti e ripristino

La misura riguarda il lavoro automatico che trattiene i lock. Non identifica a
posteriori il blocker del singolo timeout operatore del 27 ottobre alle 15:30 UTC.
Verificare dopo il rilascio le durate delle fasi, gli esiti e i log: un singolo
ciclo senza errori non garantisce l'assenza di ogni possibile timeout futuro.

Per ripristinare: usare la definizione originale dei candidati dalla fixture e
quella del controllore precedente; l'indice può restare perché non cambia risultati
né permessi. Non vengono modificati ruoli, RLS, pianificazione o invii ai clienti.

-- Evita una scansione di tutti i messaggi per ogni ricerca della prova PDF.
-- Le regole di associazione (impronta, targa, uscita e originale non modificato)
-- e la frequenza delle routine rimangono invariate.
set local lock_timeout = '2s';
set local statement_timeout = '20s';
create index if not exists keplero_originali_pdf_inviati
 on public.keplero_originali (sha256_pdf, targa_pdf, data_messaggio)
 where direzione = 'uscita' and not modificato and sha256_pdf is not null;

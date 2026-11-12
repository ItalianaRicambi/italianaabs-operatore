-- Sola lettura, eseguibile anche sul progetto: nessun clock sostituito, nessun
-- record di prova, nessun invio. Copertura confermata fino al 31/12/2026.
with casi(istante,atteso) as (values
 (null::timestamptz,false),
 ('2026-12-04T12:29:59Z'::timestamptz,true),
 ('2026-12-04T12:30:00Z'::timestamptz,false),
 ('2026-12-05T10:00:00Z'::timestamptz,false),
 ('2026-12-06T10:00:00Z'::timestamptz,false),
 ('2026-12-07T10:00:00Z'::timestamptz,false),
 ('2026-12-08T10:00:00Z'::timestamptz,false),
 ('2026-12-09T07:59:59Z'::timestamptz,false),
 ('2026-12-09T08:00:00Z'::timestamptz,true),
 ('2026-12-09T11:29:59Z'::timestamptz,true),
 ('2026-12-09T11:30:00Z'::timestamptz,false),
 ('2026-12-09T13:00:00Z'::timestamptz,true),
 ('2026-12-09T17:29:59Z'::timestamptz,true),
 ('2026-12-09T17:30:00Z'::timestamptz,false),
 ('2026-12-23T13:00:00Z'::timestamptz,true),
 ('2026-12-24T10:00:00Z'::timestamptz,false),
 ('2026-12-25T10:00:00Z'::timestamptz,false),
 ('2026-12-26T10:00:00Z'::timestamptz,false),
 ('2026-12-27T10:00:00Z'::timestamptz,false),
 ('2026-12-28T08:00:00Z'::timestamptz,true),
 ('2026-12-30T17:29:59Z'::timestamptz,true),
 ('2026-12-31T10:00:00Z'::timestamptz,false),
 ('2027-01-04T10:00:00Z'::timestamptz,false),
 ('2026-07-13T07:00:00Z'::timestamptz,true),
 ('2026-11-09T07:00:00Z'::timestamptz,false)
), risultati as (
 select istante,atteso,private.followup_dati_fascia_aperta(istante) as effettivo from casi
)
select count(*) as casi, bool_and(effettivo is not distinct from atteso) as tutti_superati,
 coalesce(jsonb_agg(to_jsonb(risultati)) filter(where effettivo is distinct from atteso),'[]'::jsonb) as errori
from risultati;

-- Distingue l'arretrato automatico dal lavoro operatore senza risolvere o eliminare schede.
-- Richieste esplicite, anomalie gia valutate e schede assegnate restano operative.
do $preflight$
begin
 if (select encode(sha256(convert_to(btrim(replace(prosrc,E'\r\n',E'\n'),E' \t\r\n'),'UTF8')),'hex') from pg_proc
  where oid='public.stato_esiti_commerciali_k()'::regprocedure)
  is distinct from '62e54f9bf46edfba6ebe25a3a5c3935f45ffa09f8c52799c2b0b40e7b7234d1f' then
  raise exception 'Definizione del controllo cambiata: rivalutare la migrazione';
 end if;
end; $preflight$;
create or replace view public.keplero_lavori_pratiche_elenco with(security_invoker=true) as
with fonti as (
 select case when e.pratica_id is not null then 'pratica:'||e.pratica_id
   else coalesce('chat:'||e.sessione,e.fonte||':'||e.chiave) end chiave,
  count(*) fonti_aperte,
  bool_or(e.stato='ricevuto' and e.fonte<>'richiesta') da_elaborare,
  bool_or((e.stato in ('in_attesa','da_verificare') and e.codice not in ('attesa_cliente','dati_amministrativi'))
    or (e.stato='ricevuto' and e.fonte='richiesta')) da_lavorare
 from public.keplero_esiti_fonti e where e.stato in ('ricevuto','in_attesa','da_verificare')
 group by 1
)
select l.chiave,l.pratica_id,l.sessione,l.stato,l.priorita,l.responsabile,l.presa_in_carico_at,l.scadenza_at,
 l.prima_rilevazione_at,l.ultimo_controllo_at,l.risolta_at,l.versione,p.numero_pratica,p.nome_cliente,p.targa,
 coalesce(s.assistente,'2aef20d3-5ef8-4c81-8f21-bd450f22960c'::uuid) assistente,
 coalesce((l.motivi#>>'{richiesta_preventivo,verifica_tecnica}')::boolean,false) verifica_tecnica_necessaria,
 l.motivi#>>'{richiesta_preventivo,azione}' azione_preventivo,
 l.motivi#>'{richiesta_preventivo,dati_mancanti}' dati_mancanti,
 coalesce(f.fonti_aperte,0::bigint) fonti_aperte,
 (l.responsabile is null and l.stato<>'in_carico' and l.priorita<>0
  and l.motivi-'eventi_senza_esito'-'da_associare'='{}'::jsonb
  and coalesce(f.da_elaborare,false) and not coalesce(f.da_lavorare,false)) attesa_automazione
from public.keplero_lavori_pratiche l left join public.pratiche p on p.id=l.pratica_id
left join public.keplero_sessioni_originali s on s.sessione=l.sessione
left join fonti f on f.chiave=l.chiave;
revoke all on public.keplero_lavori_pratiche_elenco from public,anon,authenticated;
grant select on public.keplero_lavori_pratiche_elenco to service_role;

create or replace function public.stato_esiti_commerciali_k()
returns jsonb language sql stable security invoker set search_path='' as $$
with coda as materialized (select pratica_id,priorita,attesa_automazione from public.keplero_lavori_pratiche_elenco where stato<>'risolta')
select jsonb_build_object('controllo',(select to_jsonb(s) from public.keplero_stato_riconciliazione s where id),
 'controllo_in_ritardo',not exists(select 1 from public.keplero_stato_riconciliazione where id and ultimo_successo_at>=now()-interval '5 minutes'),
 'lavori_aperti',(select count(*) from coda where not attesa_automazione),
 'lavori_in_attesa_automazione',(select count(*) from coda where attesa_automazione),
 'lavori_totali',(select count(*) from public.keplero_lavori_pratiche where stato<>'risolta'),
 'prioritari',(select count(*) from coda where not attesa_automazione and priorita=0),
 'da_associare',(select count(*) from coda where not attesa_automazione and pratica_id is null),
 'ingressi_in_elaborazione',(select count(*) from public.keplero_esiti_fonti where stato='ricevuto'),
 'ingressi_in_ritardo',(select count(*) from public.keplero_esiti_fonti where stato='ricevuto' and created_at<now()-interval '5 minutes'),
 'errori',(select count(*) from public.keplero_esiti_fonti where errore is not null and stato='da_verificare'),
 'originali_in_ritardo',not exists(select 1 from public.keplero_recupero_originali where id and automatico and ultimo_successo_at>=now()-interval '10 minutes' and errore_elenco is null),
 'fonte_originali',public.stato_originali_k());
$$;
revoke all on function public.stato_esiti_commerciali_k() from public,anon,authenticated;
grant execute on function public.stato_esiti_commerciali_k() to service_role;

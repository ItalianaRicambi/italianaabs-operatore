-- Riporta tutte le schede aperte nella coda operativa; nessuna scheda viene cancellata.
create or replace view public.keplero_lavori_pratiche_elenco with(security_invoker=true) as
select l.chiave,l.pratica_id,l.sessione,l.stato,l.priorita,l.responsabile,l.presa_in_carico_at,l.scadenza_at,
 l.prima_rilevazione_at,l.ultimo_controllo_at,l.risolta_at,l.versione,p.numero_pratica,p.nome_cliente,p.targa,
 coalesce(s.assistente,'2aef20d3-5ef8-4c81-8f21-bd450f22960c'::uuid) assistente,
 coalesce((l.motivi#>>'{richiesta_preventivo,verifica_tecnica}')::boolean,false) verifica_tecnica_necessaria,
 l.motivi#>>'{richiesta_preventivo,azione}' azione_preventivo,
 l.motivi#>'{richiesta_preventivo,dati_mancanti}' dati_mancanti,
 (select count(*) from public.keplero_esiti_fonti e where e.stato in ('ricevuto','in_attesa','da_verificare')
  and (e.pratica_id=l.pratica_id or (l.pratica_id is null and e.pratica_id is null
    and coalesce('chat:'||e.sessione,e.fonte||':'||e.chiave)=l.chiave))) fonti_aperte,false attesa_automazione
from public.keplero_lavori_pratiche l left join public.pratiche p on p.id=l.pratica_id
left join public.keplero_sessioni_originali s on s.sessione=l.sessione;
revoke all on public.keplero_lavori_pratiche_elenco from public,anon,authenticated;
grant select on public.keplero_lavori_pratiche_elenco to service_role;

create or replace function public.stato_esiti_commerciali_k()
returns jsonb language sql stable security invoker set search_path='' as $$
select jsonb_build_object('controllo',(select to_jsonb(s) from public.keplero_stato_riconciliazione s where id),
 'controllo_in_ritardo',not exists(select 1 from public.keplero_stato_riconciliazione where id and ultimo_successo_at>=now()-interval '5 minutes'),
 'lavori_aperti',(select count(*) from public.keplero_lavori_pratiche where stato<>'risolta'),
 'prioritari',(select count(*) from public.keplero_lavori_pratiche where stato<>'risolta' and priorita=0),
 'da_associare',(select count(*) from public.keplero_lavori_pratiche where stato<>'risolta' and pratica_id is null),
 'ingressi_in_elaborazione',(select count(*) from public.keplero_esiti_fonti where stato='ricevuto'),
 'ingressi_in_ritardo',(select count(*) from public.keplero_esiti_fonti where stato='ricevuto' and created_at<now()-interval '5 minutes'),
 'errori',(select count(*) from public.keplero_esiti_fonti where errore is not null and stato='da_verificare'),
 'originali_in_ritardo',not exists(select 1 from public.keplero_recupero_originali where id and automatico and ultimo_successo_at>=now()-interval '10 minutes' and errore_elenco is null),
 'fonte_originali',public.stato_originali_k());
$$;
revoke all on function public.stato_esiti_commerciali_k() from public,anon,authenticated;
grant execute on function public.stato_esiti_commerciali_k() to service_role;

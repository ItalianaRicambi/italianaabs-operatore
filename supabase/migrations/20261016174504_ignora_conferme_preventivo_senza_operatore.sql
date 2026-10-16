-- Le vecchie azioni prive di identità non sono una prova e non devono bloccare altri flussi.
create or replace function private.documento_dopo_conferma_operatore()
returns trigger language plpgsql security invoker set search_path='' as $$
declare doc uuid;
begin
 if new.azione<>'commerciale_preventivo_inviato' or coalesce(new.operatore,'') not in ('Operatore 1','Operatore 2','Operatore 3','Operatore 4') then return new; end if;
 -- Un unico documento recente: più versioni/copie richiedono verifica, non una scelta arbitraria.
 select (array_agg(id))[1] into doc from public.documenti_preventivo_auto
 where pratica_id=new.pratica_id and stato in ('pronto','da_verificare')
 and data_offerta between new.created_at-interval '30 days' and new.created_at+interval '5 minutes'
 having count(*)=1;
 if doc is not null then
  perform public.conferma_invio_documento_preventivo(doc,jsonb_build_object('fonte','operatore','fonte_id','operatore:'||new.id,'azione_id',new.id,'inviato_at',new.created_at));
 end if;
 return new;
end; $$;

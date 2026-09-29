create index if not exists idx_keplero_event_processing_pratica
  on private.keplero_event_processing(pratica_id, updated_at desc);

create index if not exists idx_keplero_live_events_pratica_created
  on public.keplero_live_events(pratica_id, created_at desc);

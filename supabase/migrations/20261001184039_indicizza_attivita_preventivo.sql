create index if not exists idx_attivita_operatore_preventivo
  on public.attivita_operatore(preventivo_id)
  where preventivo_id is not null;

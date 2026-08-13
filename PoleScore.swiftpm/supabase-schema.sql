-- PoleScore shared learning — paste this into the Supabase SQL editor and run.
--
-- One table, two policies. Every install contributes anonymous feature vectors
-- and reads back the pool, so a brand new phone starts with everyone else's
-- experience instead of nothing. The project URL and anon key are already baked
-- into CloudDefaults.swift, so once this table exists the app finds it with no
-- setup on the device and no switch to leave in the wrong position.
--
-- The cloud vision model is separate and optional — see
-- supabase/functions/polescore/index.ts. It needs no table.

create table if not exists public.training_examples (
  id          text primary key,
  device      text not null,
  features    double precision[] not null,
  label       smallint not null,
  rule_call   smallint not null,
  app_version text,
  created_at  timestamptz not null default now()
);

create index if not exists training_examples_created_idx
  on public.training_examples (created_at desc);

alter table public.training_examples enable row level security;

-- Anyone with the anon key may contribute. There is nothing personal in a row:
-- fourteen normalized numbers and the correct call. The CHECK is what makes the
-- key safe to ship in client code — it bounds what the key can do to exactly
-- "insert one well-formed observation".
create policy "anon can contribute"
  on public.training_examples
  for insert
  to anon
  with check (
    array_length(features, 1) = 14
    and label between 0 and 5
    and rule_call between 0 and 5
  );

-- Anyone may read the pool. That is the point: shared learning.
create policy "anon can read the pool"
  on public.training_examples
  for select
  to anon
  using (true);

-- Deliberately no update or delete policy. Rows are immutable observations;
-- nothing should be able to rewrite the training history after the fact.

-- Optional hygiene: cap how much history is kept.
-- delete from public.training_examples
-- where created_at < now() - interval '180 days';

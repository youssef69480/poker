-- Classement entre potes : a coller UNE fois dans Supabase (SQL Editor -> New query -> Run).
-- Une ligne par tournoi termine entre humains. Rien d'autre n'est stocke.

create table if not exists public.poker_parties (
  id      uuid primary key default gen_random_uuid(),
  cree    timestamptz not null default now(),
  donnees jsonb not null check (octet_length(donnees::text) < 8000)
);

alter table public.poker_parties enable row level security;

-- tout le monde peut lire le classement et y ajouter un tournoi,
-- personne ne peut modifier ni effacer ce qui est deja enregistre
drop policy if exists "lire le classement" on public.poker_parties;
create policy "lire le classement" on public.poker_parties
  for select to anon, authenticated using (true);

drop policy if exists "ajouter un tournoi" on public.poker_parties;
create policy "ajouter un tournoi" on public.poker_parties
  for insert to anon, authenticated with check (true);

grant select, insert on public.poker_parties to anon, authenticated;

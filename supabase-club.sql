-- ============================================================
--  Le club comme fiche partagee
--  A coller une seule fois dans l'editeur SQL de Supabase.
--
--  Avant, un club n'existait que dans le telephone de celui qui l'avait
--  cree. Son nom et ses membres etaient devines apres coup a partir des
--  parties terminees : tant que personne n'avait fini une soiree, celui
--  qui saisissait le code tombait sur une coquille vide appelee
--  « Club XXXXX », et un code FAUX donnait exactement la meme chose.
--
--  Le club est maintenant pose explicitement des sa creation.
--
--  Ce qui est protege ici, c'est ce qui pourrait nuire aux autres :
--  - le nom est fixe par le createur et n'est plus modifiable ensuite,
--    sinon n'importe qui ayant le code pourrait renommer le club ;
--  - la liste des membres ne peut que GRANDIR : une ecriture ne remplace
--    jamais la liste, elle la fusionne. Sans ca, un seul appel suffirait
--    a effacer tous les membres.
--  Le code du club reste le seul secret : qui l'a peut entrer. C'est
--  voulu -- c'est un jeu a jetons fictifs entre amis.
-- ============================================================

create table if not exists poker_clubs (
  id      text primary key,
  nom     text not null,
  cree    timestamptz not null default now(),
  membres jsonb not null default '[]'::jsonb,
  maj     timestamptz not null default now()
);

-- personne ne touche la table directement : tout passe par les fonctions
-- ci-dessous, les seules a y avoir droit (security definer).
alter table poker_clubs enable row level security;
revoke all on table poker_clubs from anon, authenticated;

-- ---------- les membres, nettoyes : au plus 40, et rien d'exotique ----------
create or replace function poker_club_membres(p jsonb) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_agg(m order by (m->>'at')::bigint nulls last), '[]'::jsonb)
  from (
    select distinct on (m->>'id') m
    from jsonb_array_elements(coalesce(p, '[]'::jsonb)) m
    where jsonb_typeof(m) = 'object'
      and nullif(trim(m->>'id'), '') is not null
    order by (m->>'id'), (m->>'at')::bigint nulls last
    limit 40
  ) q
$$;

-- ---------- poser un club, ou s'y inscrire ----------
--  Rend TOUJOURS la fiche a jour : c'est elle qui fait foi, pas ce que le
--  client croyait savoir.
create or replace function poker_club_poser(
  p_id text, p_nom text, p_membres jsonb)
returns table(id text, n text, at bigint, membres jsonb)
language plpgsql security definer set search_path = public as $$
-- les colonnes de sortie s'appellent id / membres, comme celles de la table :
-- sans cette directive, « on conflict (id) » ne sait pas de laquelle on parle.
#variable_conflict use_column
declare
  v_id text := lower(nullif(trim(p_id), ''));
begin
  if v_id is null then return; end if;

  insert into poker_clubs(id, nom, membres)
  values (left(v_id, 12),
          left(coalesce(nullif(trim(p_nom), ''), 'Club'), 24),
          poker_club_membres(p_membres))
  on conflict (id) do update
    -- le nom NE bouge PAS : seul le createur le fixe.
    -- les membres fusionnent : la liste ne peut que grandir.
    set membres = poker_club_membres(poker_clubs.membres || poker_club_membres(excluded.membres)),
        maj = now();

  return query
    select c.id, c.nom,
           (extract(epoch from c.cree) * 1000)::bigint,
           c.membres
    from poker_clubs c where c.id = left(v_id, 12);
end $$;

-- ---------- lire un club ----------
create or replace function poker_club_lire(p_id text)
returns table(id text, n text, at bigint, membres jsonb)
language sql security definer set search_path = public as $$
  select c.id, c.nom,
         (extract(epoch from c.cree) * 1000)::bigint,
         c.membres
  from poker_clubs c
  where c.id = left(lower(nullif(trim(p_id), '')), 12)
$$;

grant execute on function poker_club_poser(text, text, jsonb) to anon, authenticated;
grant execute on function poker_club_lire(text) to anon, authenticated;
-- Postgres accorde l'execution a PUBLIC par defaut : revoquer pour anon seul
-- ne revoque rien du tout. C'est bien a PUBLIC qu'il faut retirer le droit.
revoke execute on function poker_club_membres(jsonb) from public, anon, authenticated;

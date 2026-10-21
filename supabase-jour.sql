-- ============================================================
--  La main du jour
--  A coller une seule fois dans l'editeur SQL de Supabase.
--
--  Idee : une seule main, la meme pour tout le club, qui change a minuit.
--  La main elle-meme n'est PAS ici : elle est fabriquee dans l'appli a
--  partir de la date seule, donc tout le monde tombe sur la meme sans que
--  le serveur ait rien a dire. Cette table ne garde que les resultats, pour
--  qu'on puisse se comparer entre potes.
--
--  Ce qui est volontairement absent : aucune verification d'identite forte.
--  C'est un jeu a jetons fictifs entre amis -- quelqu'un qui veut tricher sur
--  son score de la main du jour peut le faire, comme il peut mentir a table.
--  En echange, aucune donnee sensible ne transite. Ce qui est protege, c'est
--  ce qui pourrait nuire aux AUTRES : on ne peut pas ecrire sous l'identite
--  de quelqu'un d'autre pour la REMPLACER par un mauvais score (voir le
--  verrou plus bas), ni lire autre chose que le classement d'un club.
-- ============================================================

create table if not exists poker_jour (
  club  text not null,
  jour  date not null,
  id    text not null,
  nom   text not null default 'Joueur',
  av    text not null default '🙂',
  bons  int  not null default 0,
  sur   int  not null default 0,
  maj   timestamptz not null default now(),
  primary key (club, jour, id)
);

create index if not exists poker_jour_cl on poker_jour(club, jour, bons desc);

-- personne ne touche la table directement : tout passe par les deux
-- fonctions ci-dessous, les seules a y avoir droit (security definer).
alter table poker_jour enable row level security;
revoke all on table poker_jour from anon, authenticated;

-- ---------- menage : on ne garde pas l'historique indefiniment ----------
create or replace function poker_jour_menage() returns void
language sql security definer set search_path = public as $$
  delete from poker_jour where jour < current_date - 60
$$;

-- ---------- ecrire son resultat du jour ----------
--  Le verrou qui compte : une ligne deja posee n'est JAMAIS remplacee par un
--  score plus bas, et seulement le MEME jour. Sans ca, n'importe qui pourrait
--  rejouer la main jusqu'a tomber juste, ou ecraser le 5/5 d'un copain par un
--  0/5. On accepte donc une seule chose : ameliorer sa propre premiere
--  reponse n'est pas possible non plus -- le premier envoi fait foi.
create or replace function poker_jour_ecrire(
  p_club text, p_jour date, p_id text, p_nom text, p_av text,
  p_bons int, p_sur int) returns void
language plpgsql security definer set search_path = public as $$
declare
  v_club text := upper(nullif(trim(p_club), ''));
  v_id   text := nullif(trim(p_id), '');
begin
  if v_club is null or v_id is null then return; end if;
  -- on n'ecrit que pour aujourd'hui : pas de resultat antidate
  if p_jour is distinct from current_date then return; end if;
  if p_sur is null or p_sur < 1 or p_sur > 12 then return; end if;
  if p_bons is null or p_bons < 0 or p_bons > p_sur then return; end if;

  insert into poker_jour(club, jour, id, nom, av, bons, sur)
  values (left(v_club, 12), p_jour, left(v_id, 24),
          left(coalesce(nullif(trim(p_nom), ''), 'Joueur'), 24),
          left(coalesce(nullif(trim(p_av), ''), '🙂'), 16),
          p_bons, p_sur)
  on conflict (club, jour, id) do update
    -- le nom et l'avatar suivent, le score non : le premier envoi fait foi
    set nom = excluded.nom, av = excluded.av, maj = now();

  perform poker_jour_menage();
end $$;

-- ---------- lire le classement d'un club pour un jour ----------
create or replace function poker_jour_lire(p_club text, p_jour date)
returns table(id text, nom text, av text, bons int, sur int)
language sql security definer set search_path = public as $$
  select id, nom, av, bons, sur
  from poker_jour
  where club = left(upper(nullif(trim(p_club), '')), 12)
    and jour = p_jour
    -- on ne sert que les 60 derniers jours : le reste est efface de toute facon
    and jour >= current_date - 60
  order by bons desc, nom asc
  limit 60
$$;

grant execute on function poker_jour_ecrire(text, date, text, text, text, int, int) to anon, authenticated;
grant execute on function poker_jour_lire(text, date) to anon, authenticated;
-- Postgres accorde l'execution a PUBLIC par defaut : revoquer pour anon seul
-- ne revoque rien. Cette fonction fait un DELETE en security definer :
-- elle doit etre hors de portee des clients.
revoke execute on function poker_jour_menage() from public, anon, authenticated;

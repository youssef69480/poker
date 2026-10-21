-- ============================================================
--  POKER — TOUT LE SQL, EN UNE SEULE FOIS
--
--  A coller dans Supabase : SQL Editor -> New query -> coller -> Run.
--  Sans risque si une partie a deja ete posee : tout est ecrit en
--  « create if not exists » / « create or replace ». On peut le relancer
--  autant de fois qu'on veut, il ne detruit jamais de donnees.
--
--  Une fois passe, ceci fonctionne :
--    - le classement et les soirees du club
--    - le croupier distant (meme l hote ne voit plus les mains)
--    - les comptes joueurs transferables
--    - le nom du club et ses membres, des l adhesion
--    - la main du jour partagee entre potes
-- ============================================================


-- ============================================================
--  1/5  Le classement entre potes (les parties terminees)
-- ============================================================
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


-- ============================================================
--  2/5  Le croupier distant (le serveur bat les cartes)
-- ============================================================
-- ============================================================
--  Le croupier distant
--  A coller une seule fois dans l'editeur SQL de Supabase.
--
--  Idee : ce n'est plus le telephone de l'hote qui bat les cartes, c'est
--  Postgres. Le paquet reste ici et personne ne peut le lire -- ni l'hote,
--  ni les invites. Chaque joueur presente un secret que lui seul connait et
--  recupere ses deux cartes, et rien d'autre. Le tableau s'ouvre rue par
--  rue, et a l'abattage chacun retourne sa main lui-meme.
--
--  Une carte est un entier, comme dans l'appli : rang*4 + enseigne,
--  rang de 2 a 14 (l'as), enseigne de 0 a 3 (pique, coeur, carreau, trefle).
--
--  Le code passe aux fonctions n'est pas le code de la table : c'est
--  "code-partie", ou "partie" est tire au sort par l'hote a chaque nouvelle
--  partie. Comme ca, deux parties de suite sur le meme code ne se melangent
--  pas, et personne ne peut reserver a l'avance les mains a venir.
-- ============================================================

-- ---------- la table des donnes ----------
create table if not exists poker_paquets (
  code    text     not null,            -- "code-partie"
  main    integer  not null,
  sieges  smallint[] not null,           -- les sieges servis, dans l'ordre de la donne
  cles    text[]     not null,           -- pour chaque siege, le sha256 de son secret
  hote    text       not null,           -- le sha256 du secret de l'hote
  paquet  smallint[] not null,           -- les 52 cartes melangees : le secret du croupier
  rue1    smallint not null default 0,   -- cartes ouvertes sur le 1er tableau (0, 3, 4, 5)
  rue2    smallint not null default 0,   -- idem pour le 2e tableau (run it twice)
  montre  smallint[] not null default '{}',       -- les sieges qui ont retourne leur main
  journal jsonb    not null default '[]'::jsonb,  -- quand chaque rue a ete demandee
  cree    timestamptz not null default now(),
  primary key (code, main)
);

create index if not exists poker_paquets_cree on poker_paquets(cree);

-- ---------- personne ne lit ces lignes directement ----------
-- RLS active et aucune policy : les clients ne peuvent ni lire ni ecrire la
-- table. Tout passe par les fonctions ci-dessous, les seules a avoir le droit
-- d'y toucher (security definer), et qui ne rendent jamais le paquet entier.
alter table poker_paquets enable row level security;
revoke all on table poker_paquets from anon, authenticated;

-- ---------- le hachage des secrets ----------
create or replace function poker_h(t text) returns text
language sql immutable as $$
  select encode(sha256(convert_to(coalesce(t,''), 'UTF8')), 'hex')
$$;

-- ---------- les mains deja retournees, dans une ligne donnee ----------
create or replace function poker_mains_montrees(v poker_paquets)
returns jsonb
language plpgsql immutable as $$
declare
  o jsonb := '{}'::jsonb;
  s smallint;
  k int;
begin
  foreach s in array coalesce(v.montre, '{}'::smallint[]) loop
    k := array_position(v.sieges, s);
    if k is not null then
      o := o || jsonb_build_object(s::text,
             jsonb_build_array(v.paquet[2*k-1], v.paquet[2*k]));
    end if;
  end loop;
  return o;
end $$;

-- ---------- menage : au-dela de 12 h, une donne ne sert plus a rien ----------
create or replace function poker_menage() returns void
language sql security definer set search_path = public as $$
  delete from poker_paquets where cree < now() - interval '12 hours'
$$;

-- ---------- de quoi verifier les cles bien formees ----------
create or replace function poker_cles_ok(p_cles text[], p_n int) returns boolean
language sql immutable as $$
  select coalesce(array_length(p_cles,1),0) = p_n
     and not exists (select 1 from unnest(p_cles) k
                      where k is null or k !~ '^[0-9a-f]{64}$')
$$;

-- ============================================================
--  1. La donne. L'hote appelle, le croupier melange.
--     Il ne recoit aucune carte en retour, pas meme les siennes.
-- ============================================================
create or replace function poker_donne(p_code text, p_main int,
                                       p_sieges smallint[], p_cles text[],
                                       p_hote text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_code text := lower(coalesce(p_code,''));
  v_n    int  := coalesce(array_length(p_sieges,1),0);
  v_jeu  smallint[];
  v      poker_paquets;
begin
  if length(v_code) < 3 or length(v_code) > 40
     or p_main is null or p_main < 0 or p_main > 100000 then
    return jsonb_build_object('ok', false, 'err', 'parametres');
  end if;
  if v_n < 2 or v_n > 10 then
    return jsonb_build_object('ok', false, 'err', 'sieges');
  end if;
  if p_hote is null or p_hote !~ '^[0-9a-f]{64}$' or not poker_cles_ok(p_cles, v_n) then
    return jsonb_build_object('ok', false, 'err', 'cles');
  end if;
  if exists (select 1 from unnest(p_sieges) s where s < 0 or s > 9) then
    return jsonb_build_object('ok', false, 'err', 'sieges');
  end if;

  -- Une main deja distribuee ne se redistribue jamais : sinon il suffirait de
  -- rappeler la fonction avec d'autres cles pour se servir le jeu d'un autre.
  -- Et la place est reservee a l'hote qui l'a ouverte : si quelqu'un d'autre
  -- a pris le numero, l'hote le saura et redistribuera sous un autre nom.
  select * into v from poker_paquets where code = v_code and main = p_main;
  if found then
    if v.hote <> p_hote then
      return jsonb_build_object('ok', false, 'err', 'pris');
    end if;
    return jsonb_build_object('ok', true, 'deja', true,
                              'n', array_length(v.sieges,1));
  end if;

  -- le melange, cote serveur
  select array_agg(c order by random())::smallint[] into v_jeu
    from (select (r*4 + s)::smallint as c
            from generate_series(2,14) r, generate_series(0,3) s) t;

  insert into poker_paquets(code, main, sieges, cles, hote, paquet)
  values (v_code, p_main, p_sieges, p_cles, p_hote, v_jeu)
  on conflict (code, main) do nothing;

  perform poker_menage();
  return jsonb_build_object('ok', true, 'deja', false, 'n', v_n);
end $$;

-- ============================================================
--  2. Mes deux cartes. Seul celui qui connait le secret les obtient.
-- ============================================================
create or replace function poker_mes_cartes(p_code text, p_main int,
                                           p_siege int, p_secret text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v poker_paquets;
  k int;
begin
  select * into v from poker_paquets
   where code = lower(coalesce(p_code,'')) and main = p_main;
  if not found then return jsonb_build_object('ok', false, 'err', 'main'); end if;

  k := array_position(v.sieges, p_siege::smallint);
  if k is null then return jsonb_build_object('ok', false, 'err', 'siege'); end if;
  if v.cles[k] <> poker_h(p_secret) then
    return jsonb_build_object('ok', false, 'err', 'cle');
  end if;

  return jsonb_build_object('ok', true,
    'cartes', jsonb_build_array(v.paquet[2*k-1], v.paquet[2*k]));
end $$;

-- plusieurs mains d'un coup : l'hote recupere la sienne et celles de ses bots
-- en un seul aller-retour. Chaque siege demande exige son propre secret.
create or replace function poker_mains(p_code text, p_main int,
                                       p_sieges smallint[], p_secrets text[])
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v poker_paquets;
  o jsonb := '{}'::jsonb;
  i int; k int; n int;
begin
  select * into v from poker_paquets
   where code = lower(coalesce(p_code,'')) and main = p_main;
  if not found then return jsonb_build_object('ok', false, 'err', 'main'); end if;

  n := coalesce(array_length(p_sieges,1),0);
  if n < 1 or n > 10 or coalesce(array_length(p_secrets,1),0) <> n then
    return jsonb_build_object('ok', false, 'err', 'sieges');
  end if;

  for i in 1..n loop
    k := array_position(v.sieges, p_sieges[i]);
    if k is not null and v.cles[k] = poker_h(p_secrets[i]) then
      o := o || jsonb_build_object(p_sieges[i]::text,
             jsonb_build_array(v.paquet[2*k-1], v.paquet[2*k]));
    end if;
  end loop;

  return jsonb_build_object('ok', true, 'mains', o);
end $$;

-- ---------- qui a le droit de regarder cette donne ----------
-- un siege avec son secret, ou l'hote avec le sien (p_siege = -1). L'hote en a
-- besoin : il tient encore la table meme quand il est elimine du tournoi.
create or replace function poker_admis(v poker_paquets, p_siege int, p_secret text)
returns boolean
language plpgsql immutable as $$
declare k int;
begin
  if p_siege is null or p_siege < 0 then
    return v.hote = poker_h(p_secret);
  end if;
  k := array_position(v.sieges, p_siege::smallint);
  return k is not null and v.cles[k] = poker_h(p_secret);
end $$;

-- ============================================================
--  3. Le tableau, rue par rue. On ne peut qu'avancer, jamais revenir,
--     et chaque ouverture est horodatee dans le journal.
-- ============================================================
create or replace function poker_tableau(p_code text, p_main int, p_tab int,
                                         p_n int, p_siege int, p_secret text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v poker_paquets;
  k int; base int; n int; haut int;
begin
  select * into v from poker_paquets
   where code = lower(coalesce(p_code,'')) and main = p_main for update;
  if not found then return jsonb_build_object('ok', false, 'err', 'main'); end if;

  if not poker_admis(v, p_siege, p_secret) then
    return jsonb_build_object('ok', false, 'err', 'cle');
  end if;
  if p_tab is null or p_tab not in (1,2) then
    return jsonb_build_object('ok', false, 'err', 'tableau');
  end if;

  -- les cartes communes commencent apres les mains ; le 2e tableau apres le 1er
  base := 2 * array_length(v.sieges,1) + (case when p_tab = 2 then 5 else 0 end);
  haut := case when p_tab = 1 then v.rue1 else v.rue2 end;
  n := least(greatest(coalesce(p_n,0), haut), 5);   -- on n'avance que vers l'avant

  if n > haut then
    if p_tab = 1 then
      update poker_paquets set rue1 = n,
             journal = journal || jsonb_build_object('t',1,'n',n,'q',p_siege,'a',now())
       where code = v.code and main = v.main;
    else
      update poker_paquets set rue2 = n,
             journal = journal || jsonb_build_object('t',2,'n',n,'q',p_siege,'a',now())
       where code = v.code and main = v.main;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'n', n,
    'cartes', coalesce((select jsonb_agg(v.paquet[base + i])
                          from generate_series(1, n) i), '[]'::jsonb));
end $$;

-- ============================================================
--  4. L'abattage. Chacun retourne sa main lui-meme ; on recoit en echange
--     celles qui sont deja sur la table. Une main que personne ne retourne
--     reste cachee : c'est la regle, il faut montrer pour gagner.
-- ============================================================
create or replace function poker_montre(p_code text, p_main int,
                                        p_siege int, p_secret text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v poker_paquets;
  k int;
begin
  select * into v from poker_paquets
   where code = lower(coalesce(p_code,'')) and main = p_main for update;
  if not found then return jsonb_build_object('ok', false, 'err', 'main'); end if;

  k := array_position(v.sieges, p_siege::smallint);
  if k is null or v.cles[k] <> poker_h(p_secret) then
    return jsonb_build_object('ok', false, 'err', 'cle');
  end if;

  if array_position(v.montre, p_siege::smallint) is null then
    update poker_paquets set montre = montre || p_siege::smallint
     where code = v.code and main = v.main
     returning * into v;
  end if;

  return jsonb_build_object('ok', true, 'mains', poker_mains_montrees(v));
end $$;

-- les mains deja retournees, pour quiconque est assis a cette donne
create or replace function poker_montrees(p_code text, p_main int,
                                          p_siege int, p_secret text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v poker_paquets;
  k int;
begin
  select * into v from poker_paquets
   where code = lower(coalesce(p_code,'')) and main = p_main;
  if not found then return jsonb_build_object('ok', false, 'err', 'main'); end if;
  if not poker_admis(v, p_siege, p_secret) then
    return jsonb_build_object('ok', false, 'err', 'cle');
  end if;
  return jsonb_build_object('ok', true, 'mains', poker_mains_montrees(v));
end $$;

-- ============================================================
--  5. Le controle. Les cles enregistrees et le journal des rues sont publics
--     a la table : chacun verifie que la cle de son siege est bien la sienne,
--     et voit a quel moment chaque rue a ete demandee. Le paquet, jamais.
-- ============================================================
create or replace function poker_controle(p_code text, p_main int)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v poker_paquets;
begin
  select * into v from poker_paquets
   where code = lower(coalesce(p_code,'')) and main = p_main;
  if not found then return jsonb_build_object('ok', false, 'err', 'main'); end if;
  return jsonb_build_object('ok', true, 'sieges', v.sieges, 'cles', v.cles,
                            'rue1', v.rue1, 'rue2', v.rue2,
                            'montre', v.montre, 'journal', v.journal,
                            'cree', v.cree);
end $$;

-- ---------- qui peut appeler quoi ----------
-- l'aide interne n'est appelable par personne de l'exterieur
revoke all on function poker_mains_montrees(poker_paquets) from public;
revoke all on function poker_admis(poker_paquets,int,text) from public;
revoke all on function poker_menage() from public;
-- les portes d'entree, elles, sont ouvertes
grant execute on function poker_donne(text,int,smallint[],text[],text) to anon, authenticated;
grant execute on function poker_mes_cartes(text,int,int,text)          to anon, authenticated;
grant execute on function poker_mains(text,int,smallint[],text[])      to anon, authenticated;
grant execute on function poker_tableau(text,int,int,int,int,text)     to anon, authenticated;
grant execute on function poker_montre(text,int,int,text)              to anon, authenticated;
grant execute on function poker_montrees(text,int,int,text)            to anon, authenticated;
grant execute on function poker_controle(text,int)                     to anon, authenticated;
grant execute on function poker_h(text)                                to anon, authenticated;


-- ============================================================
--  3/5  Les comptes joueurs (un code qui te suit d un appareil a l autre)
-- ============================================================
-- ============================================================
--  Les comptes joueurs
--  A coller une seule fois dans l'editeur SQL de Supabase.
--
--  Idee : ton identite n'est plus ton telephone, c'est un code que tu
--  gardes. L'identifiant public du joueur est derive du code par sha256 :
--
--      id = les 12 premiers caracteres de sha256(code)
--
--  Du coup, presenter le code suffit a prouver qu'on est bien le
--  proprietaire de cette ligne -- le serveur refait le calcul et n'ecrit que
--  la ligne correspondante. Personne ne peut ecrire chez un autre, et l'id
--  tout seul ne dit rien du code.
--
--  Ce qui est garde ici : le nom, l'avatar, les succes, les compteurs, et la
--  liste des anciens identifiants d'appareil (les alias), pour que deux
--  telephones du meme joueur ne comptent pas double dans le club.
-- ============================================================

create table if not exists poker_joueurs (
  id      text primary key,
  donnees jsonb not null default '{}'::jsonb,
  maj     timestamptz not null default now()
);

create index if not exists poker_joueurs_maj on poker_joueurs(maj desc);

-- personne ne lit ni n'ecrit cette table directement : tout passe par les
-- fonctions ci-dessous, les seules a y avoir droit (security definer).
alter table poker_joueurs enable row level security;
revoke all on table poker_joueurs from anon, authenticated;

-- ---------- l'identifiant public, derive du code ----------
create or replace function poker_compte_id(p_code text) returns text
language sql immutable as $$
  select left(encode(sha256(convert_to(coalesce(p_code,''), 'UTF8')), 'hex'), 12)
$$;

-- ---------- les alias, nettoyes : au plus 20, et rien d'exotique ----------
create or replace function poker_alias_propres(p jsonb) returns jsonb
language sql immutable as $$
  select coalesce(jsonb_agg(a), '[]'::jsonb) from (
    select distinct a from jsonb_array_elements_text(
      case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) a
     where a ~ '^[a-z0-9]{4,24}$'
     limit 20
  ) t
$$;

-- ============================================================
--  Ecrire SA ligne. Le code n'est jamais stocke, seulement verifie.
-- ============================================================
create or replace function poker_compte_ecrire(p_code text, p_donnees jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id text;
  v_d  jsonb;
  v_av jsonb;
begin
  if p_code is null or p_code !~ '^[a-z0-9]{10,24}$' then
    return jsonb_build_object('ok', false, 'err', 'code');
  end if;
  if p_donnees is null or jsonb_typeof(p_donnees) <> 'object' then
    return jsonb_build_object('ok', false, 'err', 'donnees');
  end if;
  if pg_column_size(p_donnees) > 8000 then
    return jsonb_build_object('ok', false, 'err', 'trop gros');
  end if;

  v_id := poker_compte_id(p_code);

  -- on ne garde que ce qu'on attend, et on borne tout
  v_av := poker_alias_propres(p_donnees -> 'alias');
  v_d := jsonb_strip_nulls(jsonb_build_object(
    'n',   left(coalesce(p_donnees ->> 'n', ''), 24),
    'av',  left(coalesce(p_donnees ->> 'av', ''), 8),
    'alias', v_av,
    'su',  case when jsonb_typeof(p_donnees -> 'su')  = 'object' then p_donnees -> 'su'  else '{}'::jsonb end,
    'cpt', case when jsonb_typeof(p_donnees -> 'cpt') = 'object' then p_donnees -> 'cpt' else '{}'::jsonb end
  ));

  insert into poker_joueurs(id, donnees, maj) values (v_id, v_d, now())
  on conflict (id) do update
    set donnees = excluded.donnees, maj = now();

  return jsonb_build_object('ok', true, 'id', v_id, 'alias', v_av);
end $$;

-- ============================================================
--  Lire un compte. Rien de secret la-dedans : un nom, un avatar, des
--  succes et des alias. On lit par identifiant, pas par code.
-- ============================================================
create or replace function poker_compte_lire(p_id text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v poker_joueurs;
begin
  if p_id is null or p_id !~ '^[0-9a-f]{12}$' then
    return jsonb_build_object('ok', false, 'err', 'id');
  end if;
  select * into v from poker_joueurs where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'err', 'inconnu'); end if;
  return jsonb_build_object('ok', true, 'id', v.id, 'donnees', v.donnees, 'maj', v.maj);
end $$;

-- ============================================================
--  Les alias de tout le monde, pour le club : c'est ce qui permet de
--  recoller deux appareils d'un meme joueur dans un seul classement.
-- ============================================================
create or replace function poker_alias()
returns jsonb
language sql security definer set search_path = public as $$
  with brut as (
    select t.id, a.a
      from (select id, donnees -> 'alias' al from poker_joueurs order by maj desc limit 500) t,
           lateral jsonb_array_elements_text(coalesce(t.al, '[]'::jsonb)) a(a)
  ),
  -- Un alias revendique par deux comptes est ambigu : on ne fusionne pas. Ca
  -- arrive sans malice (deux comptes ouverts sur le meme telephone), et ca
  -- suffirait sinon a s'approprier l'historique du voisin.
  seuls as (select a from brut group by a having count(distinct id) = 1),
  bons as (
    select b.id, b.a from brut b join seuls s on s.a = b.a
     -- ni l'identifiant d'un autre compte : on n'absorbe pas un compte entier
     where not exists (select 1 from poker_joueurs j where j.id = b.a)
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'a', al)), '[]'::jsonb)
    from (select id, jsonb_agg(a) al from bons group by id) z
$$;

-- ---------- qui peut appeler quoi ----------
revoke all on function poker_alias_propres(jsonb) from public;
grant execute on function poker_compte_ecrire(text, jsonb) to anon, authenticated;
grant execute on function poker_compte_lire(text)          to anon, authenticated;
grant execute on function poker_alias()                    to anon, authenticated;
grant execute on function poker_compte_id(text)            to anon, authenticated;


-- ============================================================
--  4/5  Le club (nom et membres partages)
-- ============================================================
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


-- ============================================================
--  5/5  La main du jour (les resultats du club)
-- ============================================================
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

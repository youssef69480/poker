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

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

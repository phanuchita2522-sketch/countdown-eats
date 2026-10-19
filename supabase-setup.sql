-- =====================================================================================
-- CountDown Eats  –  server-side rules (PostgreSQL / Supabase)            schema v3
-- Run ONCE in Supabase: SQL editor -> paste -> Run.   (Safe to re-run: uses IF NOT EXISTS / OR REPLACE.)
--
-- Why this file exists: browser code can be edited by anyone, so every rule that matters
-- (price, stock, who may confirm payment, fraud limits, pickup code) is enforced HERE.
-- The app only calls the functions below.  Tables have row-level security ON and NO policies,
-- so nobody can read or write a table directly with the public (publishable) key.
-- Standard Postgres only (no vendor extensions needed) -> can move to any Postgres host later.
-- =====================================================================================

-- ---------- settings ----------
create table if not exists cde_cfg (k text primary key, v text not null);
insert into cde_cfg(k,v) values ('terms_version','2026-10-14') on conflict do nothing;
insert into cde_cfg(k,v) values ('tag_salt', replace(gen_random_uuid()::text,'-','')) on conflict do nothing;

-- ---------- tables ----------
create table if not exists profiles (
  uid           uuid primary key references auth.users(id) on delete cascade,
  terms_version text,
  terms_at      timestamptz,
  banned        boolean not null default false,          -- admin: set true to block an account
  kg            numeric(10,1) not null default 0,         -- eco totals (kept after old orders are purged)
  items_saved   int not null default 0,
  baht_saved    int not null default 0,
  boxes         int not null default 0,
  points        int not null default 0,
  created_at    timestamptz not null default now()
);

create table if not exists shops (
  id         bigint generated always as identity primary key,
  owner      uuid not null references auth.users(id) on delete cascade,
  doc        jsonb not null,                              -- public catalogue (validated by _clean_doc); NO payment data
  type       text not null,
  chain      text,
  end_hm     text,
  lat        double precision,
  lng        double precision,
  trust      numeric(3,1) not null default 4.5,
  n_rated    int not null default 0,
  paused     boolean not null default false,              -- admin: hide a shop
  cleared    boolean not null default false,              -- admin: ignore automatic suspension
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()           -- bumped on every change that affects what buyers see (also stock)
);
create index if not exists shops_owner_idx on shops(owner);
create index if not exists shops_upd_idx   on shops(updated_at);
create index if not exists shops_geo_idx   on shops(lat,lng);

create table if not exists shop_pay (                      -- payment details: readable ONLY through order snapshots / owner functions
  shop_id bigint primary key references shops(id) on delete cascade,
  pp text, name text not null, bank text, acct text,
  ts timestamptz not null default now()
);

create table if not exists listings (                      -- authoritative price / stock / epoch, derived from the validated doc
  shop_id bigint not null references shops(id) on delete cascade,
  lk text not null check (lk in ('item','bundle','box')),
  lid text not null,
  price int not null check (price between 1 and 99999),
  worth int not null default 0,
  qty int not null check (qty between 0 and 999),
  ep bigint not null,                                      -- ms epoch of last (re)listing; orders before it no longer count
  d date not null,                                         -- Bangkok day of last listing (food ends with the day)
  food boolean not null default false,
  exp date,
  valid boolean not null default true,
  primary key (shop_id,lk,lid)
);

create table if not exists orders (
  id         bigint generated always as identity primary key,
  buyer      uuid references auth.users(id) on delete set null,
  shop_id    bigint not null references shops(id) on delete cascade,
  lk text not null, lid text not null, qty int not null check (qty between 1 and 5),
  unit_price int not null, total int not null, worth int not null default 0,
  sat        int not null default 0,                        -- unique satang (1-99) added to the amount so the shop can match the transfer
  status     text not null check (status in ('pending','review','paid','done','cancelled','expired')),
  code       text not null,                                 -- pickup code: shown to the BUYER only; shop must type/scan it
  snap       jsonb not null,                                -- display snapshot (name, emoji, kind, mix, food/non-food counts ...)
  pay        jsonb,                                         -- payment details copied at order time (buyers only ever see these for their own order)
  created_at timestamptz not null default now(),
  claimed_at timestamptz,                                   -- buyer pressed "I have paid"
  decided_at timestamptz,
  done_at    timestamptz,
  cancel_by  text,                                          -- buyer | owner | timeout
  report     text check (report in ('noitem','wrong','overcharge','fake')),
  rating     numeric(2,1)
);
create index if not exists orders_buyer_idx  on orders(buyer,created_at desc);
create index if not exists orders_shop_idx   on orders(shop_id,created_at desc);
create index if not exists orders_stock_idx  on orders(shop_id,lk,lid,created_at);
create index if not exists orders_open_idx   on orders(status) where status in ('pending','review','paid');
create unique index if not exists orders_code_idx on orders(code);

alter table listings add column if not exists auto boolean not null default false;      -- standing-menu items are kept by the nightly clean-up

-- One compact row per order, written by trigger. ~250 bytes. Survives the raw order, product and (anonymised) account deletion.
create table if not exists order_ledger (
  order_id   bigint primary key,
  buyer      uuid,                                     -- set to NULL when the buyer deletes the account
  shop_id    bigint not null,                          -- no foreign key: kept even if the shop is deleted
  shop_name  text, title text,
  lk text not null, lid text not null, qty smallint not null,
  total      int not null, sat smallint not null default 0,      -- amount to transfer = total + sat/100 baht
  status     text not null,
  created_at timestamptz not null, claimed_at timestamptz, decided_at timestamptz, done_at timestamptz,
  cancel_by  text, report text,
  pay_name   text, pay_ref text                        -- recipient name and last 4 digits only
);
create index if not exists ledger_buyer_idx on order_ledger(buyer, created_at desc) where buyer is not null;
create index if not exists ledger_shop_idx  on order_ledger(shop_id, lk, lid, created_at);
alter table order_ledger enable row level security;
revoke all on order_ledger from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname='anon') then revoke all on order_ledger from anon; end if;
  if exists (select 1 from pg_roles where rolname='authenticated') then revoke all on order_ledger from authenticated; end if;
end $$;


create table if not exists rate_log (uid uuid not null, kind text not null, ts timestamptz not null default now());
create index if not exists rate_log_idx on rate_log(uid,kind,ts);

alter table cde_cfg  enable row level security;
alter table profiles enable row level security;
alter table shops    enable row level security;
alter table shop_pay enable row level security;
alter table listings enable row level security;
alter table orders   enable row level security;
alter table rate_log enable row level security;
-- (no policies on purpose: direct table access through the public API is denied)
revoke all on cde_cfg, profiles, shops, shop_pay, listings, orders, rate_log from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname='anon') then revoke all on cde_cfg, profiles, shops, shop_pay, listings, orders, rate_log from anon; end if;
  if exists (select 1 from pg_roles where rolname='authenticated') then revoke all on cde_cfg, profiles, shops, shop_pay, listings, orders, rate_log from authenticated; end if;
end $$;

-- ---------- small helpers ----------
create or replace function _err(code text, n int default 0) returns void language plpgsql as $$
begin raise exception 'CDE_ERR:%:%', code, n using errcode='P0001'; end $$;

create or replace function _now_ms() returns bigint language sql stable as $$ select (extract(epoch from clock_timestamp())*1000)::bigint $$;
create or replace function _today() returns date language sql stable as $$ select (now() at time zone 'Asia/Bangkok')::date $$;
create or replace function _bkk_hour() returns int language sql stable as $$ select extract(hour from now() at time zone 'Asia/Bangkok')::int $$;
create or replace function _is_timed(t text) returns boolean language sql immutable as $$ select t in ('eatery','market','cafe') $$;
-- end-of-sale moment (timestamptz) of the Bangkok day `d` for a shop's cut-off time
create or replace function _end_ts(d date, hm text) returns timestamptz language sql immutable as $$
  select ((d::text||' '||coalesce(nullif(hm,''),'20:30'))::timestamp at time zone 'Asia/Bangkok') $$;

create or replace function _txt(v jsonb, n int) returns text language sql immutable as $$
  select left(btrim(regexp_replace(regexp_replace(coalesce(case when jsonb_typeof(v)='string' then v #>> '{}' end,''),'[[:cntrl:]<>]',' ','g'),'\s+',' ','g')),n) $$;
create or replace function _has_contact(x text) returns boolean language sql immutable as $$
  select translate(coalesce(x,''),'๐๑๒๓๔๕๖๗๘๙','0123456789') ~* '((\d[ .()-]*){9,}|https?://|www\.|\.(com|net|me)\M|\.co\.th|@\w{3,}|line ?id|ไลน์|wechat|whatsapp|微信)' $$;
create or replace function _bad_claim(x text) returns boolean language sql immutable as $$
  select coalesce(x,'') ~* '(รักษา(โรค|มะเร็ง|เบาหวาน|ความดัน)|หายขาด|ป้องกันโรค|\mcures?\M|miracle|cancer|diabetes)' $$;
-- {th,en} name object from a string or an object
create or replace function _nm(v jsonb) returns jsonb language plpgsql immutable as $$
declare th text; en text;
begin
  if jsonb_typeof(v)='string' then th:=_txt(v,60); en:=th;
  elsif jsonb_typeof(v)='object' then th:=_txt(v->'th',60); en:=_txt(v->'en',60); if th='' then th:=en; end if; if en='' then en:=th; end if;
  else return null; end if;
  if th='' then return null; end if;
  return jsonb_build_object('th',th,'en',en);
end $$;
create or replace function _date_or_null(v jsonb) returns date language plpgsql immutable as $$
begin
  if jsonb_typeof(v)<>'string' or (v #>> '{}') !~ '^\d{4}-\d{2}-\d{2}$' then return null; end if;
  return (v #>> '{}')::date;
exception when others then return null; end $$;
create or replace function _int(v jsonb, lo int, hi int, dflt int) returns int language plpgsql immutable as $$
declare x numeric;
begin
  if jsonb_typeof(v)='number' then x:=floor((v #>> '{}')::numeric); elsif jsonb_typeof(v)='string' and (v #>> '{}') ~ '^\d{1,9}$' then x:=(v #>> '{}')::numeric; else return dflt; end if;
  if x<lo or x>hi then return dflt; end if;
  return x::int;
end $$;

create or replace function _ms(v jsonb) returns bigint language plpgsql immutable as $$
begin
  if jsonb_typeof(v)='number' and (v #>> '{}') ~ '^\d{1,15}(\.\d+)?$' then return floor((v #>> '{}')::numeric)::bigint; end if;
  return 0;
end $$;

-- ---------- identity / consent / rate limit ----------
create or replace function _need_user() returns uuid language plpgsql stable security definer set search_path=public,pg_temp as $$
declare u uuid := auth.uid(); p profiles;
begin
  if u is null then perform _err('AUTH'); end if;
  if coalesce((auth.jwt()->>'is_anonymous')::boolean,false) then perform _err('LOGIN'); end if;     -- real (Google) account required
  select * into p from profiles where uid=u;
  if not found or p.terms_version is distinct from (select v from cde_cfg where k='terms_version') then perform _err('TERMS'); end if;
  if p.banned then perform _err('BANNED'); end if;
  return u;
end $$;

create or replace function _rate(u uuid, kind text, mx int, secs int) returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
  if (select count(*) from rate_log where uid=u and rate_log.kind=_rate.kind and ts>now()-make_interval(secs=>secs))>=mx then perform _err('RATE'); end if;
  insert into rate_log(uid,kind) values (u,kind);
end $$;

create or replace function accept_terms(p_version text) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid := auth.uid(); cur text := (select v from cde_cfg where k='terms_version');
begin
  if u is null then perform _err('AUTH'); end if;
  if coalesce((auth.jwt()->>'is_anonymous')::boolean,false) then perform _err('LOGIN'); end if;
  if p_version is distinct from cur then perform _err('BAD_INPUT'); end if;
  insert into profiles(uid,terms_version,terms_at) values (u,cur,now())
    on conflict (uid) do update set terms_version=cur, terms_at=now();
  return jsonb_build_object('terms',cur);
end $$;

-- ---------- fraud signals (all computed from server data) ----------
create or replace function _done_buyers(p_shop bigint) returns int language sql stable security definer set search_path=public,pg_temp as $$
  select count(distinct buyer)::int from order_ledger where shop_id=p_shop and status='done' and buyer is not null $$;

create or replace function _flagged(p_shop bigint) returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select exists(select 1 from shops s where s.id=p_shop and not s.cleared)
     and (select count(distinct buyer) from order_ledger where shop_id=p_shop and report is not null and status in ('paid','done') and buyer is not null and created_at>now()-interval '30 days')>=3 $$;

create or replace function _suspended(s shops) returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select s.paused or (not s.cleared and ((s.n_rated>=5 and s.trust<3.5) or _flagged(s.id))) $$;

-- buyer is limited when 2 different CREDIBLE shops rejected a payment he claimed to have made (30 days)
create or replace function _blocked(u uuid) returns boolean language sql stable security definer set search_path=public,pg_temp as $$
  select (select count(distinct s.owner) from order_ledger o join shops s on s.id=o.shop_id
           where o.buyer=u and o.status='cancelled' and o.cancel_by='owner' and o.claimed_at is not null and o.created_at>now()-interval '30 days'
             and _done_buyers(s.id)>=3)>=2 $$;

create or replace function _sold(p_shop bigint, p_lk text, p_lid text, p_ep bigint) returns int language sql stable security definer set search_path=public,pg_temp as $$
  select coalesce(sum(qty),0)::int from order_ledger
   where shop_id=p_shop and lk=p_lk and lid=p_lid and created_at>=to_timestamp(p_ep/1000.0)
     and (status in ('review','paid','done') or (status='pending' and created_at>now()-interval '15 minutes')) $$;

create or replace function _touch(p_shop bigint) returns void language sql security definer set search_path=public,pg_temp as $$
  update shops set updated_at=now() where id=p_shop $$;

-- lazy housekeeping: unpaid reservations time out, unclaimed food orders expire after the sale window
create or replace function _sweep(p_shop bigint default null, p_buyer uuid default null) returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare ids bigint[];
begin
  with u as (
    update orders set status='cancelled', cancel_by='timeout', decided_at=created_at+interval '15 minutes'
     where status='pending' and created_at<now()-interval '15 minutes' and (p_shop is null or shop_id=p_shop) and (p_buyer is null or buyer=p_buyer)
     returning shop_id)
  select array_agg(distinct shop_id) into ids from u;
  if ids is not null then update shops set updated_at=now() where id=any(ids); end if;
  update orders o set status='expired', decided_at=now()
    from shops s
   where s.id=o.shop_id and o.status in ('review','paid') and (p_shop is null or o.shop_id=p_shop) and (p_buyer is null or o.buyer=p_buyer)
     and ( (_is_timed(s.type) and now()>_end_ts((o.created_at at time zone 'Asia/Bangkok')::date,s.end_hm)+interval '15 minutes')
        or (not _is_timed(s.type) and o.created_at<now()-interval '7 days') );
end $$;

-- ---------- catalogue validation ----------
create or replace function _img_ok(u text, owner uuid) returns boolean language sql immutable as $$
  select coalesce(u,'') ~ ('^https://[a-z0-9.-]+/storage/v1/object/public/menu/'||owner::text||'/[A-Za-z0-9._-]{1,80}$') $$;

create or replace function _clean_doc(p jsonb, owner uuid) returns jsonb language plpgsql stable set search_path=public,pg_temp as $$
declare
  ty text := p->>'type'; allowed text[]; tags jsonb:='[]'; items jsonb:='[]'; bund jsonb:='[]'; sets jsonb:='[]';
  it jsonb; b jsonb; st jsonb; nm jsonb; cat text; price int; worth int; w2 int; qty int; ids text[]:='{}'; id text; f text; sz text;
  addr text; lat double precision; lng double precision; ends text; mix jsonb; k text; v int; cnt int; ok boolean; hm text;
  bi text; bitem jsonb; bids jsonb; sumw int;
begin
  if jsonb_typeof(p)<>'object' then perform _err('BAD_INPUT'); end if;
  if ty not in ('eatery','market','cafe','beauty','health','fashion','general','chain') then perform _err('BAD_INPUT'); end if;
  allowed := case ty when 'beauty' then array['beauty'] when 'health' then array['supp'] when 'fashion' then array['apparel','shoes']
                     when 'general' then array['beauty','supp','apparel','shoes','other'] when 'chain' then array['savory','sweet','drink','beauty','supp','other']
                     else array['savory','sweet','drink'] end;
  nm := _nm(p->'name'); if nm is null then perform _err('BAD_INPUT'); end if;
  if _has_contact(nm->>'th') or _has_contact(nm->>'en') or _bad_claim(nm->>'th') or _bad_claim(nm->>'en') then perform _err('BAD_TEXT'); end if;
  addr := _txt(p->'addr',80); if _has_contact(addr) then perform _err('BAD_TEXT'); end if;
  lat := case when jsonb_typeof(p->'lat')='number' then (p->>'lat')::double precision end;
  lng := case when jsonb_typeof(p->'lng')='number' then (p->>'lng')::double precision end;
  if lat is null or lng is null or abs(lat)>90 or abs(lng)>180 or (lat=0 and lng=0) then lat:=null; lng:=null; end if;
  hm := coalesce(p->>'endHM','');
  if hm not in ('','19:00','19:30','20:00','20:30','21:00') then perform _err('BAD_INPUT'); end if;
  if jsonb_typeof(p->'tags')='array' then
    select coalesce(jsonb_agg(distinct x),'[]') into tags from jsonb_array_elements_text(p->'tags') x where x in ('halal','veg','set','dessert'); end if;

  -- single items
  if jsonb_typeof(p->'items')='array' then
    if jsonb_array_length(p->'items')>10 then perform _err('TOO_MANY_ITEMS'); end if;
    for it in select * from jsonb_array_elements(p->'items') loop
      id := it->>'id'; if id is null or id !~ '^[A-Za-z0-9_-]{1,24}$' or id = any(ids) then perform _err('BAD_ITEM'); end if; ids:=ids||id;
      cat := it->>'cat'; if cat is null or not (cat=any(allowed)) then perform _err('BAD_ITEM'); end if;
      price := _int(it->'price',1,9999,0); if price=0 then perform _err('BAD_ITEM'); end if;
      worth := _int(it->'worth',0,99999,0); if worth<price or worth>price*10 then worth:=0; end if;
      qty := _int(it->'qty',0,999,-1); if qty<0 then perform _err('BAD_ITEM'); end if;
      nm := _nm(it->'name'); if nm is null or _has_contact(nm->>'th') or _has_contact(nm->>'en') or _bad_claim(nm->>'th') or _bad_claim(nm->>'en') then perform _err('BAD_TEXT'); end if;
      f := left(regexp_replace(coalesce(it->>'fda',''),'[^A-Za-z0-9 -]','','g'),24);
      sz := left(regexp_replace(coalesce(it->>'size',''),'[^A-Za-z0-9 ./-]','','g'),12);
      if cat in ('beauty','supp') and f !~ '^[A-Za-z0-9][A-Za-z0-9 -]{5,23}$' then perform _err('BAD_FDA'); end if;
      if cat in ('apparel','shoes') and sz='' then perform _err('BAD_ITEM'); end if;
      items := items || jsonb_build_array(jsonb_build_object('id',id,'name',nm,'price',price,'worth',worth,'cat',cat,'qty',qty,
        'exp',_date_or_null(it->'exp'),'fda',f,'size',sz,'auto',coalesce((it->>'auto')='true',false),
        'img',case when _img_ok(it->>'img',owner) then it->>'img' else '' end,
        'ep',_ms(it->'ep')));
    end loop;
  end if;

  -- bundles (shop-made sets of 2-6 items)
  ids := '{}';
  if jsonb_typeof(p->'bundles')='array' then
    if jsonb_array_length(p->'bundles')>4 then perform _err('BAD_ITEM'); end if;
    for b in select * from jsonb_array_elements(p->'bundles') loop
      id := b->>'id'; if id is null or id !~ '^[A-Za-z0-9_-]{1,24}$' or id = any(ids) then perform _err('BAD_ITEM'); end if; ids:=ids||id;
      bids := '[]'; if jsonb_typeof(b->'itemIds')='array' then
        select coalesce(jsonb_agg(distinct x),'[]') into bids from jsonb_array_elements_text(b->'itemIds') x where exists (select 1 from jsonb_array_elements(items) m where m->>'id'=x); end if;
      cnt := jsonb_array_length(bids); if cnt<2 or cnt>6 then perform _err('BAD_ITEM'); end if;
      price := _int(b->'price',1,99999,0); if price=0 then perform _err('BAD_ITEM'); end if;
      qty := _int(b->'qty',0,999,-1); if qty<0 then perform _err('BAD_ITEM'); end if;
      f := _txt(b->'name',30); if _has_contact(f) or _bad_claim(f) then perform _err('BAD_TEXT'); end if;
      bund := bund || jsonb_build_array(jsonb_build_object('id',id,'name',f,'itemIds',bids,'price',price,'qty',qty,'auto',coalesce((b->>'auto')='true',false),'ep',_ms(b->'ep')));
    end loop;
  end if;

  -- mystery boxes
  ids := '{}';
  if jsonb_typeof(p->'sets')='array' then
    if jsonb_array_length(p->'sets')>3 then perform _err('BAD_ITEM'); end if;
    for st in select * from jsonb_array_elements(p->'sets') loop
      id := st->>'id'; if id is null or id !~ '^[A-Za-z0-9_-]{1,24}$' or id = any(ids) then perform _err('BAD_ITEM'); end if; ids:=ids||id;
      mix := '{}'; cnt := 0;
      if jsonb_typeof(st->'mix')<>'object' then perform _err('BAD_ITEM'); end if;
      for k in select jsonb_object_keys(st->'mix') loop
        if not (k=any(allowed)) then perform _err('BAD_ITEM'); end if;
        v := _int(st->'mix'->k,0,6,0); if v>0 then mix := mix||jsonb_build_object(k,v); cnt:=cnt+v; end if;
      end loop;
      if cnt<1 or cnt>6 then perform _err('BAD_ITEM'); end if;
      price := _int(st->'price',1,99999,0); if price=0 then perform _err('BAD_ITEM'); end if;
      worth := _int(st->'worth',0,99999,0); if worth<price or worth>price*10 then worth:=0; end if;
      qty := _int(st->'qty',0,999,-1); if qty<0 then perform _err('BAD_ITEM'); end if;
      sets := sets || jsonb_build_array(jsonb_build_object('id',id,'mix',mix,'price',price,'worth',worth,'qty',qty,'auto',coalesce((st->>'auto')='true',false),'ep',_ms(st->'ep')));
    end loop;
  end if;

  return jsonb_build_object('name',_nm(p->'name'),'emoji',left(coalesce(p->>'emoji','🍱'),4),'type',ty,
    'chain',case when ty='chain' and (p->>'chain') in ('bigc','makro','lotus','central','themall','seven','cj','other') then p->>'chain' when ty='chain' then 'other' else '' end,
    'tags',tags,'endHM',hm,'addr',addr,'lat',lat,'lng',lng,
    'remind',jsonb_build_object('on',coalesce((p->'remind'->>'on')='true',false),'hm',case when (p->'remind'->>'hm') in ('06:00','06:30','07:00','07:30','08:00','09:00','10:00') then p->'remind'->>'hm' else '07:30' end),
    'items',items,'bundles',bund,'sets',sets);
end $$;

-- ---------- shop save / delete / read ----------
-- flat list of the listings contained in a validated doc
drop function if exists _listing_rows(jsonb);
create or replace function _listing_rows(d jsonb) returns table(lk text, lid text, price int, worth int, qty int, food boolean, exp date, cli_ep bigint, auto boolean) language sql stable set search_path=public,pg_temp as $$
  select 'item', i->>'id', (i->>'price')::int, (i->>'worth')::int, (i->>'qty')::int, (i->>'cat') in ('savory','sweet','drink'), nullif(i->>'exp','')::date, (i->>'ep')::bigint, coalesce((i->>'auto')='true',false)
    from jsonb_array_elements(d->'items') i
  union all
  select 'bundle', b->>'id', (b->>'price')::int,
         (select coalesce(sum(greatest((m->>'worth')::int,(m->>'price')::int)),0)::int from jsonb_array_elements(d->'items') m where m->>'id' in (select jsonb_array_elements_text(b->'itemIds'))),
         (b->>'qty')::int,
         exists(select 1 from jsonb_array_elements(d->'items') m where m->>'id' in (select jsonb_array_elements_text(b->'itemIds')) and (m->>'cat') in ('savory','sweet','drink')),
         (select min(nullif(m->>'exp','')::date) from jsonb_array_elements(d->'items') m where m->>'id' in (select jsonb_array_elements_text(b->'itemIds'))),
         (b->>'ep')::bigint, coalesce((b->>'auto')='true',false)
    from jsonb_array_elements(d->'bundles') b
  union all
  select 'box', s->>'id', (s->>'price')::int, (s->>'worth')::int, (s->>'qty')::int,
         exists(select 1 from jsonb_object_keys(s->'mix') k where k in ('savory','sweet','drink')), null::date, (s->>'ep')::bigint, coalesce((s->>'auto')='true',false)
    from jsonb_array_elements(d->'sets') s
$$;

create or replace function save_shop(p_id bigint, p_doc jsonb, p_pay jsonb) returns bigint language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid := _need_user(); dd jsonb; sid bigint := p_id; ty text; now_ms bigint := _now_ms(); today date := _today();
  r record; old listings; li record; ppn text; accn text; pnm text; pbk text; nowl bigint; prev shop_pay; newep bigint; newd date;
begin
  perform _rate(u,'save_shop',60,3600);
  if pg_column_size(p_doc)>60000 then perform _err('BAD_INPUT'); end if;
  dd := _clean_doc(p_doc,u); ty := dd->>'type';
  if sid is null then
    if (select count(*) from shops where owner=u)>=3 then perform _err('TOO_MANY_SHOPS'); end if;
    insert into shops(owner,doc,type,chain,end_hm,lat,lng) values (u,dd,ty,dd->>'chain',dd->>'endHM',nullif(dd->>'lat','')::float8,nullif(dd->>'lng','')::float8) returning id into sid;
  else
    if not exists (select 1 from shops where id=sid and owner=u) then perform _err('NOT_FOUND'); end if;
    update shops set doc=dd,type=ty,chain=dd->>'chain',end_hm=dd->>'endHM',lat=nullif(dd->>'lat','')::float8,lng=nullif(dd->>'lng','')::float8,updated_at=now() where id=sid;
  end if;

  -- listings: server decides ep (relist moment) and day, never the client
  delete from listings l where l.shop_id=sid and not exists (select 1 from _listing_rows(dd) n where n.lk=l.lk and n.lid=l.lid);
  insert into listings(shop_id,lk,lid,price,worth,qty,ep,d,food,exp,valid,auto)
    select sid,n.lk,n.lid,n.price,n.worth,n.qty,
           case when o.lid is null or n.qty<>o.qty or n.cli_ep>o.ep then now_ms else o.ep end,
           case when o.lid is null or n.qty<>o.qty or n.cli_ep>o.ep then today else o.d end,
           n.food,n.exp,true,n.auto
      from _listing_rows(dd) n left join listings o on o.shop_id=sid and o.lk=n.lk and o.lid=n.lid
    on conflict (shop_id,lk,lid) do update set price=excluded.price,worth=excluded.worth,qty=excluded.qty,ep=excluded.ep,d=excluded.d,food=excluded.food,exp=excluded.exp,auto=excluded.auto;

  -- payment details (optional on every save: null = keep what is stored)
  if p_pay is not null and jsonb_typeof(p_pay)='object' then
    ppn := regexp_replace(coalesce(p_pay->>'pp',''),'\D','','g'); accn := regexp_replace(coalesce(p_pay->>'acct',''),'\D','','g');
    pnm := _txt(p_pay->'name',40); pbk := _txt(p_pay->'bank',30);
    if ppn<>'' and ppn !~ '^(0\d{9}|\d{13}|\d{15})$' then perform _err('BAD_PAY'); end if;
    if accn<>'' and accn !~ '^\d{10,15}$' then perform _err('BAD_PAY'); end if;
    if pnm='' or (ppn='' and accn='') or _has_contact(pnm) or _has_contact(pbk) then perform _err('BAD_PAY'); end if;
    select * into prev from shop_pay where shop_id=sid;
    if not found then insert into shop_pay(shop_id,pp,name,bank,acct) values (sid,nullif(ppn,''),pnm,pbk,nullif(accn,''));
    elsif prev.pp is distinct from nullif(ppn,'') or prev.acct is distinct from nullif(accn,'') or prev.name<>pnm then
      update shop_pay set pp=nullif(ppn,''),name=pnm,bank=pbk,acct=nullif(accn,''),ts=now() where shop_id=sid;   -- ts drives the "payment details changed recently" warning
    else update shop_pay set bank=pbk where shop_id=sid; end if;
  end if;
  return sid;
end $$;

create or replace function delete_shop(p_id bigint) returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid := _need_user();
begin
  if not exists (select 1 from shops where id=p_id and owner=u) then perform _err('NOT_FOUND'); end if;
  if exists (select 1 from orders where shop_id=p_id and status in ('pending','review','paid')) then perform _err('STATE'); end if;
  delete from shops where id=p_id and owner=u;
end $$;

-- public JSON of a shop (stock / state computed here). Payment details are included only for the owner.
create or replace function _shop_json(s shops, p_mine boolean) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare j jsonb; today date := _today(); items jsonb; bund jsonb; sets jsonb; pay jsonb; endms bigint;
begin
  select coalesce(jsonb_agg(i || jsonb_build_object('left',greatest(0,l.qty-_sold(s.id,'item',l.lid,l.ep)),'ep',l.ep,'d',l.d::text,'exp',coalesce(i->'exp','null'::jsonb))),'[]') into items
    from jsonb_array_elements(s.doc->'items') i join listings l on l.shop_id=s.id and l.lk='item' and l.lid=i->>'id';
  select coalesce(jsonb_agg(i || jsonb_build_object('left',greatest(0,l.qty-_sold(s.id,'bundle',l.lid,l.ep)),'ep',l.ep,'d',l.d::text,'worth',l.worth)),'[]') into bund
    from jsonb_array_elements(s.doc->'bundles') i join listings l on l.shop_id=s.id and l.lk='bundle' and l.lid=i->>'id';
  select coalesce(jsonb_agg(i || jsonb_build_object('left',greatest(0,l.qty-_sold(s.id,'box',l.lid,l.ep)),'ep',l.ep,'d',l.d::text)),'[]') into sets
    from jsonb_array_elements(s.doc->'sets') i join listings l on l.shop_id=s.id and l.lk='box' and l.lid=i->>'id';
  endms := case when _is_timed(s.type) then (extract(epoch from _end_ts(today,s.end_hm))*1000)::bigint else (_now_ms()+3650::bigint*86400000) end;
  j := (s.doc - 'items' - 'bundles' - 'sets') || jsonb_build_object('id',s.id,'items',items,'bundles',bund,'sets',sets,'trust',s.trust,'n',greatest(2,s.n_rated),
        'verified',true,'verifiedAt',(extract(epoch from s.created_at)*1000)::bigint,'endAt',endms,'doneN',_done_buyers(s.id),
        'hasPay',(s.type='chain' or exists(select 1 from shop_pay p where p.shop_id=s.id)),'susp',_suspended(s),'mine',p_mine);
  if p_mine then
    select jsonb_build_object('pp',coalesce(pp,''),'name',name,'bank',coalesce(bank,''),'acct',coalesce(acct,''),'ts',(extract(epoch from ts)*1000)::bigint) into pay from shop_pay where shop_id=s.id;
    if pay is not null then j := j || jsonb_build_object('pay',pay); end if;
  end if;
  return j;
end $$;

-- shops near a point (public). Delta sync: pass the `now` of the previous reply as p_since to receive only changed shops.
create or replace function list_shops(p_lat double precision default null, p_lng double precision default null, p_km double precision default 6, p_since bigint default null) returns jsonb
language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid := auth.uid(); out jsonb; ids jsonb; dlat double precision; dlng double precision; km double precision := least(greatest(coalesce(p_km,6),0.5),30); vis bigint[];
begin
  if p_lat is not null and p_lng is not null and abs(p_lat)<=90 and abs(p_lng)<=180 then
    dlat := km/111.0; dlng := km/(111.0*greatest(0.2,cos(radians(p_lat))));
    select array_agg(id) into vis from (select s.id from shops s where s.owner is distinct from u and s.lat between p_lat-dlat and p_lat+dlat and s.lng between p_lng-dlng and p_lng+dlng
       order by (s.lat-p_lat)^2+((s.lng-p_lng)*cos(radians(p_lat)))^2 limit 300) q;
  else
    select array_agg(id) into vis from (select s.id from shops s where s.owner is distinct from u order by s.updated_at desc limit 150) q;
  end if;
  vis := coalesce(vis,'{}');
  select coalesce(jsonb_agg(s.id),'[]') into ids from shops s where s.id=any(vis) and not _suspended(s);
  select coalesce(jsonb_agg(_shop_json(s,false)),'[]') into out from shops s
   where s.id=any(vis) and not _suspended(s) and (p_since is null or s.updated_at>to_timestamp((p_since-3000)/1000.0));
  return jsonb_build_object('now',_now_ms(),'ids',ids,'shops',out);
end $$;

create or replace function get_shop(p_id bigint) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare s shops; u uuid := auth.uid();
begin
  select * into s from shops where id=p_id; if not found then perform _err('NOT_FOUND'); end if;
  if s.owner is distinct from u and _suspended(s) then perform _err('NOT_FOUND'); end if;
  return _shop_json(s,s.owner is not distinct from u and u is not null);
end $$;

create or replace function my_shops() returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid := auth.uid();
begin
  if u is null then perform _err('AUTH'); end if;
  return coalesce((select jsonb_agg(_shop_json(s,true) order by s.id) from shops s where s.owner=u),'[]');
end $$;

-- ---------- orders ----------
create or replace function _order_json(o orders, role text) returns jsonb language plpgsql stable security definer set search_path=public,pg_temp as $$
declare j jsonb;
begin
  j := o.snap || jsonb_build_object('id',o.id,'shopId',o.shop_id,'lk',o.lk,'lid',o.lid,'qty',o.qty,'price',o.total,'worth',o.worth,'sat',o.sat,
        'no',_order_no(o.id),'status',o.status,'ts',(extract(epoch from o.created_at)*1000)::bigint,'cl',o.claimed_at is not null,'rp',coalesce(o.report,''),'rated',o.rating is not null);
  if role='buyer' then
    j := j || jsonb_build_object('code',o.code,'buyer','me');
    if o.status='pending' and o.pay is not null then j := j || jsonb_build_object('pay',o.pay); end if;
  else
    j := j || jsonb_build_object('tail',right(o.code,4),'buyer','remote','tag','B'||upper(substr(md5(coalesce(o.buyer::text,'x')||o.shop_id::text||(select v from cde_cfg where k='tag_salt')),1,4)));
  end if;
  return j;
end $$;

create or replace function _snap(d jsonb, p_lk text, p_lid text, p_qty int) returns jsonb language plpgsql stable set search_path=public,pg_temp as $$
declare name jsonb := d->'name'; food int:=0; non int:=0; its jsonb; m jsonb; n int:=1; mixo jsonb:=null; iname jsonb:=null; bname text:=''; inames jsonb:='[]'; k text; v int; b jsonb; s jsonb;
begin
  if p_lk='item' then
    select i into m from jsonb_array_elements(d->'items') i where i->>'id'=p_lid;
    iname:=m->'name'; if (m->>'cat') in ('savory','sweet','drink') then food:=p_qty; else non:=p_qty; end if;
  elsif p_lk='bundle' then
    select x into b from jsonb_array_elements(d->'bundles') x where x->>'id'=p_lid; bname:=coalesce(b->>'name','');
    for m in select i from jsonb_array_elements(d->'items') i where i->>'id' in (select jsonb_array_elements_text(b->'itemIds')) loop
      inames := inames||jsonb_build_array(m->'name'); if (m->>'cat') in ('savory','sweet','drink') then food:=food+p_qty; else non:=non+p_qty; end if; end loop;
    n := jsonb_array_length(inames);
  else
    select x into s from jsonb_array_elements(d->'sets') x where x->>'id'=p_lid; mixo:=s->'mix'; n:=0;
    for k,v in select key, value::int from jsonb_each_text(mixo) loop n:=n+v; if k in ('savory','sweet','drink') then food:=food+v; else non:=non+v; end if; end loop;
  end if;
  return jsonb_build_object('name',name,'emoji',d->>'emoji','kind',case p_lk when 'box' then 'box' else p_lk end,'n',n,'mix',mixo,'itemName',iname,'bundleName',bname,'itemNames',inames,'foodN',food,'nonN',non,
    'chain',d->>'chain','type',d->>'type');
end $$;

create or replace function place_order(p_shop bigint, p_lk text, p_lid text, p_qty int) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid := _need_user(); s shops; l listings; today date := _today(); sold int; qr boolean; sat int:=0; pay jsonb; unit int; tot int; o orders; code text; lock_until timestamptz; hv int; cnt int;
begin
  perform _rate(u,'order',12,3600);
  if p_lk not in ('item','bundle','box') or p_lid is null or p_qty is null or p_qty<1 or p_qty>5 or (p_lk='box' and p_qty<>1) then perform _err('BAD_INPUT'); end if;
  select * into s from shops where id=p_shop; if not found then perform _err('NOT_FOUND'); end if;
  if s.owner=u then perform _err('SELF'); end if;
  if _suspended(s) then perform _err('SUSPENDED'); end if;
  if _is_timed(s.type) and (_bkk_hour()<18 or _bkk_hour()>=21 or now()>=_end_ts(today,s.end_hm)) then perform _err('CLOSED'); end if;
  -- serialise buyers of the same listing so two people can never take the last unit
  select * into l from listings where shop_id=p_shop and lk=p_lk and lid=p_lid for update; if not found then perform _err('ENDED'); end if;
  if not l.valid or (l.food and l.d<>today) or (l.exp is not null and l.exp<today) then perform _err('ENDED'); end if;
  perform _sweep(p_shop,null); perform _sweep(null,u);
  -- buyer checks
  if _blocked(u) then perform _err('ACCT_LIMITED'); end if;
  select count(*) into cnt from orders where buyer=u and status in ('pending','review'); if cnt>=3 then perform _err('TOO_MANY_OPEN',cnt); end if;
  select count(*), max(decided_at) into cnt, lock_until from orders where buyer=u and status='cancelled' and cancel_by='timeout' and created_at>now()-interval '1 day';
  if cnt>=3 and lock_until+interval '60 minutes'>now() then perform _err('UNPAID_LOCK',ceil(extract(epoch from (lock_until+interval '60 minutes'-now()))/60)::int); end if;
  -- payment mode
  qr := s.type<>'chain';
  if qr then select jsonb_build_object('pp',coalesce(pp,''),'name',name,'bank',coalesce(bank,''),'acct',coalesce(acct,''),'ts',(extract(epoch from ts)*1000)::bigint) into pay from shop_pay where shop_id=s.id;
             if pay is null then perform _err('NO_PAY'); end if; end if;
  unit := l.price; tot := unit*p_qty;
  if qr and _done_buyers(s.id)<3 then
    if tot>300 then perform _err('NEW_SHOP_CAP',300); end if;
    select count(*) into cnt from orders where shop_id=s.id and status in ('review','paid','pending') and (status<>'pending' or created_at>now()-interval '15 minutes'); if cnt>=5 then perform _err('NEW_SHOP_BUSY'); end if;
  end if;
  -- stock
  sold := _sold(s.id,p_lk,p_lid,l.ep);
  if sold>=l.qty then perform _err('SOLD_OUT'); end if;
  if sold+p_qty>l.qty then perform _err('STOCK_LEFT',l.qty-sold); end if;
  -- unique satang among open orders of this shop
  if qr then
    select x into sat from generate_series(1,99) x where x not in (select o2.sat from orders o2 where o2.shop_id=s.id and (o2.status='review' or (o2.status='pending' and o2.created_at>now()-interval '15 minutes')) and o2.sat>0)
      order by random() limit 1;
    if sat is null then perform _err('SHOP_BUSY'); end if;
  end if;
  code := 'CDE-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
  insert into orders(buyer,shop_id,lk,lid,qty,unit_price,total,worth,sat,status,code,snap,pay)
    values (u,s.id,p_lk,p_lid,p_qty,unit,tot,l.worth*p_qty,coalesce(sat,0),case when qr then 'pending' else 'paid' end,code,_snap(s.doc,p_lk,p_lid,p_qty),pay) returning * into o;
  perform _touch(s.id);
  return _order_json(o,'buyer');
end $$;

create or replace function mark_paid(p_order bigint) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid := _need_user(); o orders;
begin
  perform _rate(u,'claim',20,3600);
  select * into o from orders where id=p_order and buyer=u for update; if not found then perform _err('NOT_FOUND'); end if;
  if o.status<>'pending' then perform _err('STATE'); end if;
  if o.created_at<now()-interval '15 minutes' then perform _sweep(null,u); perform _err('EXPIRED_ORDER'); end if;
  update orders set status='review', claimed_at=now() where id=o.id returning * into o;
  perform _touch(o.shop_id);
  return _order_json(o,'buyer');
end $$;

create or replace function cancel_order(p_order bigint) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid := _need_user(); o orders;
begin
  select * into o from orders where id=p_order and buyer=u for update; if not found then perform _err('NOT_FOUND'); end if;
  if o.status<>'pending' then perform _err('STATE'); end if;
  update orders set status='cancelled', cancel_by='buyer', decided_at=now() where id=o.id returning * into o;
  perform _touch(o.shop_id);
  return _order_json(o,'buyer');
end $$;

-- shop owner: payment received (paid) or rejected (cancelled)
create or replace function owner_decide(p_order bigint, p_to text) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid := _need_user(); o orders;
begin
  if p_to not in ('paid','cancelled') then perform _err('BAD_INPUT'); end if;
  select o2.* into o from orders o2 join shops s on s.id=o2.shop_id where o2.id=p_order and s.owner=u for update of o2; if not found then perform _err('NOT_FOUND'); end if;
  if o.status not in ('pending','review') then perform _err('STATE'); end if;
  if p_to='paid' and o.created_at<now()-interval '15 minutes' and o.status='pending' then perform _err('EXPIRED_ORDER'); end if;
  update orders set status=p_to, decided_at=now(), cancel_by=case when p_to='cancelled' then 'owner' end where id=o.id returning * into o;
  perform _touch(o.shop_id);
  return _order_json(o,'owner');
end $$;

-- shop owner: customer shows the pickup QR / code
create or replace function confirm_pickup(p_shop bigint, p_code text) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid := _need_user(); s shops; o orders; c text := upper(regexp_replace(coalesce(p_code,''),'\s','','g'));
begin
  perform _rate(u,'pickup',120,3600);
  select * into s from shops where id=p_shop and owner=u; if not found then perform _err('NOT_FOUND'); end if;
  if c !~ '^CDE-[A-Z0-9]{4,12}$' then perform _err('BAD_CODE'); end if;
  select * into o from orders where code=c and shop_id=p_shop for update; if not found then perform _err('BAD_CODE'); end if;
  if o.status in ('pending','review') then perform _err('NOT_PAID'); end if;
  if o.status='done' then perform _err('USED'); end if;
  if o.status<>'paid' then perform _err('STATE'); end if;
  if _is_timed(s.type) and now()>_end_ts((o.created_at at time zone 'Asia/Bangkok')::date,s.end_hm)+interval '15 minutes' then
    update orders set status='expired', decided_at=now() where id=o.id; perform _err('EXPIRED_ORDER'); end if;
  update orders set status='done', done_at=now() where id=o.id returning * into o;
  if o.buyer is not null then
    update profiles set kg=kg+round(((o.snap->>'foodN')::int*0.3)::numeric,1), items_saved=items_saved+(o.snap->>'nonN')::int,
           baht_saved=baht_saved+greatest(0,o.worth-o.total), boxes=boxes+1, points=points+15 where uid=o.buyer;
  end if;
  return _order_json(o,'owner');
end $$;

create or replace function report_order(p_order bigint, p_reason text) returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid := _need_user(); o orders;
begin
  if p_reason not in ('noitem','wrong','overcharge','fake') then perform _err('BAD_INPUT'); end if;
  perform _rate(u,'report',10,86400);
  select * into o from orders where id=p_order and buyer=u for update; if not found then perform _err('NOT_FOUND'); end if;
  if o.status not in ('review','paid','done') or o.report is not null then perform _err('STATE'); end if;
  update orders set report=p_reason where id=o.id;
  perform _touch(o.shop_id);
end $$;

create or replace function rate_order(p_order bigint, a int, b int, c int) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid := _need_user(); o orders; sm numeric; ct int;
begin
  if a not between 1 and 5 or b not between 1 and 5 or c not between 1 and 5 then perform _err('BAD_INPUT'); end if;
  select * into o from orders where id=p_order and buyer=u for update; if not found then perform _err('NOT_FOUND'); end if;
  if o.status<>'done' or o.rating is not null then perform _err('STATE'); end if;
  update orders set rating=round(((a+b+c)/3.0)::numeric,1) where id=o.id;
  select coalesce(sum(rating),0), count(*) into sm, ct from orders where shop_id=o.shop_id and rating is not null;
  update shops set n_rated=ct, trust=round(((4.5*5+sm)/(5+ct))::numeric,1), updated_at=now() where id=o.shop_id;     -- 5 "virtual" 4.5-star ratings: one angry review cannot sink a shop
  return jsonb_build_object('ok',true);
end $$;

create or replace function my_orders() returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid := auth.uid(); st profiles;
begin
  if u is null then perform _err('AUTH'); end if;
  perform _sweep(null,u);
  select * into st from profiles where uid=u;
  return jsonb_build_object('now',_now_ms(),'terms',st.terms_version,
    'stats',case when st.uid is null then null else jsonb_build_object('kg',st.kg,'items',st.items_saved,'baht',st.baht_saved,'boxes',st.boxes,'points',st.points) end,
    'orders',coalesce((select jsonb_agg(_order_json(o,'buyer') order by o.id desc) from (select * from orders where buyer=u and created_at>now()-interval '30 days' order by id desc limit 60) o),'[]'));
end $$;

create or replace function shop_orders(p_shop bigint) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid := auth.uid();
begin
  if u is null then perform _err('AUTH'); end if;
  if not exists (select 1 from shops where id=p_shop and owner=u) then perform _err('NOT_FOUND'); end if;
  perform _sweep(p_shop,null);
  return jsonb_build_object('now',_now_ms(),'orders',coalesce((select jsonb_agg(_order_json(o,'owner') order by o.id desc)
    from (select * from orders where shop_id=p_shop and (created_at>now()-interval '2 days' or status in ('pending','review','paid')) order by id desc limit 100) o),'[]'));
end $$;


-- who am I (consent state for the app's start-up check)
create or replace function my_status() returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid := auth.uid(); p profiles; cur text := (select v from cde_cfg where k='terms_version');
begin
  if u is null then perform _err('AUTH'); end if;
  select * into p from profiles where uid=u;
  return jsonb_build_object('terms',coalesce(p.terms_version=cur,false),'version',cur,'banned',coalesce(p.banned,false),'anon',coalesce((auth.jwt()->>'is_anonymous')::boolean,false));
end $$;

-- ---------- privacy rights (PDPA): export / delete ----------
create or replace function export_my_data() returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid := auth.uid();
begin
  if u is null then perform _err('AUTH'); end if;
  return jsonb_build_object('exported_at',now(),'user_id',u,
    'profile',(select to_jsonb(p) from profiles p where uid=u),
    'shops',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('payment',(select to_jsonb(sp) from shop_pay sp where sp.shop_id=s.id))) from shops s where owner=u),'[]'),
    'orders_as_buyer',coalesce((select jsonb_agg(to_jsonb(o)) from orders o where buyer=u),'[]'),
    'transaction_history',coalesce((select jsonb_agg(to_jsonb(l) order by l.order_id) from order_ledger l where l.buyer=u),'[]'),
    'orders_as_shop',coalesce((select jsonb_agg(_order_json(o,'owner')) from orders o join shops s on s.id=o.shop_id where s.owner=u),'[]'));
end $$;

-- deletes the account: shops + payment details removed, own orders anonymised (kept only as non-identifying counts), login removed
create or replace function delete_my_account() returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid := auth.uid();
begin
  if u is null then perform _err('AUTH'); end if;
  if exists (select 1 from orders o join shops s on s.id=o.shop_id where (s.owner=u or o.buyer=u) and o.status in ('review','paid')) then perform _err('STATE'); end if;
  delete from shops where owner=u;
  update orders set buyer=null, pay=null where buyer=u;
  update order_ledger set buyer=null where buyer=u;                -- the money record stays (evidence, 12 months) but is no longer linked to you
  delete from rate_log where uid=u;
  delete from profiles where uid=u;
  delete from auth.users where id=u;
end $$;

-- ---------- retention (data minimisation) ----------
-- raw orders: 30 days after they finish. The compact order_ledger (order no., amount, times, who/what) is kept `ledger_months` (default 12) as evidence for disputes.
-- Eco totals stay in profiles. Called by cde_nightly() (pg_cron below) or by hand.
create or replace function cde_purge() returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare a int; b int; c int; d int;
begin
  delete from orders where status in ('done','cancelled','expired') and created_at<now()-interval '30 days'; get diagnostics a=row_count;     -- raw order (pickup code, payment snapshot) – the ledger keeps the evidence
  delete from orders where created_at<now()-interval '90 days'; get diagnostics b=row_count;                                                  -- anything stuck
  delete from order_ledger where created_at<now()-make_interval(months=>_ledger_months()); get diagnostics d=row_count;
  delete from rate_log where ts<now()-interval '2 days'; get diagnostics c=row_count;
  return jsonb_build_object('orders_short',a,'orders_old',b,'ledger_old',d,'rate_log',c);
end $$;


-- =====================================================================================
-- Evidence ledger, image clean-up, nightly job
-- =====================================================================================
insert into cde_cfg(k,v) values ('ledger_months','12') on conflict do nothing;     -- how long transaction evidence is kept (months)
insert into cde_cfg(k,v) values ('project_url','')     on conflict do nothing;     -- https://<ref>.supabase.co  (needed by the image clean-up, see README)

create or replace function _ledger_months() returns int language sql stable as $$ select greatest(1,coalesce((select v::int from cde_cfg where k='ledger_months'),12)) $$;
create or replace function _order_no(p_id bigint) returns text language sql immutable as $$ select 'CD'||lpad(p_id::text,8,'0') $$;   -- public order number (NOT the secret pickup code)

create or replace function _ledger_sync() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare ref text := coalesce(nullif(new.pay->>'pp',''),nullif(new.pay->>'acct',''));
begin
  insert into order_ledger(order_id,buyer,shop_id,shop_name,title,lk,lid,qty,total,sat,status,created_at,claimed_at,decided_at,done_at,cancel_by,report,pay_name,pay_ref)
  values (new.id,new.buyer,new.shop_id,left(new.snap->'name'->>'th',60),
          left(coalesce(new.snap->'itemName'->>'th',nullif(new.snap->>'bundleName',''),case when new.lk='box' then 'Mystery box' else 'Set' end),60),
          new.lk,new.lid,new.qty,new.total,new.sat,new.status,new.created_at,new.claimed_at,new.decided_at,new.done_at,new.cancel_by,new.report,
          left(new.pay->>'name',40),case when ref is null then null else '…'||right(ref,4) end)
  on conflict (order_id) do update set status=excluded.status,claimed_at=excluded.claimed_at,decided_at=excluded.decided_at,done_at=excluded.done_at,cancel_by=excluded.cancel_by,report=excluded.report;
  return null;
end $$;
drop trigger if exists orders_ledger on orders;
create trigger orders_ledger after insert or update of status,claimed_at,decided_at,done_at,cancel_by,report on orders for each row execute function _ledger_sync();
update orders set status=status where not exists (select 1 from order_ledger l where l.order_id=orders.id);      -- back-fill when upgrading an existing database

-- buyer: my transaction history (evidence when "I paid but got nothing")
create or replace function my_ledger() returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid := auth.uid();
begin
  if u is null then perform _err('AUTH'); end if;
  return jsonb_build_object('months',_ledger_months(),'rows',coalesce((
    select jsonb_agg(jsonb_build_object('no',_order_no(l.order_id),'id',l.order_id,'shop',l.shop_name,'title',l.title,'qty',l.qty,'amount',(l.total*100+l.sat)/100.0,'status',l.status,
             'ts',(extract(epoch from l.created_at)*1000)::bigint,'claimed',(extract(epoch from l.claimed_at)*1000)::bigint,'decided',(extract(epoch from l.decided_at)*1000)::bigint,
             'doneAt',(extract(epoch from l.done_at)*1000)::bigint,'by',l.cancel_by,'report',l.report,'to',l.pay_name,'ref',l.pay_ref) order by l.order_id desc)
    from (select * from order_ledger where buyer=u order by order_id desc limit 200) l),'[]'));
end $$;

-- shop owner: transaction history of one shop (buyers appear only as an anonymous tag)
create or replace function shop_ledger(p_shop bigint) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare u uuid := auth.uid(); salt text := (select v from cde_cfg where k='tag_salt');
begin
  if u is null then perform _err('AUTH'); end if;
  if not exists (select 1 from shops where id=p_shop and owner=u) then perform _err('NOT_FOUND'); end if;
  return jsonb_build_object('months',_ledger_months(),'rows',coalesce((
    select jsonb_agg(jsonb_build_object('no',_order_no(l.order_id),'id',l.order_id,'title',l.title,'qty',l.qty,'amount',(l.total*100+l.sat)/100.0,'status',l.status,
             'ts',(extract(epoch from l.created_at)*1000)::bigint,'claimed',(extract(epoch from l.claimed_at)*1000)::bigint,'decided',(extract(epoch from l.decided_at)*1000)::bigint,
             'doneAt',(extract(epoch from l.done_at)*1000)::bigint,'by',l.cancel_by,'report',l.report,
             'tag','B'||upper(substr(md5(coalesce(l.buyer::text,'x')||l.shop_id::text||salt),1,4))) order by l.order_id desc)
    from (select * from order_ledger where shop_id=p_shop order by order_id desc limit 300) l),'[]'));
end $$;

-- ---------- product images live in Storage; deleting a product must delete its files ----------
create table if not exists image_queue (
  path      text primary key,                          -- object path inside bucket `menu`
  queued_at timestamptz not null default now(),
  req_id    bigint, sent_at timestamptz, tries int not null default 0
);
alter table image_queue enable row level security;
revoke all on image_queue from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname='anon') then revoke all on image_queue from anon; end if;
  if exists (select 1 from pg_roles where rolname='authenticated') then revoke all on image_queue from authenticated; end if;
end $$;

create or replace function _img_paths(d jsonb) returns text[] language sql immutable as $$
  select coalesce(array_agg(distinct p),'{}') from (
    select substring(i->>'img' from '/storage/v1/object/public/menu/(.+)$') p from jsonb_array_elements(coalesce(d->'items','[]'::jsonb)) i) x where p is not null $$;

-- fires whenever a shop's catalogue changes or the shop is deleted (also via account deletion / cascade)
create or replace function _shops_img_trg() returns trigger language plpgsql security definer set search_path=public,pg_temp as $$
declare gone text[];
begin
  if tg_op='DELETE' then gone := _img_paths(old.doc);
  else gone := array(select unnest(_img_paths(old.doc)) except select unnest(_img_paths(new.doc))); end if;
  if coalesce(array_length(gone,1),0)>0 then insert into image_queue(path) select unnest(gone) on conflict do nothing; end if;
  return null;
end $$;
drop trigger if exists shops_img_del on shops;
drop trigger if exists shops_img_upd on shops;
create trigger shops_img_del after delete on shops for each row execute function _shops_img_trg();
create trigger shops_img_upd after update of doc on shops for each row when (old.doc is distinct from new.doc) execute function _shops_img_trg();

-- sends the actual DELETE to the Storage API (pg_net + the service key kept in Supabase Vault; never in the app). Retries; gives up after 5 tries.
create or replace function cde_flush_images() returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare base text := (select v from cde_cfg where k='project_url'); key text; q record; rid bigint; sent int:=0; done int:=0; gave int:=0; kept int:=0;
begin
  with refs as (select distinct unnest(_img_paths(doc)) p from shops) delete from image_queue where path in (select p from refs); get diagnostics kept=row_count;   -- image became referenced again: do not delete
  if to_regclass('net._http_response') is not null then
    execute $q$ delete from image_queue where req_id in (select id from net._http_response where status_code in (200,204,404)) $q$; get diagnostics done=row_count;
    execute $q$ update image_queue set req_id=null where req_id in (select id from net._http_response where status_code not in (200,204,404)) $q$;
  end if;
  update image_queue set req_id=null where req_id is not null and sent_at<now()-interval '1 hour';
  delete from image_queue where tries>=5 and req_id is null; get diagnostics gave=row_count;
  if to_regclass('vault.decrypted_secrets') is not null then execute $q$ select decrypted_secret from vault.decrypted_secrets where name='cde_service_key' $q$ into key; end if;
  if coalesce(base,'')='' or key is null or to_regprocedure('net.http_delete(text,jsonb,jsonb,integer)') is null then
    return jsonb_build_object('queued',(select count(*) from image_queue),'sent',0,'done',done,'gave_up',gave,'configured',false);
  end if;
  for q in select path from image_queue where req_id is null order by queued_at limit 200 loop
    execute 'select net.http_delete($1, ''{}''::jsonb, $2)' into rid using base||'/storage/v1/object/menu/'||q.path, jsonb_build_object('Authorization','Bearer '||key,'apikey',key);
    update image_queue set req_id=rid, sent_at=now(), tries=tries+1 where path=q.path; sent:=sent+1;
  end loop;
  return jsonb_build_object('queued',(select count(*) from image_queue),'sent',sent,'done',done,'gave_up',gave,'configured',true);
end $$;

-- files in the bucket that no shop references any more (failed uploads, old versions) -> queued for deletion
create or replace function _orphan_images() returns int language plpgsql security definer set search_path=public,pg_temp as $$
declare n int:=0;
begin
  if to_regclass('storage.objects') is null then return 0; end if;
  execute $q$ insert into image_queue(path)
      select o.name from storage.objects o
       left join (select distinct unnest(_img_paths(doc)) p from shops) r on r.p=o.name
      where o.bucket_id='menu' and o.created_at<now()-interval '1 day' and r.p is null
      on conflict do nothing $q$;
  get diagnostics n=row_count; return n;
end $$;

-- ---------- nightly clean-up: expired products disappear day by day ----------
-- removes (1) products whose expiry date has passed, (2) food listings of a previous day that are not "standing menu" items.
-- Bundles that contain a removed item go too. Their images are queued for deletion by the trigger above.
create or replace function _purge_products() returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare today date:=_today(); s record; ri text[]; rb text[]; rs text[]; d2 jsonb; ni int:=0; nb int:=0; ns int:=0; ns_shops int:=0; cnt int;
begin
  for s in select sh.id, sh.doc from shops sh where exists (select 1 from listings l where l.shop_id=sh.id and ((l.food and l.d<today and not l.auto) or (l.exp is not null and l.exp<today))) loop
    select coalesce(array_agg(lid) filter (where lk='item'),'{}'), coalesce(array_agg(lid) filter (where lk='bundle'),'{}'), coalesce(array_agg(lid) filter (where lk='box'),'{}')
      into ri, rb, rs from listings where shop_id=s.id and ((food and d<today and not auto) or (exp is not null and exp<today));
    d2 := jsonb_set(s.doc,'{items}',coalesce((select jsonb_agg(i) from jsonb_array_elements(s.doc->'items') i where not (i->>'id'=any(ri))),'[]'::jsonb));
    d2 := jsonb_set(d2,'{bundles}',coalesce((select jsonb_agg(b) from jsonb_array_elements(s.doc->'bundles') b
            where not (b->>'id'=any(rb)) and not exists (select 1 from jsonb_array_elements_text(b->'itemIds') x where x=any(ri))),'[]'::jsonb));
    d2 := jsonb_set(d2,'{sets}',coalesce((select jsonb_agg(x) from jsonb_array_elements(s.doc->'sets') x where not (x->>'id'=any(rs))),'[]'::jsonb));
    ni := ni + jsonb_array_length(s.doc->'items') - jsonb_array_length(d2->'items');
    nb := nb + jsonb_array_length(s.doc->'bundles') - jsonb_array_length(d2->'bundles');
    ns := ns + jsonb_array_length(s.doc->'sets') - jsonb_array_length(d2->'sets');
    update shops set doc=d2, updated_at=now() where id=s.id;                                   -- fires the image trigger
    delete from listings l where l.shop_id=s.id and not exists (select 1 from _listing_rows(d2) n where n.lk=l.lk and n.lid=l.lid);
    ns_shops := ns_shops+1;
  end loop;
  return jsonb_build_object('shops',ns_shops,'items',ni,'bundles',nb,'boxes',ns);
end $$;

create or replace function cde_nightly() returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare a jsonb; b jsonb; c int; f jsonb;
begin
  a := _purge_products(); b := cde_purge(); c := _orphan_images(); f := cde_flush_images();
  return jsonb_build_object('ran_at',now(),'products',a,'purge',b,'orphan_images_queued',c,'images',f);
end $$;

-- admin only: how full is the free plan?   select cde_usage();
create or replace function cde_usage() returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare db_mb numeric := round(pg_database_size(current_database())/1048576.0,1); st_mb numeric := 0;
begin
  if to_regclass('storage.objects') is not null then execute $q$ select coalesce(round(sum((metadata->>'size')::bigint)/1048576.0,1),0) from storage.objects where bucket_id='menu' $q$ into st_mb; end if;
  return jsonb_build_object('database_mb',db_mb,'database_pct_of_500mb',round(db_mb/5.0,1),'storage_mb',st_mb,'storage_pct_of_1gb',round(st_mb/10.24,1),
    'shops',(select count(*) from shops),'raw_orders',(select count(*) from orders),'ledger_rows',(select count(*) from order_ledger),'image_queue',(select count(*) from image_queue),
    'ledger_months',_ledger_months());
end $$;

-- ---------- permissions: only the API functions are callable by signed-in users ----------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid=p.pronamespace
            where n.nspname='public' and p.proname in ('_err','_now_ms','_today','_bkk_hour','_is_timed','_end_ts','_txt','_has_contact','_bad_claim','_nm','_date_or_null','_int','_ms','_listing_rows','_need_user','_rate',
              '_done_buyers','_flagged','_suspended','_blocked','_sold','_touch','_sweep','_img_ok','_clean_doc','_shop_json','_order_json','_snap','cde_purge','_ledger_months','_order_no','_ledger_sync','_img_paths','_shops_img_trg','cde_flush_images','_orphan_images','_purge_products','cde_nightly','cde_usage',
              'accept_terms','my_status','save_shop','delete_shop','list_shops','get_shop','my_shops','place_order','mark_paid','cancel_order','owner_decide','confirm_pickup','report_order','rate_order','my_orders','shop_orders','export_my_data','delete_my_account','my_ledger','shop_ledger')
  loop
    execute format('revoke all on function %s from public',f.sig);
    if exists (select 1 from pg_roles where rolname='anon') then execute format('revoke all on function %s from anon',f.sig); end if;
    if f.proname in ('list_shops','get_shop') and exists (select 1 from pg_roles where rolname='anon') then execute format('grant execute on function %s to anon',f.sig); end if;
    if f.proname in ('accept_terms','my_status','save_shop','delete_shop','list_shops','get_shop','my_shops','place_order','mark_paid','cancel_order','owner_decide','confirm_pickup','report_order','rate_order','my_orders','shop_orders','export_my_data','delete_my_account','my_ledger','shop_ledger')
       and exists (select 1 from pg_roles where rolname='authenticated') then
      execute format('grant execute on function %s to authenticated',f.sig);
    end if;
  end loop;
end $$;

-- keep-alive ping (called by the GitHub Action so the free project is not paused for inactivity)
create or replace function cde_ping() returns int language sql stable as $$ select 1 $$;
do $$ begin
  if exists (select 1 from pg_roles where rolname='anon') then grant execute on function cde_ping() to anon, authenticated; end if;
end $$;

-- ---------- image bucket (Supabase Storage) ----------
do $$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
      values ('menu','menu',true,204800,array['image/jpeg','image/webp','image/png'])
      on conflict (id) do update set public=true,file_size_limit=204800,allowed_mime_types=array['image/jpeg','image/webp','image/png'];
    drop policy if exists "menu write own" on storage.objects;
    drop policy if exists "menu update own" on storage.objects;
    drop policy if exists "menu delete own" on storage.objects;
    create policy "menu write own"  on storage.objects for insert to authenticated with check (bucket_id='menu' and (storage.foldername(name))[1]=auth.uid()::text and coalesce((auth.jwt()->>'is_anonymous')::boolean,false)=false);
    create policy "menu update own" on storage.objects for update to authenticated using (bucket_id='menu' and (storage.foldername(name))[1]=auth.uid()::text);
    create policy "menu delete own" on storage.objects for delete to authenticated using (bucket_id='menu' and (storage.foldername(name))[1]=auth.uid()::text);
  end if;
end $$;

-- ---------- schedules (pg_cron; skipped silently if the extension is not available) ----------
-- 17:00 UTC = 00:00 Bangkok: nightly clean-up.  Every 15 min: send queued image deletions to Storage.
do $$
begin
  if exists (select 1 from pg_available_extensions where name='pg_net') then create extension if not exists pg_net; end if;
  if exists (select 1 from pg_available_extensions where name='pg_cron') then
    create extension if not exists pg_cron;
    begin perform cron.unschedule('cde-purge'); exception when others then null; end;
    perform cron.schedule('cde-nightly','0 17 * * *','select public.cde_nightly()');
    perform cron.schedule('cde-flush','*/15 * * * *','select public.cde_flush_images()');
  end if;
exception when others then raise notice 'schedules not created: %', sqlerrm;
end $$;

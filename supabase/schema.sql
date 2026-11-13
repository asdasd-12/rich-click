-- Rich Click: Supabase foundation
-- Run once in Supabase SQL Editor. All currency and item transfers are server-side RPCs.
create extension if not exists pgcrypto;

create table if not exists public.relic_catalog (
  id text primary key,
  name text not null,
  rarity text not null check (rarity in ('common','rare','epic','legendary')),
  base_value bigint not null check (base_value > 0)
);

insert into public.relic_catalog(id,name,rarity,base_value) values
('mona','Мона Лиза','common',12000),
('venus','Венера Милосская','common',18000),
('victory','Ника Самофракийская','common',22000),
('thinker','Мыслитель','rare',65000),
('pearl','Девушка с жемчужной серёжкой','rare',82000),
('starry','Звёздная ночь','rare',95000),
('lace','Кружевница','epic',240000),
('astronomer','Астроном','epic',320000),
('scribe','Сидящий писец','epic',380000),
('liberty','Свобода, ведущая народ','legendary',1100000),
('psyche','Амур и Психея','legendary',1600000),
('hammurabi','Стела Хаммурапи','legendary',2200000)
on conflict (id) do update set name=excluded.name, rarity=excluded.rarity, base_value=excluded.base_value;

create table if not exists public.player_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  nickname text not null default 'Игрок' check (char_length(nickname) between 1 and 18),
  created_at timestamptz not null default now()
);

create table if not exists public.player_wallets (
  user_id uuid primary key references auth.users(id) on delete cascade,
  balance bigint not null default 0 check (balance >= 0),
  lifetime_earned bigint not null default 0 check (lifetime_earned >= 0),
  updated_at timestamptz not null default now()
);

create table if not exists public.player_relics (
  user_id uuid not null references auth.users(id) on delete cascade,
  relic_id text not null references public.relic_catalog(id),
  owned_count integer not null default 0 check (owned_count >= 0),
  purchased_count integer not null default 0 check (purchased_count between 0 and 3),
  listed_count integer not null default 0 check (listed_count >= 0 and listed_count <= owned_count),
  primary key(user_id,relic_id)
);

create table if not exists public.market_listings (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references auth.users(id) on delete cascade,
  relic_id text not null references public.relic_catalog(id),
  quantity integer not null check (quantity > 0),
  unit_price bigint not null check (unit_price > 0),
  created_at timestamptz not null default now(),
  status text not null default 'active' check (status in ('active','sold','cancelled'))
);

create index if not exists market_active_created_idx on public.market_listings(status,created_at desc);
create index if not exists market_active_price_idx on public.market_listings(status,unit_price asc);

create or replace function public.on_auth_user_created()
returns trigger language plpgsql security definer set search_path=public
as $$
begin
  insert into public.player_profiles(user_id,nickname)
  values(new.id, coalesce(nullif(left(new.raw_user_meta_data->>'user_name',18),''),'Игрок'))
  on conflict(user_id) do nothing;
  insert into public.player_wallets(user_id) values(new.id)
  on conflict(user_id) do nothing;
  return new;
end;
$$;

drop trigger if exists auth_user_created_rich_click on auth.users;
create trigger auth_user_created_rich_click after insert on auth.users
for each row execute procedure public.on_auth_user_created();

alter table public.player_profiles enable row level security;
alter table public.player_wallets enable row level security;
alter table public.player_relics enable row level security;
alter table public.market_listings enable row level security;
alter table public.relic_catalog enable row level security;

drop policy if exists "Profiles are public" on public.player_profiles;
create policy "Profiles are public" on public.player_profiles for select using (true);
drop policy if exists "Players update own nickname" on public.player_profiles;
create policy "Players update own nickname" on public.player_profiles for update using (auth.uid()=user_id) with check (auth.uid()=user_id);
drop policy if exists "Wallet owner can read" on public.player_wallets;
create policy "Wallet owner can read" on public.player_wallets for select using (auth.uid()=user_id);
drop policy if exists "Relic inventory is public" on public.player_relics;
create policy "Relic inventory is public" on public.player_relics for select using (true);
drop policy if exists "Catalog is public" on public.relic_catalog;
create policy "Catalog is public" on public.relic_catalog for select using (true);
drop policy if exists "Active listings are public" on public.market_listings;
create policy "Active listings are public" on public.market_listings for select using (status='active' or auth.uid()=seller_id);

-- No client-side INSERT/UPDATE/DELETE policies for wallets, inventory or listings.
-- Mutations below execute atomically and validate ownership/caps on the database.

create or replace function public.purchase_relic(p_relic_id text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare uid uuid := auth.uid(); item public.relic_catalog%rowtype; wallet public.player_wallets%rowtype; inv public.player_relics%rowtype;
begin
  if uid is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into item from public.relic_catalog where id=p_relic_id;
  if not found then raise exception 'RELIC_NOT_FOUND'; end if;
  select * into wallet from public.player_wallets where user_id=uid for update;
  if wallet.balance < item.base_value then raise exception 'NOT_ENOUGH_BALANCE'; end if;
  insert into public.player_relics(user_id,relic_id,owned_count,purchased_count)
  values(uid,p_relic_id,0,0) on conflict do nothing;
  select * into inv from public.player_relics where user_id=uid and relic_id=p_relic_id for update;
  if inv.purchased_count >= 3 then raise exception 'PURCHASE_LIMIT_REACHED'; end if;
  update public.player_wallets set balance=balance-item.base_value, updated_at=now() where user_id=uid;
  update public.player_relics set owned_count=owned_count+1,purchased_count=purchased_count+1
  where user_id=uid and relic_id=p_relic_id;
  return jsonb_build_object('success',true,'price',item.base_value,'remaining_balance',wallet.balance-item.base_value);
end;
$$;

create or replace function public.create_relic_listing(p_relic_id text,p_quantity integer,p_unit_price bigint)
returns uuid language plpgsql security definer set search_path=public
as $$
declare uid uuid := auth.uid(); inv public.player_relics%rowtype; new_id uuid;
begin
  if uid is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_quantity is null or p_quantity<1 or p_unit_price is null or p_unit_price<1 then raise exception 'INVALID_LISTING'; end if;
  select * into inv from public.player_relics where user_id=uid and relic_id=p_relic_id for update;
  if not found or inv.owned_count-inv.listed_count<p_quantity then raise exception 'NOT_ENOUGH_UNLISTED_ITEMS'; end if;
  update public.player_relics set listed_count=listed_count+p_quantity where user_id=uid and relic_id=p_relic_id;
  insert into public.market_listings(seller_id,relic_id,quantity,unit_price)
  values(uid,p_relic_id,p_quantity,p_unit_price) returning id into new_id;
  return new_id;
end;
$$;

create or replace function public.buy_relic_listing(p_listing_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare buyer uuid := auth.uid(); listing public.market_listings%rowtype; buyer_wallet public.player_wallets%rowtype;
begin
  if buyer is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into listing from public.market_listings where id=p_listing_id and status='active' for update;
  if not found then raise exception 'LISTING_UNAVAILABLE'; end if;
  if listing.seller_id=buyer then raise exception 'CANNOT_BUY_OWN_LISTING'; end if;
  select * into buyer_wallet from public.player_wallets where user_id=buyer for update;
  if buyer_wallet.balance < listing.unit_price*listing.quantity then raise exception 'NOT_ENOUGH_BALANCE'; end if;
  -- All acquisitions count toward the lifetime cap of three copies per relic type.
  insert into public.player_relics(user_id,relic_id,owned_count,purchased_count)
  values(buyer,listing.relic_id,0,0) on conflict do nothing;
  perform 1 from public.player_relics where user_id=buyer and relic_id=listing.relic_id for update;
  if (select purchased_count from public.player_relics where user_id=buyer and relic_id=listing.relic_id)+listing.quantity>3 then
    raise exception 'PURCHASE_LIMIT_REACHED';
  end if;
  update public.player_wallets set balance=balance-listing.unit_price*listing.quantity,updated_at=now() where user_id=buyer;
  update public.player_wallets set balance=balance+listing.unit_price*listing.quantity,updated_at=now() where user_id=listing.seller_id;
  insert into public.player_relics(user_id,relic_id,owned_count,purchased_count)
  values(buyer,listing.relic_id,listing.quantity,0)
  on conflict(user_id,relic_id) do update set owned_count=public.player_relics.owned_count+excluded.owned_count,
    purchased_count=public.player_relics.purchased_count+excluded.owned_count;
  update public.player_relics set owned_count=owned_count-listing.quantity,listed_count=listed_count-listing.quantity
  where user_id=listing.seller_id and relic_id=listing.relic_id;
  update public.market_listings set status='sold' where id=p_listing_id;
  return jsonb_build_object('success',true,'total',listing.unit_price*listing.quantity);
end;
$$;

create or replace function public.cancel_relic_listing(p_listing_id uuid)
returns boolean language plpgsql security definer set search_path=public
as $$
declare uid uuid := auth.uid(); listing public.market_listings%rowtype;
begin
  if uid is null then raise exception 'AUTH_REQUIRED'; end if;
  select * into listing from public.market_listings where id=p_listing_id and seller_id=uid and status='active' for update;
  if not found then raise exception 'LISTING_UNAVAILABLE'; end if;
  update public.player_relics set listed_count=listed_count-listing.quantity
  where user_id=uid and relic_id=listing.relic_id;
  update public.market_listings set status='cancelled' where id=p_listing_id;
  return true;
end;
$$;

create or replace view public.balance_leaderboard as
select p.user_id,p.nickname,w.balance,
 row_number() over(order by w.balance desc,p.created_at asc) as rank
from public.player_profiles p join public.player_wallets w using(user_id);

create or replace view public.relic_value_leaderboard as
select p.user_id,p.nickname,
 coalesce(sum(r.owned_count*c.base_value),0)::bigint as collection_value,
 row_number() over(order by coalesce(sum(r.owned_count*c.base_value),0) desc,p.created_at asc) as rank
from public.player_profiles p
left join public.player_relics r on r.user_id=p.user_id
left join public.relic_catalog c on c.id=r.relic_id
group by p.user_id,p.nickname,p.created_at;

grant select on public.player_profiles,public.player_relics,public.relic_catalog,public.market_listings,public.balance_leaderboard,public.relic_value_leaderboard to anon,authenticated;
grant select on public.player_wallets to authenticated;
grant execute on function public.purchase_relic(text) to authenticated;
grant execute on function public.create_relic_listing(text,integer,bigint) to authenticated;
grant execute on function public.buy_relic_listing(uuid) to authenticated;
grant execute on function public.cancel_relic_listing(uuid) to authenticated;

revoke all on function public.purchase_relic(text) from public, anon;
revoke all on function public.create_relic_listing(text,integer,bigint) from public, anon;
revoke all on function public.buy_relic_listing(uuid) from public, anon;
revoke all on function public.cancel_relic_listing(uuid) from public, anon;

-- Server-side click earnings. A small cooldown and per-click cap reduce trivial client-side abuse.
alter table public.player_wallets add column if not exists last_click_at timestamptz;
create or replace function public.earn_click(p_amount bigint)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare uid uuid := auth.uid(); w public.player_wallets%rowtype; reward bigint;
begin
  if uid is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_amount is null or p_amount<1 then raise exception 'INVALID_REWARD'; end if;
  select * into w from public.player_wallets where user_id=uid for update;
  if not found then raise exception 'WALLET_NOT_FOUND'; end if;
  if w.last_click_at is not null and w.last_click_at > now() - interval '150 milliseconds' then
    raise exception 'CLICK_TOO_FAST';
  end if;
  reward := least(p_amount,100);
  update public.player_wallets
    set balance=balance+reward,
        lifetime_earned=lifetime_earned+reward,
        last_click_at=now(),
        updated_at=now()
    where user_id=uid
    returning * into w;
  return jsonb_build_object('balance',w.balance,'earned',w.lifetime_earned,'reward',reward);
end;
$$;
grant execute on function public.earn_click(bigint) to authenticated;
revoke all on function public.earn_click(bigint) from public, anon;


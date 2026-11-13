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
('hammurabi','Стела Хаммурапи','legendary',2200000),
('david','Давид','common',26000),('thinker2','Поэт','common',31000),('waterlilies','Кувшинки','rare',115000),('scream','Крик','rare',135000),('guernica','Герника','rare',155000),('nightwatch','Ночной дозор','epic',430000),('creation','Сотворение Адама','epic',520000),('birthvenus','Рождение Венеры','epic',610000),('sunflowers','Подсолнухи','epic',720000),('girlred','Портрет дамы в красном','legendary',2600000),('terracotta','Терракотовая армия','legendary',3100000),('mask','Золотая погребальная маска','legendary',4200000),('crown','Императорская корона','legendary',5800000),
('apollo','Аполлон Бельведерский','rare',185000),
('discobolus','Дискобол','rare',205000),
('laocoon','Лаокоон и его сыновья','epic',850000),
('mona2','Мадонна в скалах','epic',920000),
('lastsupper','Тайная вечеря','epic',1050000),
('persistence','Постоянство памяти','epic',1250000),
('american_gothic','Американская готика','epic',1450000),
('girl_vermeer','Молодая женщина с кувшином','epic',1650000),
('ivory_chess','Императорские шахматы','legendary',6500000),
('jade_dragon','Нефритовый дракон','legendary',7800000),
('pharaoh_mask','Маска фараона','legendary',9200000),
('royal_scepter','Королевский скипетр','legendary',11500000),
('blue_diamond','Голубой бриллиант','legendary',14500000),
('golden_fleece','Золотое руно','legendary',18500000),
('ancient_map','Карта неизвестных земель','legendary',22000000)
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



-- Persistent assets and server-calculated passive income.
create table if not exists public.asset_catalog (asset_key text primary key,category text not null check(category in ('business','property','cars')),name text not null,price bigint not null check(price>0),income_per_second bigint not null default 0 check(income_per_second>=0));
insert into public.asset_catalog(asset_key,category,name,price,income_per_second) values
('business:0','business','Кофейня',250,3),('business:1','business','Бургерная',1200,18),('business:2','business','Супермаркет',6500,95),('business:3','business','Отель',28000,430),('business:4','business','Завод',145000,2300),('business:5','business','Космопорт',900000,16000),
('property:0','property','Студия',80000,650),('property:1','property','Пентхаус',650000,5200),('property:2','property','Жилой комплекс',4200000,36000),('property:3','property','Частный остров',32000000,310000),
('cars:0','cars','Merchedes Binz C-Class',12000,0),('cars:1','cars','Porshe 911 Carrera',95000,0),('cars:2','cars','Bavarian M5',180000,0),('cars:3','cars','Lamborgini Aventor',850000,0),('cars:4','cars','Ferrari SF90 Stradale',2400000,0),
('business:6','business','Сеть пиццерий',4200000,78000),
('business:7','business','Нефтехранилище',18000000,360000),
('business:8','business','Частный банк',85000000,1850000),
('business:9','business','Телеком-компания',360000000,8200000),
('business:10','business','Космическая корпорация',1500000000,38000000),
('business:11','business','Энергетический холдинг',6500000000,190000000),
('property:4','property','Торговый центр',145000000,1450000),
('property:5','property','Небоскрёб',620000000,7200000),
('property:6','property','Курортный комплекс',2400000000,31000000),
('property:7','property','Городской квартал',9500000000,145000000),
('cars:5','cars','Tesla Model S Plaid',4200000,0),
('cars:6','cars','Lamborghini Urus',7800000,0),
('cars:7','cars','Bentley Continental GT',14500000,0),
('cars:8','cars','Rolls-Royce Ghost',28000000,0),
('cars:9','cars','McLaren 750S',42000000,0),
('cars:10','cars','Bugatti Chiron',180000000,0),
('cars:11','cars','Pagani Huayra',320000000,0),
('cars:12','cars','Koenigsegg Jesko',520000000,0),
('business:12','business','Морской порт',28000000000,850000000),
('business:13','business','Нефтяная корпорация',95000000000,3200000000),
('business:14','business','Строительный холдинг',280000000000,9800000000),
('business:15','business','Глобальный маркетплейс',850000000000,32000000000),
('business:16','business','ИИ-лаборатория',2400000000000,105000000000),
('business:17','business','Биотех-корпорация',7500000000000,360000000000),
('business:18','business','Международный конгломерат',24000000000000,1250000000000),
('business:19','business','Орбитальная империя',85000000000000,5200000000000),
('property:8','property','Исторический замок',28000000000,420000000),
('property:9','property','Архипелаг вилл',95000000000,1800000000),
('property:10','property','Развлекательный квартал',320000000000,7200000000),
('property:11','property','Национальная арена',980000000000,26000000000),
('property:12','property','Умный мегаполис',4800000000000,145000000000),
('property:13','property','Лунная база',22000000000000,820000000000),
('cars:13','cars','Mercedes-AMG G 63',68000000,0),
('cars:14','cars','Porsche 918 Spyder',125000000,0),
('cars:15','cars','Ferrari LaFerrari',210000000,0),
('cars:16','cars','Aston Martin Valkyrie',265000000,0),
('cars:17','cars','Rimac Nevera',310000000,0),
('cars:18','cars','Hennessey Venom F5',390000000,0),
('cars:19','cars','Bugatti Bolide',480000000,0),
('cars:20','cars','Pagani Utopia',560000000,0),
('cars:21','cars','Ferrari Daytona SP3',720000000,0),
('cars:22','cars','Mercedes-Benz Project One',950000000,0)
on conflict(asset_key) do update set category=excluded.category,name=excluded.name,price=excluded.price,income_per_second=excluded.income_per_second;
create table if not exists public.player_assets(user_id uuid not null references auth.users(id) on delete cascade,asset_key text not null references public.asset_catalog(asset_key),quantity integer not null default 0 check(quantity>=0),primary key(user_id,asset_key));
alter table public.player_assets enable row level security;
drop policy if exists "Players read own assets" on public.player_assets;
create policy "Players read own assets" on public.player_assets for select using(auth.uid()=user_id);
alter table public.player_wallets add column if not exists last_income_at timestamptz not null default now();
create or replace function public.purchase_asset(p_asset_key text) returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); a public.asset_catalog%rowtype; w public.player_wallets%rowtype; qty integer;
begin if uid is null then raise exception 'AUTH_REQUIRED'; end if; select * into a from public.asset_catalog where asset_key=p_asset_key; if not found then raise exception 'ASSET_NOT_FOUND'; end if; select * into w from public.player_wallets where user_id=uid for update; if not found then raise exception 'WALLET_NOT_FOUND'; end if; if w.balance<a.price then raise exception 'NOT_ENOUGH_BALANCE'; end if; update public.player_wallets set balance=balance-a.price,updated_at=now() where user_id=uid; insert into public.player_assets(user_id,asset_key,quantity) values(uid,p_asset_key,1) on conflict(user_id,asset_key) do update set quantity=public.player_assets.quantity+1 returning quantity into qty; return jsonb_build_object('success',true,'balance',w.balance-a.price,'quantity',qty); end; $$;
create or replace function public.collect_passive_income() returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); w public.player_wallets%rowtype; inc bigint; elapsed numeric; reward bigint;
begin if uid is null then raise exception 'AUTH_REQUIRED'; end if; select * into w from public.player_wallets where user_id=uid for update; if not found then raise exception 'WALLET_NOT_FOUND'; end if; select coalesce(sum(a.income_per_second*p.quantity),0)::bigint into inc from public.player_assets p join public.asset_catalog a using(asset_key) where p.user_id=uid; elapsed:=greatest(0,least(extract(epoch from(now()-w.last_income_at)),86400)); reward:=floor(elapsed*inc)::bigint; update public.player_wallets set balance=balance+reward,lifetime_earned=lifetime_earned+reward,last_income_at=now(),updated_at=now() where user_id=uid returning * into w; return jsonb_build_object('balance',w.balance,'earned',w.lifetime_earned,'income',inc,'reward',reward); end; $$;
grant select on public.asset_catalog to anon,authenticated; grant select on public.player_assets to authenticated; grant execute on function public.purchase_asset(text) to authenticated; grant execute on function public.collect_passive_income() to authenticated; revoke all on function public.purchase_asset(text) from public,anon; revoke all on function public.collect_passive_income() from public,anon;


-- Admin controls for issuing virtual currency.
-- After the first GitHub login, copy your UUID from Authentication -> Users
-- and run: insert into public.rich_click_admins(user_id) values ('YOUR-AUTH-USER-UUID');
create table if not exists public.rich_click_admins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.rich_click_admins enable row level security;

create or replace function public.is_rich_click_admin()
returns boolean language sql stable security definer set search_path=public
as $$
  select exists(select 1 from public.rich_click_admins where user_id=auth.uid());
$$;

create or replace function public.admin_search_players(p_query text)
returns table(user_id uuid,nickname text,balance bigint)
language plpgsql stable security definer set search_path=public
as $$
begin
  if auth.uid() is null or not exists(select 1 from public.rich_click_admins where user_id=auth.uid()) then
    raise exception 'ADMIN_REQUIRED';
  end if;
  if p_query is null or char_length(trim(p_query))<2 then
    raise exception 'QUERY_TOO_SHORT';
  end if;
  return query
    select p.user_id as user_id,p.nickname as nickname,w.balance as balance
    from public.player_profiles as p
    join public.player_wallets as w on w.user_id = p.user_id
    where p.nickname ilike '%' || left(trim(p_query),18) || '%'
    order by p.nickname
    limit 20;
end;
$$;

create or replace function public.admin_grant_money(p_user_id uuid,p_amount bigint)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare new_balance bigint;
begin
  if auth.uid() is null or not exists(select 1 from public.rich_click_admins where user_id=auth.uid()) then
    raise exception 'ADMIN_REQUIRED';
  end if;
  if p_amount is null or p_amount<1 or p_amount>1000000000000000 then
    raise exception 'INVALID_AMOUNT';
  end if;
  update public.player_wallets
    set balance=balance+p_amount,
        lifetime_earned=lifetime_earned+p_amount,
        updated_at=now()
    where user_id=p_user_id
    returning balance into new_balance;
  if not found then raise exception 'PLAYER_WALLET_NOT_FOUND'; end if;
  return jsonb_build_object('success',true,'balance',new_balance,'granted',p_amount);
end;
$$;

grant execute on function public.is_rich_click_admin() to anon,authenticated;
grant execute on function public.admin_search_players(text) to authenticated;
grant execute on function public.admin_grant_money(uuid,bigint) to authenticated;
revoke all on function public.admin_search_players(text) from public,anon;
revoke all on function public.admin_grant_money(uuid,bigint) from public,anon;


-- Full game administration: balances, global announcements, economy settings,
-- relic inventory management, and an auditable admin action log.
create table if not exists public.game_settings (
  id boolean primary key default true check(id),
  click_multiplier numeric not null default 1 check(click_multiplier between 0 and 1000),
  passive_multiplier numeric not null default 1 check(passive_multiplier between 0 and 1000),
  maintenance_mode boolean not null default false,
  updated_at timestamptz not null default now()
);
insert into public.game_settings(id) values(true) on conflict(id) do nothing;
alter table public.game_settings enable row level security;
drop policy if exists "Game settings readable" on public.game_settings;
create policy "Game settings readable" on public.game_settings for select using(true);

create table if not exists public.game_announcements (
  id bigserial primary key,
  title text not null check(char_length(title) between 1 and 80),
  message text not null check(char_length(message) between 1 and 500),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id)
);
alter table public.game_announcements enable row level security;
drop policy if exists "Active game announcement readable" on public.game_announcements;
create policy "Active game announcement readable" on public.game_announcements for select using(active=true);

create table if not exists public.admin_action_logs (
  id bigserial primary key,
  admin_id uuid references auth.users(id),
  action text not null,
  details text not null default '',
  created_at timestamptz not null default now()
);
alter table public.admin_action_logs enable row level security;

create or replace function public.admin_log(p_action text,p_details text)
returns void language sql security definer set search_path=public
as $$ insert into public.admin_action_logs(admin_id,action,details) values(auth.uid(),left(p_action,80),left(p_details,500)); $$;

create or replace function public.admin_change_player_balance(p_user_id uuid,p_amount bigint,p_mode text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare new_balance bigint;
begin
 if not exists(select 1 from public.rich_click_admins where user_id=auth.uid()) then raise exception 'ADMIN_REQUIRED'; end if;
 if p_amount is null or p_amount<0 or p_amount>1000000000000000 or p_mode not in ('add','remove','set') then raise exception 'INVALID_INPUT'; end if;
 update public.player_wallets set balance=case p_mode when 'add' then least(balance+p_amount,9000000000000000000::bigint) when 'remove' then greatest(0,balance-p_amount) else p_amount end,updated_at=now()
 where user_id=p_user_id returning balance into new_balance;
 if not found then raise exception 'PLAYER_NOT_FOUND'; end if;
 perform public.admin_log('player_balance',p_mode||' '||p_amount||' user='||p_user_id);
 return jsonb_build_object('balance',new_balance);
end $$;

create or replace function public.admin_adjust_all_balances(p_mode text,p_amount bigint)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare affected integer; delta numeric;
begin
 if not exists(select 1 from public.rich_click_admins where user_id=auth.uid()) then raise exception 'ADMIN_REQUIRED'; end if;
 if p_mode not in ('add','remove','reset') or p_amount is null or p_amount<0 or p_amount>1000000000000000 then raise exception 'INVALID_INPUT'; end if;
 if p_mode='add' then
  update public.player_wallets set balance=least(balance+p_amount,9000000000000000000::bigint),lifetime_earned=lifetime_earned+p_amount,updated_at=now();
 elsif p_mode='remove' then
  update public.player_wallets set balance=greatest(0,balance-p_amount),updated_at=now();
 else
  update public.player_wallets set balance=0,updated_at=now();
 end if;
 get diagnostics affected=row_count;
 delta:=case p_mode when 'add' then p_amount::numeric*affected when 'remove' then -(p_amount::numeric*affected) else 0 end;
 perform public.admin_log('global_balance',p_mode||' amount='||p_amount||' affected='||affected);
 return jsonb_build_object('affected',affected,'total_delta',delta);
end $$;

create or replace function public.admin_publish_announcement(p_title text,p_message text)
returns bigint language plpgsql security definer set search_path=public
as $$
declare new_id bigint;
begin
 if not exists(select 1 from public.rich_click_admins where user_id=auth.uid()) then raise exception 'ADMIN_REQUIRED'; end if;
 if p_title is null or char_length(trim(p_title))<1 or char_length(p_title)>80 or p_message is null or char_length(trim(p_message))<1 or char_length(p_message)>500 then raise exception 'INVALID_ANNOUNCEMENT'; end if;
 update public.game_announcements set active=false where active=true;
 insert into public.game_announcements(title,message,created_by) values(trim(p_title),trim(p_message),auth.uid()) returning id into new_id;
 perform public.admin_log('announcement','published id='||new_id);
 return new_id;
end $$;
create or replace function public.admin_clear_announcement()
returns boolean language plpgsql security definer set search_path=public
as $$ begin
 if not exists(select 1 from public.rich_click_admins where user_id=auth.uid()) then raise exception 'ADMIN_REQUIRED'; end if;
 update public.game_announcements set active=false where active=true;
 perform public.admin_log('announcement','cleared');
 return true;
end $$;

create or replace function public.admin_get_settings()
returns jsonb language plpgsql stable security definer set search_path=public
as $$ declare x public.game_settings%rowtype; begin
 if not exists(select 1 from public.rich_click_admins where user_id=auth.uid()) then raise exception 'ADMIN_REQUIRED'; end if;
 select * into x from public.game_settings where id=true;
 return jsonb_build_object('click_multiplier',x.click_multiplier,'passive_multiplier',x.passive_multiplier,'maintenance_mode',x.maintenance_mode);
end $$;
create or replace function public.admin_update_settings(p_click_multiplier numeric,p_passive_multiplier numeric,p_maintenance_mode boolean)
returns boolean language plpgsql security definer set search_path=public
as $$ begin
 if not exists(select 1 from public.rich_click_admins where user_id=auth.uid()) then raise exception 'ADMIN_REQUIRED'; end if;
 if p_click_multiplier not between 0 and 1000 or p_passive_multiplier not between 0 and 1000 then raise exception 'INVALID_MULTIPLIER'; end if;
 update public.game_settings set click_multiplier=p_click_multiplier,passive_multiplier=p_passive_multiplier,maintenance_mode=coalesce(p_maintenance_mode,false),updated_at=now() where id=true;
 perform public.admin_log('game_settings','click='||p_click_multiplier||' passive='||p_passive_multiplier||' maintenance='||p_maintenance_mode);
 return true;
end $$;

create or replace function public.admin_manage_relic(p_user_id uuid,p_relic_id text,p_quantity integer,p_mode text)
returns jsonb language plpgsql security definer set search_path=public
as $$ declare inv public.player_relics%rowtype; begin
 if not exists(select 1 from public.rich_click_admins where user_id=auth.uid()) then raise exception 'ADMIN_REQUIRED'; end if;
 if p_quantity is null or p_quantity<1 or p_quantity>100 or p_mode not in ('give','remove') then raise exception 'INVALID_INPUT'; end if;
 if not exists(select 1 from public.relic_catalog where id=p_relic_id) then raise exception 'RELIC_NOT_FOUND'; end if;
 insert into public.player_relics(user_id,relic_id,owned_count,purchased_count) values(p_user_id,p_relic_id,0,0) on conflict do nothing;
 select * into inv from public.player_relics where user_id=p_user_id and relic_id=p_relic_id for update;
 if p_mode='give' then update public.player_relics set owned_count=owned_count+p_quantity where user_id=p_user_id and relic_id=p_relic_id;
 else
  if inv.owned_count-inv.listed_count<p_quantity then raise exception 'NOT_ENOUGH_UNLISTED_ITEMS'; end if;
  update public.player_relics set owned_count=owned_count-p_quantity where user_id=p_user_id and relic_id=p_relic_id;
 end if;
 perform public.admin_log('relic_'||p_mode,'user='||p_user_id||' relic='||p_relic_id||' qty='||p_quantity);
 return jsonb_build_object('success',true,'message',p_mode||' '||p_quantity||' x '||p_relic_id);
end $$;

create or replace function public.admin_recent_logs()
returns table(created_at timestamptz,admin_nickname text,action text,details text)
language plpgsql stable security definer set search_path=public
as $$ begin
 if not exists(select 1 from public.rich_click_admins where user_id=auth.uid()) then raise exception 'ADMIN_REQUIRED'; end if;
 return query select l.created_at,coalesce(p.nickname,'Администратор'),l.action,l.details
 from public.admin_action_logs l left join public.player_profiles p on p.user_id=l.admin_id
 order by l.created_at desc limit 50;
end $$;

-- Apply server-side game controls to click and passive-income RPCs.
create or replace function public.earn_click(p_amount bigint)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare uid uuid:=auth.uid(); w public.player_wallets%rowtype; reward bigint; settings public.game_settings%rowtype;
begin
 if uid is null then raise exception 'AUTH_REQUIRED'; end if;
 select * into settings from public.game_settings where id=true;
 if settings.maintenance_mode then raise exception 'MAINTENANCE_MODE'; end if;
 if p_amount is null or p_amount<1 then raise exception 'INVALID_REWARD'; end if;
 select * into w from public.player_wallets where user_id=uid for update;
 if not found then raise exception 'WALLET_NOT_FOUND'; end if;
 if w.last_click_at is not null and w.last_click_at>now()-interval '150 milliseconds' then raise exception 'CLICK_TOO_FAST'; end if;
 reward:=least(floor(least(p_amount,100)*settings.click_multiplier)::bigint,1000000000000);
 update public.player_wallets set balance=balance+reward,lifetime_earned=lifetime_earned+reward,last_click_at=now(),updated_at=now() where user_id=uid returning * into w;
 return jsonb_build_object('balance',w.balance,'earned',w.lifetime_earned,'reward',reward);
end $$;

create or replace function public.collect_passive_income()
returns jsonb language plpgsql security definer set search_path=public
as $$
declare uid uuid:=auth.uid(); w public.player_wallets%rowtype; inc bigint; elapsed numeric; reward bigint; settings public.game_settings%rowtype;
begin
 if uid is null then raise exception 'AUTH_REQUIRED'; end if;
 select * into settings from public.game_settings where id=true;
 select * into w from public.player_wallets where user_id=uid for update;
 if not found then raise exception 'WALLET_NOT_FOUND'; end if;
 select coalesce(sum(a.income_per_second*p.quantity),0)::bigint into inc from public.player_assets p join public.asset_catalog a using(asset_key) where p.user_id=uid;
 inc:=floor(inc*settings.passive_multiplier)::bigint;
 elapsed:=greatest(0,least(extract(epoch from(now()-w.last_income_at)),86400));
 reward:=case when settings.maintenance_mode then 0 else floor(elapsed*inc)::bigint end;
 update public.player_wallets set balance=balance+reward,lifetime_earned=lifetime_earned+reward,last_income_at=now(),updated_at=now() where user_id=uid returning * into w;
 return jsonb_build_object('balance',w.balance,'earned',w.lifetime_earned,'income',inc,'reward',reward);
end $$;

grant select on public.game_announcements,public.game_settings to anon,authenticated;
grant execute on function public.admin_change_player_balance(uuid,bigint,text) to authenticated;
grant execute on function public.admin_adjust_all_balances(text,bigint) to authenticated;
grant execute on function public.admin_publish_announcement(text,text) to authenticated;
grant execute on function public.admin_clear_announcement() to authenticated;
grant execute on function public.admin_get_settings() to authenticated;
grant execute on function public.admin_update_settings(numeric,numeric,boolean) to authenticated;
grant execute on function public.admin_manage_relic(uuid,text,integer,text) to authenticated;
grant execute on function public.admin_recent_logs() to authenticated;
revoke all on function public.admin_change_player_balance(uuid,bigint,text) from public,anon;
revoke all on function public.admin_adjust_all_balances(text,bigint) from public,anon;
revoke all on function public.admin_publish_announcement(text,text) from public,anon;
revoke all on function public.admin_clear_announcement() from public,anon;
revoke all on function public.admin_get_settings() from public,anon;
revoke all on function public.admin_update_settings(numeric,numeric,boolean) from public,anon;
revoke all on function public.admin_manage_relic(uuid,text,integer,text) from public,anon;
revoke all on function public.admin_recent_logs() from public,anon;


-- Respect maintenance mode for all player-facing purchases as well.
create or replace function public.purchase_asset(p_asset_key text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare uid uuid:=auth.uid(); a public.asset_catalog%rowtype; w public.player_wallets%rowtype; qty integer; settings public.game_settings%rowtype;
begin
 if uid is null then raise exception 'AUTH_REQUIRED'; end if;
 select * into settings from public.game_settings where id=true;
 if settings.maintenance_mode then raise exception 'MAINTENANCE_MODE'; end if;
 select * into a from public.asset_catalog where asset_key=p_asset_key;
 if not found then raise exception 'ASSET_NOT_FOUND'; end if;
 select * into w from public.player_wallets where user_id=uid for update;
 if not found then raise exception 'WALLET_NOT_FOUND'; end if;
 if w.balance<a.price then raise exception 'NOT_ENOUGH_BALANCE'; end if;
 update public.player_wallets set balance=balance-a.price,updated_at=now() where user_id=uid;
 insert into public.player_assets(user_id,asset_key,quantity) values(uid,p_asset_key,1)
 on conflict(user_id,asset_key) do update set quantity=public.player_assets.quantity+1 returning quantity into qty;
 return jsonb_build_object('success',true,'balance',w.balance-a.price,'quantity',qty);
end $$;

create or replace function public.purchase_relic(p_relic_id text)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare uid uuid:=auth.uid(); item public.relic_catalog%rowtype; wallet public.player_wallets%rowtype; inv public.player_relics%rowtype; settings public.game_settings%rowtype;
begin
 if uid is null then raise exception 'AUTH_REQUIRED'; end if;
 select * into settings from public.game_settings where id=true;
 if settings.maintenance_mode then raise exception 'MAINTENANCE_MODE'; end if;
 select * into item from public.relic_catalog where id=p_relic_id;
 if not found then raise exception 'RELIC_NOT_FOUND'; end if;
 select * into wallet from public.player_wallets where user_id=uid for update;
 if wallet.balance<item.base_value then raise exception 'NOT_ENOUGH_BALANCE'; end if;
 insert into public.player_relics(user_id,relic_id,owned_count,purchased_count) values(uid,p_relic_id,0,0) on conflict do nothing;
 select * into inv from public.player_relics where user_id=uid and relic_id=p_relic_id for update;
 if inv.purchased_count>=3 then raise exception 'PURCHASE_LIMIT_REACHED'; end if;
 update public.player_wallets set balance=balance-item.base_value,updated_at=now() where user_id=uid;
 update public.player_relics set owned_count=owned_count+1,purchased_count=purchased_count+1 where user_id=uid and relic_id=p_relic_id;
 return jsonb_build_object('success',true,'price',item.base_value,'remaining_balance',wallet.balance-item.base_value);
end $$;

create or replace function public.buy_relic_listing(p_listing_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare buyer uuid:=auth.uid(); listing public.market_listings%rowtype; buyer_wallet public.player_wallets%rowtype; settings public.game_settings%rowtype;
begin
 if buyer is null then raise exception 'AUTH_REQUIRED'; end if;
 select * into settings from public.game_settings where id=true;
 if settings.maintenance_mode then raise exception 'MAINTENANCE_MODE'; end if;
 select * into listing from public.market_listings where id=p_listing_id and status='active' for update;
 if not found then raise exception 'LISTING_UNAVAILABLE'; end if;
 if listing.seller_id=buyer then raise exception 'CANNOT_BUY_OWN_LISTING'; end if;
 select * into buyer_wallet from public.player_wallets where user_id=buyer for update;
 if buyer_wallet.balance<listing.unit_price*listing.quantity then raise exception 'NOT_ENOUGH_BALANCE'; end if;
 insert into public.player_relics(user_id,relic_id,owned_count,purchased_count) values(buyer,listing.relic_id,0,0) on conflict do nothing;
 perform 1 from public.player_relics where user_id=buyer and relic_id=listing.relic_id for update;
 if (select purchased_count from public.player_relics where user_id=buyer and relic_id=listing.relic_id)+listing.quantity>3 then raise exception 'PURCHASE_LIMIT_REACHED'; end if;
 update public.player_wallets set balance=balance-listing.unit_price*listing.quantity,updated_at=now() where user_id=buyer;
 update public.player_wallets set balance=balance+listing.unit_price*listing.quantity,updated_at=now() where user_id=listing.seller_id;
 insert into public.player_relics(user_id,relic_id,owned_count,purchased_count) values(buyer,listing.relic_id,listing.quantity,0)
 on conflict(user_id,relic_id) do update set owned_count=public.player_relics.owned_count+excluded.owned_count,purchased_count=public.player_relics.purchased_count+excluded.owned_count;
 update public.player_relics set owned_count=owned_count-listing.quantity,listed_count=listed_count-listing.quantity where user_id=listing.seller_id and relic_id=listing.relic_id;
 update public.market_listings set status='sold' where id=p_listing_id;
 return jsonb_build_object('success',true,'total',listing.unit_price*listing.quantity);
end $$;

revoke all on function public.admin_log(text,text) from public,anon;


-- Enable database change events for the Rich Click live interface.
-- Run this schema in Supabase SQL Editor to apply the publication changes.
do $$
declare
  t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array[
      'player_wallets',
      'player_assets',
      'player_relics',
      'player_profiles',
      'market_listings',
      'game_announcements'
    ]
    loop
      if not exists (
        select 1 from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename = t
      ) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;


-- Complete progress reset controls. These preserve auth accounts and nicknames,
-- while clearing all player-owned gameplay progress and active market listings.
create or replace function public.admin_reset_player_progress(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  relic_rows integer;
  asset_rows integer;
  listing_rows integer;
begin
  if auth.uid() is null or not exists (
    select 1 from public.rich_click_admins where user_id=auth.uid()
  ) then
    raise exception 'ADMIN_REQUIRED';
  end if;
  if p_user_id is null or not exists (
    select 1 from public.player_wallets where user_id=p_user_id
  ) then
    raise exception 'PLAYER_NOT_FOUND';
  end if;

  update public.market_listings
    set status='cancelled'
    where seller_id=p_user_id and status='active';
  get diagnostics listing_rows=row_count;

  delete from public.player_relics where user_id=p_user_id;
  get diagnostics relic_rows=row_count;

  delete from public.player_assets where user_id=p_user_id;
  get diagnostics asset_rows=row_count;

  update public.player_wallets
    set balance=0,
        lifetime_earned=0,
        last_income_at=now(),
        last_click_at=null,
        updated_at=now()
    where user_id=p_user_id;

  perform public.admin_log(
    'player_full_reset',
    'user='||p_user_id||' relic_rows='||relic_rows||
    ' asset_rows='||asset_rows||' listings_cancelled='||listing_rows
  );

  return jsonb_build_object(
    'success',true,
    'relic_rows',relic_rows,
    'asset_rows',asset_rows,
    'listings_cancelled',listing_rows
  );
end;
$$;

create or replace function public.admin_reset_all_progress()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  affected_players integer;
  relic_rows integer;
  asset_rows integer;
  listing_rows integer;
begin
  if auth.uid() is null or not exists (
    select 1 from public.rich_click_admins where user_id=auth.uid()
  ) then
    raise exception 'ADMIN_REQUIRED';
  end if;

  update public.market_listings
    set status='cancelled'
    where status='active';
  get diagnostics listing_rows=row_count;

  delete from public.player_relics;
  get diagnostics relic_rows=row_count;

  delete from public.player_assets;
  get diagnostics asset_rows=row_count;

  update public.player_wallets
    set balance=0,
        lifetime_earned=0,
        last_income_at=now(),
        last_click_at=null,
        updated_at=now();
  get diagnostics affected_players=row_count;

  perform public.admin_log(
    'global_full_reset',
    'players='||affected_players||' relic_rows='||relic_rows||
    ' asset_rows='||asset_rows||' listings_cancelled='||listing_rows
  );

  return jsonb_build_object(
    'success',true,
    'affected_players',affected_players,
    'relic_rows',relic_rows,
    'asset_rows',asset_rows,
    'listings_cancelled',listing_rows
  );
end;
$$;

grant execute on function public.admin_reset_player_progress(uuid) to authenticated;
grant execute on function public.admin_reset_all_progress() to authenticated;
revoke all on function public.admin_reset_player_progress(uuid) from public,anon;
revoke all on function public.admin_reset_all_progress() from public,anon;


-- Fix admin player search: qualify the admin-table user_id so it cannot
-- collide with the RETURNS TABLE output column named user_id.
create or replace function public.admin_search_players(p_query text)
returns table(user_id uuid,nickname text,balance bigint)
language plpgsql stable security definer set search_path=public
as $$
begin
  if auth.uid() is null or not exists(
    select 1 from public.rich_click_admins as admins
    where admins.user_id = auth.uid()
  ) then
    raise exception 'ADMIN_REQUIRED';
  end if;
  if p_query is null or char_length(trim(p_query)) < 2 then
    raise exception 'QUERY_TOO_SHORT';
  end if;
  return query
    select p.user_id, p.nickname, w.balance
    from public.player_profiles as p
    join public.player_wallets as w on w.user_id = p.user_id
    where p.nickname ilike '%' || left(trim(p_query),18) || '%'
    order by p.nickname
    limit 20;
end;
$$;
grant execute on function public.admin_search_players(text) to authenticated;
revoke all on function public.admin_search_players(text) from public, anon;

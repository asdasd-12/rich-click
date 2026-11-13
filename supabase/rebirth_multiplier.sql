-- Rebirth multiplier: +1.0x per rebirth for both clicks and passive income.
create or replace function public.purchase_rebirth()
returns jsonb language plpgsql security definer set search_path=public
as $$
declare uid uuid:=auth.uid(); w public.player_wallets%rowtype; cost numeric;
begin
 if uid is null then raise exception 'AUTH_REQUIRED'; end if;
 select * into w from public.player_wallets where user_id=uid for update;
 if not found then raise exception 'WALLET_NOT_FOUND'; end if;
 if w.rebirths>=50 then raise exception 'REBIRTH_MAX'; end if;
 cost:=100000::numeric*power(10::numeric,w.rebirths);
 if cost>w.balance then raise exception 'INSUFFICIENT_FUNDS'; end if;
 update public.player_wallets
   set balance=balance-cost::bigint,lifetime_earned=0,rebirths=rebirths+1,
       last_income_at=now(),last_click_at=null,updated_at=now()
   where user_id=uid returning * into w;
 return jsonb_build_object(
   'balance',w.balance,
   'rebirths',w.rebirths,
   'click_multiplier',1+w.rebirths,
   'passive_multiplier',1+w.rebirths,
   'next_cost',100000::numeric*power(10::numeric,w.rebirths)
 );
end $$;

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
 reward:=least(floor(least(p_amount,100)*settings.click_multiplier*(1+w.rebirths))::bigint,1000000000000);
 update public.player_wallets set balance=balance+reward,lifetime_earned=lifetime_earned+reward,last_click_at=now(),updated_at=now() where user_id=uid returning * into w;
 return jsonb_build_object('balance',w.balance,'earned',w.lifetime_earned,'reward',reward,'rebirths',w.rebirths);
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
 select coalesce(sum(a.income_per_second*p.quantity),0)::bigint into inc
 from public.player_assets p join public.asset_catalog a using(asset_key) where p.user_id=uid;
 inc:=floor(inc*settings.passive_multiplier*(1+w.rebirths))::bigint;
 elapsed:=greatest(0,least(extract(epoch from(now()-w.last_income_at)),86400));
 reward:=case when settings.maintenance_mode then 0 else floor(elapsed*inc)::bigint end;
 update public.player_wallets set balance=balance+reward,lifetime_earned=lifetime_earned+reward,last_income_at=now(),updated_at=now() where user_id=uid returning * into w;
 return jsonb_build_object('balance',w.balance,'earned',w.lifetime_earned,'income',inc,'reward',reward,'rebirths',w.rebirths);
end $$;

-- 056: 친구 목록 RPC 반환 타입 보정 + 홈 배너 RPC/UI 복구 보강.
-- - rpc_list_friend_members(integer)의 RETURNS TABLE 타입과 RETURN QUERY 타입을 명시 캐스팅으로 일치시킨다.
-- - home_banner/RPC가 migration 누락 또는 schema cache 문제로 흔들려도 다시 복구되도록 보강한다.

create table if not exists public.home_banner (
  id uuid primary key default gen_random_uuid(),
  message text not null,
  background_color text not null default '#000000',
  text_color text not null default '#ffffff',
  border_color text not null default '#d6b133',
  sort_order integer not null default 0,
  is_active boolean not null default true,
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (btrim(message) <> ''),
  check (char_length(message) <= 120),
  check (background_color ~ '^#[0-9A-Fa-f]{6}$'),
  check (text_color ~ '^#[0-9A-Fa-f]{6}$'),
  check (border_color ~ '^#[0-9A-Fa-f]{6}$')
);
create index if not exists home_banner_active_order_idx
  on public.home_banner(is_active, sort_order, created_at);
create index if not exists home_banner_active_period_idx
  on public.home_banner(is_active, starts_at, ends_at);
do $$
begin
  if to_regclass('public.set_updated_at') is not null then
    drop trigger if exists home_banner_set_updated_at on public.home_banner;
    create trigger home_banner_set_updated_at
    before update on public.home_banner
    for each row execute function public.set_updated_at();
  end if;
end;
$$;
alter table public.home_banner enable row level security;
drop policy if exists home_banner_admin_all on public.home_banner;
create policy home_banner_admin_all
on public.home_banner for all to authenticated
using (
  exists (
    select 1
      from public.member m
     where m.user_id = (select auth.uid())
       and m.role in ('admin', 'super_admin')
  )
)
with check (
  exists (
    select 1
      from public.member m
     where m.user_id = (select auth.uid())
       and m.role in ('admin', 'super_admin')
  )
);
insert into public.home_banner(message, background_color, text_color, border_color, sort_order, is_active)
select '상담만 받아도 3만원 상당의 추가 혜택', '#000000', '#ffffff', '#d6b133', 10, true
where not exists (
  select 1
    from public.home_banner
   where message = '상담만 받아도 3만원 상당의 추가 혜택'
);
create or replace function public.rpc_get_home_banners()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_banners jsonb;
begin
  perform private.require_active_member();

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', hb.id,
        'message', hb.message,
        'backgroundColor', hb.background_color,
        'textColor', hb.text_color,
        'borderColor', hb.border_color,
        'sortOrder', hb.sort_order
      ) order by hb.sort_order asc, hb.created_at asc
    ),
    '[]'::jsonb
  )
    into v_banners
    from public.home_banner hb
   where hb.is_active = true
     and (hb.starts_at is null or hb.starts_at <= now())
     and (hb.ends_at is null or hb.ends_at > now());

  return jsonb_build_object('banners', v_banners);
end;
$$;
revoke all on function public.rpc_get_home_banners() from public, anon, authenticated;
grant execute on function public.rpc_get_home_banners() to authenticated;
drop function if exists public.rpc_list_friend_members(integer);
create or replace function public.rpc_list_friend_members(
  p_limit integer default 100
)
returns table (
  user_id uuid,
  mb_no bigint,
  mb_id text,
  mb_name text,
  mb_email text,
  mb_profile text,
  relation_type text,
  referral_status text,
  joined_at timestamptz,
  created_at timestamptz,
  direct_referral_count integer,
  friend_level integer
)
language plpgsql
stable
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 200);
begin
  v_member := private.require_active_member();

  return query
  with referrer_edges as (
    select
      rn.referrer_user_id::uuid as referrer_user_id,
      rn.status::text as referral_status,
      rn.joined_at::timestamptz as joined_at
    from public.referral_network rn
    where rn.referred_user_id = v_member.user_id
      and rn.depth = 1
      and rn.status = 'active'

    union all

    select
      v_member.referrer_user_id::uuid as referrer_user_id,
      'active'::text as referral_status,
      v_member.created_at::timestamptz as joined_at
    where v_member.referrer_user_id is not null
  ),
  distinct_referrers as (
    select distinct on (re.referrer_user_id)
      re.referrer_user_id::uuid as referrer_user_id,
      re.referral_status::text as referral_status,
      re.joined_at::timestamptz as joined_at
    from referrer_edges re
    where re.referrer_user_id is not null
    order by re.referrer_user_id, re.joined_at desc nulls last
  ),
  friends as (
    select
      referrer.user_id::uuid as user_id,
      referrer.mb_no::bigint as mb_no,
      referrer.mb_id::text as mb_id,
      referrer.mb_name::text as mb_name,
      referrer.mb_email::text as mb_email,
      referrer.mb_profile::text as mb_profile,
      'referrer'::text as relation_type,
      coalesce(dr.referral_status, 'active')::text as referral_status,
      coalesce(dr.joined_at, v_member.created_at)::timestamptz as joined_at,
      referrer.created_at::timestamptz as created_at,
      0::integer as relation_order
    from distinct_referrers dr
    join public.member referrer on referrer.user_id = dr.referrer_user_id
    where referrer.status = 'active'
      and not coalesce(referrer.is_del, false)

    union all

    select
      referred.user_id::uuid as user_id,
      referred.mb_no::bigint as mb_no,
      referred.mb_id::text as mb_id,
      referred.mb_name::text as mb_name,
      referred.mb_email::text as mb_email,
      referred.mb_profile::text as mb_profile,
      'referred'::text as relation_type,
      rn.status::text as referral_status,
      rn.joined_at::timestamptz as joined_at,
      referred.created_at::timestamptz as created_at,
      1::integer as relation_order
    from public.referral_network rn
    join public.member referred on referred.user_id = rn.referred_user_id
    where rn.referrer_user_id = v_member.user_id
      and rn.depth = 1
      and rn.status = 'active'
      and referred.status = 'active'
      and not coalesce(referred.is_del, false)
  ),
  friend_counts as (
    select
      f.user_id,
      f.mb_no,
      f.mb_id,
      f.mb_name,
      f.mb_email,
      f.mb_profile,
      f.relation_type,
      f.referral_status,
      f.joined_at,
      f.created_at,
      f.relation_order,
      coalesce((
        select count(*)::integer
        from public.referral_network child_rn
        join public.member child on child.user_id = child_rn.referred_user_id
        where child_rn.referrer_user_id = f.user_id
          and child_rn.depth = 1
          and child_rn.status = 'active'
          and child.status = 'active'
          and not coalesce(child.is_del, false)
      ), 0)::integer as direct_referral_count
    from friends f
  ),
  friend_levels as (
    select
      fc.*,
      (coalesce((
        select max(rrl.level)::integer
        from public.referral_reward_levels rrl
        where rrl.is_active = true
          and rrl.required_referrals <= fc.direct_referral_count
      ), 0) + 1)::integer as friend_level
    from friend_counts fc
  )
  select
    fl.user_id::uuid,
    fl.mb_no::bigint,
    fl.mb_id::text,
    fl.mb_name::text,
    fl.mb_email::text,
    fl.mb_profile::text,
    fl.relation_type::text,
    fl.referral_status::text,
    fl.joined_at::timestamptz,
    fl.created_at::timestamptz,
    fl.direct_referral_count::integer,
    fl.friend_level::integer
  from friend_levels fl
  order by fl.relation_order asc, fl.joined_at desc nulls last, fl.created_at desc
  limit v_limit;
end;
$$;
revoke all on function public.rpc_list_friend_members(integer) from public, anon;
grant execute on function public.rpc_list_friend_members(integer) to authenticated;
notify pgrst, 'reload schema';

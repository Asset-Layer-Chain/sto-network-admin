-- Referral reward level policy and friend activity summary.

create table if not exists public.referral_reward_levels (
  id bigserial primary key,
  level integer not null unique,
  required_referrals integer not null,
  reward_stoc numeric(18, 6) not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint referral_reward_levels_level_positive check (level > 0),
  constraint referral_reward_levels_required_positive check (required_referrals > 0),
  constraint referral_reward_levels_reward_nonnegative check (reward_stoc >= 0)
);
insert into public.referral_reward_levels(level, required_referrals, reward_stoc, is_active)
values
  (1, 10, 10, true),
  (2, 30, 30, true),
  (3, 100, 110, true),
  (4, 500, 550, true),
  (5, 1000, 1500, true),
  (6, 5000, 6000, true),
  (7, 10000, 13000, true)
on conflict (level) do update set
  required_referrals = excluded.required_referrals,
  reward_stoc = excluded.reward_stoc,
  is_active = excluded.is_active,
  updated_at = now();
alter table public.referral_reward_levels enable row level security;
drop policy if exists referral_reward_levels_select_active on public.referral_reward_levels;
create policy referral_reward_levels_select_active
on public.referral_reward_levels for select to authenticated
using (is_active = true);
create or replace function public.rpc_get_referral_reward_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_direct_count integer := 0;
  v_today_count integer := 0;
  v_yesterday_count integer := 0;
  v_base_reward numeric(18, 6) := 5;
  v_today_reward numeric(18, 6) := 0;
  v_level_reward numeric(18, 6) := 0;
  v_current_level integer := 0;
  v_next_level jsonb;
  v_levels jsonb;
begin
  v_member := private.require_active_member();

  select count(*)::integer into v_direct_count
  from public.referral_network rn
  join public.member referred on referred.user_id = rn.referred_user_id
  where rn.referrer_user_id = v_member.user_id
    and rn.depth = 1
    and rn.status = 'active'
    and referred.status = 'active'
    and not coalesce(referred.is_del, false);

  select count(*)::integer into v_today_count
  from public.referral_network rn
  where rn.referrer_user_id = v_member.user_id
    and rn.depth = 1
    and rn.status = 'active'
    and rn.joined_at >= date_trunc('day', now())
    and rn.joined_at < date_trunc('day', now()) + interval '1 day';

  select count(*)::integer into v_yesterday_count
  from public.referral_network rn
  where rn.referrer_user_id = v_member.user_id
    and rn.depth = 1
    and rn.status = 'active'
    and rn.joined_at >= date_trunc('day', now()) - interval '1 day'
    and rn.joined_at < date_trunc('day', now());

  v_today_reward := v_today_count * v_base_reward;

  select coalesce(max(level), 0), coalesce(sum(reward_stoc), 0)
    into v_current_level, v_level_reward
  from public.referral_reward_levels
  where is_active = true
    and required_referrals <= v_direct_count;

  select jsonb_build_object(
    'level', level,
    'requiredReferrals', required_referrals,
    'rewardStoc', reward_stoc,
    'remaining', greatest(required_referrals - v_direct_count, 0)
  ) into v_next_level
  from public.referral_reward_levels
  where is_active = true
    and required_referrals > v_direct_count
  order by required_referrals asc
  limit 1;

  select coalesce(jsonb_agg(jsonb_build_object(
    'level', level,
    'requiredReferrals', required_referrals,
    'rewardStoc', reward_stoc
  ) order by level asc), '[]'::jsonb)
    into v_levels
  from public.referral_reward_levels
  where is_active = true;

  return jsonb_build_object(
    'directReferralCount', v_direct_count,
    'todayRewardStoc', v_today_reward,
    'yesterdayReferralCount', v_yesterday_count,
    'totalRewardStoc', (v_direct_count * v_base_reward) + coalesce(v_level_reward, 0),
    'baseRewardStoc', v_base_reward,
    'currentLevel', v_current_level,
    'nextLevel', v_next_level,
    'levels', v_levels,
    'updatedAt', now()
  );
end;
$$;
revoke all on function public.rpc_get_referral_reward_summary() from public, anon;
grant execute on function public.rpc_get_referral_reward_summary() to authenticated;
-- The return table shape changes in this migration, so PostgreSQL
-- cannot use CREATE OR REPLACE for the existing function signature.
-- Drop the old function before recreating it with the new OUT columns.
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
    select rn.referrer_user_id as referrer_user_id, rn.status as referral_status, rn.joined_at
    from public.referral_network rn
    where rn.referred_user_id = v_member.user_id
      and rn.depth = 1
      and rn.status = 'active'

    union all

    select v_member.referrer_user_id as referrer_user_id, 'active'::text as referral_status, v_member.created_at as joined_at
    where v_member.referrer_user_id is not null
  ),
  distinct_referrers as (
    select distinct on (re.referrer_user_id) re.referrer_user_id, re.referral_status, re.joined_at
    from referrer_edges re
    where re.referrer_user_id is not null
    order by re.referrer_user_id, re.joined_at desc nulls last
  ),
  friends as (
    select
      referrer.user_id,
      referrer.mb_no,
      referrer.mb_id,
      referrer.mb_name,
      referrer.mb_email,
      referrer.mb_profile,
      'referrer'::text as relation_type,
      coalesce(dr.referral_status, 'active') as referral_status,
      coalesce(dr.joined_at, v_member.created_at) as joined_at,
      referrer.created_at,
      0 as relation_order
    from distinct_referrers dr
    join public.member referrer on referrer.user_id = dr.referrer_user_id
    where referrer.status = 'active'
      and not coalesce(referrer.is_del, false)

    union all

    select
      referred.user_id,
      referred.mb_no,
      referred.mb_id,
      referred.mb_name,
      referred.mb_email,
      referred.mb_profile,
      'referred'::text as relation_type,
      rn.status as referral_status,
      rn.joined_at,
      referred.created_at,
      1 as relation_order
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
      f.*,
      (
        select count(*)::integer
        from public.referral_network child_rn
        join public.member child on child.user_id = child_rn.referred_user_id
        where child_rn.referrer_user_id = f.user_id
          and child_rn.depth = 1
          and child_rn.status = 'active'
          and child.status = 'active'
          and not coalesce(child.is_del, false)
      ) as direct_referral_count
    from friends f
  )
  select
    fc.user_id,
    fc.mb_no,
    fc.mb_id,
    fc.mb_name,
    fc.mb_email,
    fc.mb_profile,
    fc.relation_type,
    fc.referral_status,
    fc.joined_at,
    fc.created_at,
    fc.direct_referral_count,
    greatest(coalesce((
      select max(rrl.level)
      from public.referral_reward_levels rrl
      where rrl.is_active = true
        and rrl.required_referrals <= fc.direct_referral_count
    ), 1), 1) as friend_level
  from friend_counts fc
  order by fc.relation_order asc, fc.joined_at desc nulls last, fc.created_at desc
  limit v_limit;
end;
$$;
revoke all on function public.rpc_list_friend_members(integer) from public, anon;
grant execute on function public.rpc_list_friend_members(integer) to authenticated;

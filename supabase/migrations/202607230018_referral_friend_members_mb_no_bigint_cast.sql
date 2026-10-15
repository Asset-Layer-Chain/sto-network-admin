-- Fix rpc_list_friend_members return type mismatch.
-- public.member.mb_no can be integer in existing projects, while the RPC contract
-- returns mb_no as bigint. Cast explicitly to keep the public RPC shape stable.

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
    fc.mb_no::bigint as mb_no,
    fc.mb_id,
    fc.mb_name,
    fc.mb_email,
    fc.mb_profile,
    fc.relation_type,
    fc.referral_status,
    fc.joined_at,
    fc.created_at,
    fc.direct_referral_count::integer as direct_referral_count,
    coalesce((
      select max(rrl.level)
      from public.referral_reward_levels rrl
      where rrl.is_active = true
        and rrl.required_referrals <= fc.direct_referral_count
    ), 0)::integer as friend_level
  from friend_counts fc
  order by fc.relation_order asc, fc.joined_at desc nulls last, fc.created_at desc
  limit v_limit;
end;
$$;
revoke all on function public.rpc_list_friend_members(integer) from public, anon;
grant execute on function public.rpc_list_friend_members(integer) to authenticated;

-- Friend tab referrer display hardening.
-- A member should normally have one signup referrer, but legacy/manual data can
-- contain multiple active depth-1 referral_network rows pointing to the member.
-- The friend screen must show every active referrer instead of only
-- member.referrer_user_id.

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
  created_at timestamptz
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
      rn.referrer_user_id as referrer_user_id,
      rn.status as referral_status,
      rn.joined_at
    from public.referral_network rn
    where rn.referred_user_id = v_member.user_id
      and rn.depth = 1
      and rn.status = 'active'

    union all

    select
      v_member.referrer_user_id as referrer_user_id,
      'active'::text as referral_status,
      v_member.created_at as joined_at
    where v_member.referrer_user_id is not null
  ),
  distinct_referrers as (
    select distinct on (re.referrer_user_id)
      re.referrer_user_id,
      re.referral_status,
      re.joined_at
    from referrer_edges re
    where re.referrer_user_id is not null
    order by re.referrer_user_id, re.joined_at desc nulls last
  ),
  friends as (
    -- 나를 추천한 사람들. 가입 추천인은 원칙상 1명이지만 데이터 보정/운영 이슈를 고려해 모두 표시한다.
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

    -- 내가 추천한 사람들.
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
  )
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
    f.created_at
  from friends f
  order by f.relation_order asc, f.joined_at desc nulls last, f.created_at desc
  limit v_limit;
end;
$$;
revoke all on function public.rpc_list_friend_members(integer) from public, anon;
grant execute on function public.rpc_list_friend_members(integer) to authenticated;

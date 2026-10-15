-- 057: Friend list pagination for infinite scroll with accurate total counts.
-- - Keep rpc_list_friend_members(integer) for backward compatibility.
-- - Add rpc_list_friend_members_page(limit, offset, search) returning items + totalCount.

create or replace function public.rpc_list_friend_members_page(
  p_limit integer default 50,
  p_offset integer default 0,
  p_search text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_search text := nullif(lower(trim(coalesce(p_search, ''))), '');
  v_total integer := 0;
  v_items jsonb := '[]'::jsonb;
begin
  v_member := private.require_active_member();

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
  ),
  filtered as (
    select *
      from friend_levels fl
     where v_search is null
        or lower(coalesce(fl.mb_id, '')) like '%' || v_search || '%'
        or lower(coalesce(fl.mb_name, '')) like '%' || v_search || '%'
        or lower(coalesce(fl.mb_email, '')) like '%' || v_search || '%'
  )
  select count(*)::integer
    into v_total
    from filtered;

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
  ),
  filtered as (
    select *
      from friend_levels fl
     where v_search is null
        or lower(coalesce(fl.mb_id, '')) like '%' || v_search || '%'
        or lower(coalesce(fl.mb_name, '')) like '%' || v_search || '%'
        or lower(coalesce(fl.mb_email, '')) like '%' || v_search || '%'
  ),
  page_data as (
    select *
      from filtered fl
     order by fl.relation_order asc, fl.joined_at desc nulls last, fl.created_at desc
     limit v_limit
     offset v_offset
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', pd.user_id,
    'mb_no', pd.mb_no,
    'mb_id', pd.mb_id,
    'mb_name', pd.mb_name,
    'mb_email', pd.mb_email,
    'mb_profile', pd.mb_profile,
    'relation_type', pd.relation_type,
    'referral_status', pd.referral_status,
    'joined_at', pd.joined_at,
    'created_at', pd.created_at,
    'direct_referral_count', pd.direct_referral_count,
    'friend_level', pd.friend_level
  ) order by pd.relation_order asc, pd.joined_at desc nulls last, pd.created_at desc), '[]'::jsonb)
    into v_items
    from page_data pd;

  return jsonb_build_object(
    'items', v_items,
    'totalCount', v_total,
    'limit', v_limit,
    'offset', v_offset,
    'nextOffset', v_offset + jsonb_array_length(v_items),
    'hasMore', v_offset + jsonb_array_length(v_items) < v_total
  );
end;
$$;
revoke all on function public.rpc_list_friend_members_page(integer, integer, text) from public, anon, authenticated;
grant execute on function public.rpc_list_friend_members_page(integer, integer, text) to authenticated;
notify pgrst, 'reload schema';

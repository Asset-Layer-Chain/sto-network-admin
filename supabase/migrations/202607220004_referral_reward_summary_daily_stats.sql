create or replace function public.rpc_get_referral_reward_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_temp
as $rpc_get_referral_reward_summary$
declare
  v_member public.member%rowtype;
  v_direct_count integer := 0;
  v_today_count integer := 0;
  v_yesterday_count integer := 0;
  v_base_reward numeric(18, 6) := 5;
  v_today_reward numeric(18, 6) := 0;
  v_yesterday_reward numeric(18, 6) := 0;
  v_total_reward numeric(18, 6) := 0;
  v_achieved_reward_level integer := 0;
  v_current_level integer := 1;
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
  join public.member referred on referred.user_id = rn.referred_user_id
  where rn.referrer_user_id = v_member.user_id
    and rn.depth = 1
    and rn.status = 'active'
    and referred.status = 'active'
    and not coalesce(referred.is_del, false)
    and rn.joined_at >= date_trunc('day', now())
    and rn.joined_at < date_trunc('day', now()) + interval '1 day';

  select count(*)::integer into v_yesterday_count
  from public.referral_network rn
  join public.member referred on referred.user_id = rn.referred_user_id
  where rn.referrer_user_id = v_member.user_id
    and rn.depth = 1
    and rn.status = 'active'
    and referred.status = 'active'
    and not coalesce(referred.is_del, false)
    and rn.joined_at >= date_trunc('day', now()) - interval '1 day'
    and rn.joined_at < date_trunc('day', now());

  select coalesce(sum(rg.amount_stoc), 0)
    into v_today_reward
  from public.referral_reward_grants rg
  where rg.member_id = v_member.user_id
    and rg.status = 'completed'
    and rg.granted_at >= date_trunc('day', now())
    and rg.granted_at < date_trunc('day', now()) + interval '1 day';

  select coalesce(sum(rg.amount_stoc), 0)
    into v_yesterday_reward
  from public.referral_reward_grants rg
  where rg.member_id = v_member.user_id
    and rg.status = 'completed'
    and rg.granted_at >= date_trunc('day', now()) - interval '1 day'
    and rg.granted_at < date_trunc('day', now());

  select coalesce(sum(rg.amount_stoc), 0)
    into v_total_reward
  from public.referral_reward_grants rg
  where rg.member_id = v_member.user_id
    and rg.status = 'completed';

  select coalesce(max(level), 0)
    into v_achieved_reward_level
  from public.referral_reward_levels
  where is_active = true
    and required_referrals <= v_direct_count;

  v_current_level := v_achieved_reward_level + 1;

  select jsonb_build_object(
    'rewardLevel', level,
    'level', level + 1,
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
    'rewardLevel', level,
    'level', level + 1,
    'requiredReferrals', required_referrals,
    'rewardStoc', reward_stoc
  ) order by level asc), '[]'::jsonb)
    into v_levels
  from public.referral_reward_levels
  where is_active = true;

  return jsonb_build_object(
    'directReferralCount', v_direct_count,
    'todayRewardStoc', v_today_reward,
    'todayReferralCount', v_today_count,
    'yesterdayRewardStoc', v_yesterday_reward,
    'yesterdayReferralCount', v_yesterday_count,
    'totalRewardStoc', v_total_reward,
    'baseRewardStoc', v_base_reward,
    'currentLevel', v_current_level,
    'nextLevel', v_next_level,
    'levels', v_levels,
    'updatedAt', now()
  );
end;
$rpc_get_referral_reward_summary$;
revoke all on function public.rpc_get_referral_reward_summary() from public, anon;
grant execute on function public.rpc_get_referral_reward_summary() to authenticated;

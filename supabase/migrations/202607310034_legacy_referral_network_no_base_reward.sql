-- 034: Import certified legacy referral relations into current referral_network without base STOC rewards.
-- Policy:
-- 1) legacy-only referred members remain displayed as "비인증" and do not count for level rewards.
-- 2) When the legacy referred member is migrated/certified, import the relation into referral_network.
-- 3) Do not grant referred_signup/referrer_signup base rewards for imported legacy relations.
-- 4) Imported certified relations count toward direct referrals and can trigger level rewards only.

create or replace function private.grant_legacy_referral_level_rewards_only(
  p_referrer_user_id uuid,
  p_source_member_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_direct_count integer := 0;
  v_granted_count integer := 0;
  v_total_amount numeric(18, 6) := 0;
  v_level record;
  v_granted_levels jsonb := '[]'::jsonb;
begin
  if p_referrer_user_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'missing_referrer',
      'levelRewardGrantCount', 0,
      'levelRewardAmount', 0,
      'grantedLevels', '[]'::jsonb
    );
  end if;

  select count(*)::integer
    into v_direct_count
  from public.referral_network rn
  join public.member referred on referred.user_id = rn.referred_user_id
  where rn.referrer_user_id = p_referrer_user_id
    and rn.depth = 1
    and rn.status = 'active'
    and referred.status = 'active'
    and not coalesce(referred.is_del, false);

  for v_level in
    select level, reward_stoc
    from public.referral_reward_levels
    where is_active = true
      and required_referrals <= v_direct_count
    order by level asc
  loop
    if private.grant_referral_reward(
      p_referrer_user_id,
      p_source_member_id,
      'level_reward',
      v_level.level,
      v_level.reward_stoc
    ) then
      v_granted_count := v_granted_count + 1;
      v_total_amount := v_total_amount + coalesce(v_level.reward_stoc, 0);
      v_granted_levels := v_granted_levels || jsonb_build_array(jsonb_build_object(
        'level', v_level.level,
        'rewardStoc', v_level.reward_stoc
      ));
    end if;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'directReferralCount', v_direct_count,
    'levelRewardGrantCount', v_granted_count,
    'levelRewardAmount', v_total_amount,
    'grantedLevels', v_granted_levels
  );
end;
$$;
revoke all on function private.grant_legacy_referral_level_rewards_only(uuid, uuid)
  from public, anon, authenticated;
create or replace function public.service_import_legacy_referral_no_base_reward(
  p_referred_legacy_mb_id text,
  p_referrer_legacy_mb_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_referred_legacy_id text := trim(coalesce(p_referred_legacy_mb_id, ''));
  v_referrer_legacy_id text := trim(coalesce(p_referrer_legacy_mb_id, ''));
  v_referred_claim public.legacy_migration_claims%rowtype;
  v_referrer_claim public.legacy_migration_claims%rowtype;
  v_referred public.member%rowtype;
  v_referrer public.member%rowtype;
  v_existing_network_referrer uuid;
  v_existing_member_referrer uuid;
  v_relation_existed boolean := false;
  v_level_result jsonb;
  v_joined_at timestamptz;
begin
  if auth.role() <> 'service_role' then
    raise exception using errcode = '42501', message = 'SERVICE_ROLE_REQUIRED';
  end if;

  if v_referred_legacy_id = '' or v_referrer_legacy_id = '' then
    return jsonb_build_object(
      'ok', false,
      'code', 'legacy_referral_missing_id',
      'baseRewardGranted', false,
      'levelRewardGrantCount', 0
    );
  end if;

  if lower(v_referred_legacy_id) = lower(v_referrer_legacy_id) then
    return jsonb_build_object(
      'ok', false,
      'code', 'self_referral',
      'baseRewardGranted', false,
      'levelRewardGrantCount', 0
    );
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('legacy-referral-import:' || lower(v_referrer_legacy_id) || ':' || lower(v_referred_legacy_id), 0)
  );

  select *
    into v_referred_claim
    from public.legacy_migration_claims c
   where lower(c.legacy_mb_id) = lower(v_referred_legacy_id)
   limit 1
   for update;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'referred_legacy_not_claimed',
      'referredLegacyMbId', v_referred_legacy_id,
      'baseRewardGranted', false,
      'levelRewardGrantCount', 0
    );
  end if;

  select *
    into v_referrer_claim
    from public.legacy_migration_claims c
   where lower(c.legacy_mb_id) = lower(v_referrer_legacy_id)
   limit 1
   for update;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'referrer_legacy_not_claimed',
      'referrerLegacyMbId', v_referrer_legacy_id,
      'baseRewardGranted', false,
      'levelRewardGrantCount', 0
    );
  end if;

  select *
    into v_referred
    from public.member m
   where m.user_id = v_referred_claim.user_id
   for update;

  if not found or coalesce(v_referred.status, '') <> 'active' or coalesce(v_referred.is_del, false) then
    return jsonb_build_object(
      'ok', false,
      'code', 'referred_member_not_active',
      'referredUserId', v_referred_claim.user_id,
      'baseRewardGranted', false,
      'levelRewardGrantCount', 0
    );
  end if;

  select *
    into v_referrer
    from public.member m
   where m.user_id = v_referrer_claim.user_id
   for update;

  if not found or coalesce(v_referrer.status, '') <> 'active' or coalesce(v_referrer.is_del, false) then
    return jsonb_build_object(
      'ok', false,
      'code', 'referrer_member_not_active',
      'referrerUserId', v_referrer_claim.user_id,
      'baseRewardGranted', false,
      'levelRewardGrantCount', 0
    );
  end if;

  if v_referred.user_id = v_referrer.user_id then
    return jsonb_build_object(
      'ok', false,
      'code', 'self_referral',
      'baseRewardGranted', false,
      'levelRewardGrantCount', 0
    );
  end if;

  v_existing_member_referrer := v_referred.referrer_user_id;

  select rn.referrer_user_id
    into v_existing_network_referrer
    from public.referral_network rn
   where rn.referred_user_id = v_referred.user_id
     and rn.depth = 1
     and rn.status = 'active'
   order by rn.joined_at desc nulls last, rn.created_at desc nulls last
   limit 1;

  if v_existing_member_referrer is not null and v_existing_member_referrer <> v_referrer.user_id then
    return jsonb_build_object(
      'ok', false,
      'code', 'referred_already_has_other_referrer',
      'referredUserId', v_referred.user_id,
      'existingReferrerUserId', v_existing_member_referrer,
      'baseRewardGranted', false,
      'levelRewardGrantCount', 0
    );
  end if;

  if v_existing_network_referrer is not null and v_existing_network_referrer <> v_referrer.user_id then
    return jsonb_build_object(
      'ok', false,
      'code', 'referred_already_has_other_referral_network',
      'referredUserId', v_referred.user_id,
      'existingReferrerUserId', v_existing_network_referrer,
      'baseRewardGranted', false,
      'levelRewardGrantCount', 0
    );
  end if;

  v_relation_existed := v_existing_member_referrer = v_referrer.user_id
    and v_existing_network_referrer = v_referrer.user_id;

  perform set_config('sto.skip_referral_reward_trigger', 'on', true);

  update public.member
     set referrer_user_id = v_referrer.user_id,
         updated_at = now()
   where user_id = v_referred.user_id
     and referrer_user_id is null;

  v_joined_at := coalesce(v_referred_claim.completed_at, v_referred.created_at, now());

  insert into public.referral_network(
    referrer_user_id,
    referred_user_id,
    depth,
    status,
    joined_at
  ) values (
    v_referrer.user_id,
    v_referred.user_id,
    1,
    'active',
    v_joined_at
  )
  on conflict (referrer_user_id, referred_user_id, depth)
  do update set
    status = 'active',
    joined_at = coalesce(public.referral_network.joined_at, excluded.joined_at);

  v_level_result := private.grant_legacy_referral_level_rewards_only(
    v_referrer.user_id,
    v_referred.user_id
  );

  return jsonb_build_object(
    'ok', true,
    'code', case when v_relation_existed then 'already_imported' else 'imported' end,
    'reason', 'legacy_referral_import_no_base_reward',
    'referrerLegacyMbId', v_referrer_claim.legacy_mb_id,
    'referredLegacyMbId', v_referred_claim.legacy_mb_id,
    'referrerUserId', v_referrer.user_id,
    'referredUserId', v_referred.user_id,
    'joinedAt', v_joined_at,
    'baseRewardGranted', false,
    'referredBaseRewardGranted', false,
    'referrerBaseRewardGranted', false,
    'levelRewardGrantCount', coalesce((v_level_result->>'levelRewardGrantCount')::integer, 0),
    'levelRewardAmount', coalesce((v_level_result->>'levelRewardAmount')::numeric, 0),
    'levelReward', v_level_result
  );
end;
$$;
revoke all on function public.service_import_legacy_referral_no_base_reward(text, text)
  from public, anon, authenticated;
grant execute on function public.service_import_legacy_referral_no_base_reward(text, text)
  to service_role;

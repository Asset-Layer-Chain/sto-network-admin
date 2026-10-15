-- 035: Block direct reciprocal referrals and clean legacy reciprocal pairs during re-authentication.
-- Scope intentionally covers only direct A -> B / B -> A relationships. Multi-hop cycles are deferred.

create or replace function private.is_direct_reciprocal_referral(
  p_referrer_user_id uuid,
  p_referred_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, private, pg_temp
as $$
  select coalesce(p_referrer_user_id is not null and p_referred_user_id is not null, false)
    and p_referrer_user_id <> p_referred_user_id
    and (
      exists (
        select 1
          from public.referral_network rn
         where rn.referrer_user_id = p_referred_user_id
           and rn.referred_user_id = p_referrer_user_id
           and rn.depth = 1
           and rn.status = 'active'
      )
      or exists (
        select 1
          from public.member m
         where m.user_id = p_referrer_user_id
           and m.referrer_user_id = p_referred_user_id
           and m.status = 'active'
           and not coalesce(m.is_del, false)
      )
    );
$$;
revoke all on function private.is_direct_reciprocal_referral(uuid, uuid)
  from public, anon, authenticated;
create or replace function private.prevent_referrer_user_id_change()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
begin
  if current_setting('sto.allow_referrer_repair', true) = 'on' then
    return new;
  end if;

  if old.referrer_user_id is not null
     and new.referrer_user_id is distinct from old.referrer_user_id then
    raise exception using errcode = 'P0001', message = 'REFERRER_ALREADY_FIXED';
  end if;

  if new.referrer_user_id is not null
     and private.is_direct_reciprocal_referral(new.referrer_user_id, new.user_id) then
    raise exception using errcode = 'P0001', message = 'REFERRAL_RECIPROCAL_BLOCKED';
  end if;

  return new;
end;
$$;
create or replace function private.prevent_direct_reciprocal_referral_network()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
begin
  if current_setting('sto.allow_referrer_repair', true) = 'on' then
    return new;
  end if;

  if new.depth = 1
     and new.status = 'active'
     and private.is_direct_reciprocal_referral(new.referrer_user_id, new.referred_user_id) then
    raise exception using errcode = 'P0001', message = 'REFERRAL_RECIPROCAL_BLOCKED';
  end if;

  return new;
end;
$$;
revoke all on function private.prevent_direct_reciprocal_referral_network()
  from public, anon, authenticated;
drop trigger if exists referral_network_reciprocal_guard_trg on public.referral_network;
create trigger referral_network_reciprocal_guard_trg
before insert or update of referrer_user_id, referred_user_id, depth, status
on public.referral_network
for each row
execute function private.prevent_direct_reciprocal_referral_network();
create or replace function public.service_clear_legacy_reciprocal_referrals(
  p_first_legacy_mb_id text,
  p_second_legacy_mb_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_first_legacy_id text := trim(coalesce(p_first_legacy_mb_id, ''));
  v_second_legacy_id text := trim(coalesce(p_second_legacy_mb_id, ''));
  v_first_claim public.legacy_migration_claims%rowtype;
  v_second_claim public.legacy_migration_claims%rowtype;
  v_member_clear_count integer := 0;
  v_network_block_count integer := 0;
  v_lock_key text;
begin
  if auth.role() <> 'service_role' then
    raise exception using errcode = '42501', message = 'SERVICE_ROLE_REQUIRED';
  end if;

  if v_first_legacy_id = '' or v_second_legacy_id = '' then
    return jsonb_build_object(
      'ok', false,
      'code', 'legacy_reciprocal_missing_id',
      'cleared', false,
      'memberClearCount', 0,
      'networkBlockCount', 0
    );
  end if;

  if lower(v_first_legacy_id) = lower(v_second_legacy_id) then
    return jsonb_build_object(
      'ok', false,
      'code', 'self_referral',
      'cleared', false,
      'memberClearCount', 0,
      'networkBlockCount', 0
    );
  end if;

  v_lock_key := 'legacy-reciprocal-referral:' || least(lower(v_first_legacy_id), lower(v_second_legacy_id)) || ':' || greatest(lower(v_first_legacy_id), lower(v_second_legacy_id));
  perform pg_advisory_xact_lock(hashtextextended(v_lock_key, 0));

  select *
    into v_first_claim
    from public.legacy_migration_claims c
   where lower(c.legacy_mb_id) = lower(v_first_legacy_id)
   limit 1
   for update;

  select *
    into v_second_claim
    from public.legacy_migration_claims c
   where lower(c.legacy_mb_id) = lower(v_second_legacy_id)
   limit 1
   for update;

  if v_first_claim.user_id is null or v_second_claim.user_id is null then
    return jsonb_build_object(
      'ok', true,
      'code', 'legacy_reciprocal_pending_claim',
      'cleared', false,
      'firstLegacyMbId', v_first_legacy_id,
      'secondLegacyMbId', v_second_legacy_id,
      'memberClearCount', 0,
      'networkBlockCount', 0
    );
  end if;

  perform set_config('sto.allow_referrer_repair', 'on', true);
  perform set_config('sto.skip_referral_reward_trigger', 'on', true);

  update public.member m
     set referrer_user_id = null,
         updated_at = now()
   where (
       m.user_id = v_first_claim.user_id
       and m.referrer_user_id = v_second_claim.user_id
     )
      or (
       m.user_id = v_second_claim.user_id
       and m.referrer_user_id = v_first_claim.user_id
     );
  get diagnostics v_member_clear_count = row_count;

  update public.referral_network rn
     set status = 'blocked'
   where rn.depth = 1
     and rn.status = 'active'
     and (
       (
         rn.referrer_user_id = v_first_claim.user_id
         and rn.referred_user_id = v_second_claim.user_id
       )
       or (
         rn.referrer_user_id = v_second_claim.user_id
         and rn.referred_user_id = v_first_claim.user_id
       )
     );
  get diagnostics v_network_block_count = row_count;

  return jsonb_build_object(
    'ok', true,
    'code', 'legacy_reciprocal_cleared',
    'cleared', (v_member_clear_count + v_network_block_count) > 0,
    'firstLegacyMbId', v_first_legacy_id,
    'secondLegacyMbId', v_second_legacy_id,
    'firstUserId', v_first_claim.user_id,
    'secondUserId', v_second_claim.user_id,
    'memberClearCount', v_member_clear_count,
    'networkBlockCount', v_network_block_count,
    'baseRewardReversed', false,
    'levelRewardReversed', false
  );
end;
$$;
revoke all on function public.service_clear_legacy_reciprocal_referrals(text, text)
  from public, anon, authenticated;
grant execute on function public.service_clear_legacy_reciprocal_referrals(text, text)
  to service_role;
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

  if private.is_direct_reciprocal_referral(v_referrer.user_id, v_referred.user_id) then
    return jsonb_build_object(
      'ok', false,
      'code', 'direct_reciprocal_referral',
      'message', '서로 추천인으로 등록할 수 없습니다.',
      'referrerLegacyMbId', v_referrer_claim.legacy_mb_id,
      'referredLegacyMbId', v_referred_claim.legacy_mb_id,
      'referrerUserId', v_referrer.user_id,
      'referredUserId', v_referred.user_id,
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
create or replace function public.rpc_register_referrer_by_code(
  p_referral_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_referrer public.member%rowtype;
  v_input text := trim(coalesce(p_referral_code, ''));
  v_existing_referrer uuid;
  v_reward_result jsonb;
  v_updated_count integer := 0;
begin
  v_member := private.require_active_member();

  perform pg_advisory_xact_lock(
    hashtextextended('register-referrer:' || v_member.user_id::text, 0)
  );

  select * into v_member
    from public.member m
   where m.user_id = v_member.user_id
     and m.status = 'active'
     and not coalesce(m.is_del, false)
   for update;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'member_not_found',
      'message', '회원 정보를 찾을 수 없습니다.'
    );
  end if;

  if v_input = '' then
    return jsonb_build_object(
      'ok', false,
      'code', 'empty_referral_code',
      'message', '추천인 ID를 입력해주세요.'
    );
  end if;

  select rn.referrer_user_id
    into v_existing_referrer
    from public.referral_network rn
   where rn.referred_user_id = v_member.user_id
     and rn.depth = 1
     and rn.status = 'active'
   order by rn.joined_at desc nulls last, rn.created_at desc nulls last
   limit 1;

  if v_member.referrer_user_id is not null or v_existing_referrer is not null then
    return jsonb_build_object(
      'ok', false,
      'code', 'already_has_referrer',
      'message', '이미 추천인 ID가 등록되어 있습니다.'
    );
  end if;

  select * into v_referrer
    from public.member m
   where m.status = 'active'
     and not coalesce(m.is_del, false)
     and (
       lower(m.referral_code) = lower(v_input)
       or lower(m.mb_id) = lower(v_input)
     )
   order by case when lower(m.referral_code) = lower(v_input) then 0 else 1 end
   limit 1;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'not_found',
      'message', '추천인 ID를 찾을 수 없습니다.'
    );
  end if;

  if v_referrer.user_id = v_member.user_id then
    return jsonb_build_object(
      'ok', false,
      'code', 'self_referral',
      'message', '본인의 추천인 ID는 입력할 수 없습니다.'
    );
  end if;

  if private.is_direct_reciprocal_referral(v_referrer.user_id, v_member.user_id) then
    return jsonb_build_object(
      'ok', false,
      'code', 'direct_reciprocal_referral',
      'message', '서로 추천인으로 등록할 수 없습니다. 기존 추천 관계를 확인해주세요.'
    );
  end if;

  perform set_config('sto.skip_referral_reward_trigger', 'on', true);

  update public.member
     set referrer_user_id = v_referrer.user_id,
         updated_at = now()
   where user_id = v_member.user_id
     and referrer_user_id is null;

  get diagnostics v_updated_count = row_count;

  if v_updated_count <> 1 then
    return jsonb_build_object(
      'ok', false,
      'code', 'already_has_referrer',
      'message', '이미 추천인 ID가 등록되어 있습니다.'
    );
  end if;

  v_reward_result := private.apply_referral_rewards(v_member.user_id, v_referrer.user_id);

  return jsonb_build_object(
    'ok', true,
    'message', '추천인 ID가 등록되었습니다.',
    'reward', v_reward_result,
    'referrer', jsonb_build_object(
      'user_id', v_referrer.user_id,
      'mb_id', v_referrer.mb_id,
      'mb_name', v_referrer.mb_name,
      'referral_code', v_referrer.referral_code
    )
  );
end;
$$;
revoke all on function public.rpc_register_referrer_by_code(text) from public, anon;
grant execute on function public.rpc_register_referrer_by_code(text) to authenticated;

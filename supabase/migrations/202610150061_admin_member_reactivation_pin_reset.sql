-- 061: Headquarters-only member reactivation and PIN reset.
-- Migration 058 and earlier migrations are immutable. This migration redefines
-- the existing RPCs using their latest definitions and appends a PIN reset RPC.
-- Apply this migration before deploying the updated admin UI.

create or replace function public.rpc_admin_get_session()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_grade text;
  v_grade_label text;
begin
  v_admin := private.require_admin();
  v_grade := private.admin_grade_for(v_admin.user_id, v_admin.role);
  v_grade_label := case v_grade
    when 'team_lead' then '팀장급'
    when 'center_director' then '센터장'
    when 'headquarters' then '본부'
    else '자산 권한 미설정'
  end;

  return jsonb_build_object(
    'userId', v_admin.user_id,
    'memberNo', v_admin.mb_no,
    'memberId', v_admin.mb_id,
    'name', v_admin.mb_name,
    'email', v_admin.mb_email,
    'profile', v_admin.mb_profile,
    'role', v_admin.role,
    'adminGrade', v_grade,
    'adminGradeLabel', v_grade_label,
    'permissions', jsonb_build_object(
      'memberRead', true,
      'memberListBrowse', v_grade is distinct from 'team_lead',
      'memberSearch', true,
      'assetDeposit', v_grade = 'headquarters',
      'assetWithdrawal', v_grade in ('center_director', 'headquarters'),
      'assetAirdrop', v_grade in ('team_lead', 'center_director', 'headquarters'),
      'reasonPresetManage', v_grade in ('center_director', 'headquarters'),
      'bulkDepositManage', v_grade = 'headquarters',
      'memberReactivate', v_grade = 'headquarters',
      'memberPinReset', v_grade = 'headquarters',
      'chatManage', true,
      'adminLogRead', true
    )
  );
end;
$$;
revoke all on function public.rpc_admin_get_session() from public, anon;
grant execute on function public.rpc_admin_get_session() to authenticated;

create or replace function public.rpc_admin_reactivate_member(
  p_user_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_admin_grade text;
  v_target public.member%rowtype;
  v_request public.member_deletion_requests%rowtype;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
  v_auth_user_exists boolean := false;
  v_released_identifier_count integer := 0;
  v_log_id uuid;
  v_before jsonb;
  v_after jsonb;
begin
  v_admin := private.require_admin();
  v_admin_grade := private.admin_grade_for(v_admin.user_id, v_admin.role);

  -- Only active headquarters administrators may reactivate deleted accounts.
  if coalesce(v_admin_grade, '') <> 'headquarters' then
    raise exception using
      errcode = 'P0001',
      message = 'MEMBER_REACTIVATION_PERMISSION_DENIED';
  end if;

  if p_user_id is null then
    raise exception using errcode = 'P0001', message = 'MEMBER_REQUIRED';
  end if;

  if v_reason is null or char_length(v_reason) < 2 then
    raise exception using errcode = 'P0001', message = 'MEMBER_REACTIVATION_REASON_REQUIRED';
  end if;

  if char_length(v_reason) > 500 then
    raise exception using errcode = 'P0001', message = 'MEMBER_REACTIVATION_REASON_TOO_LONG';
  end if;

  -- Use the same advisory-lock namespace as deletion so delete/reactivate cannot
  -- race each other for the same member.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('member-delete:' || p_user_id::text, 0)
  );

  select *
    into v_target
    from public.member m
   where m.user_id = p_user_id
   for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_FOUND';
  end if;

  if not coalesce(v_target.is_del, false)
     and v_target.status is distinct from 'deleted' then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_DELETED';
  end if;

  select exists (
    select 1
      from auth.users au
     where au.id = p_user_id
  ) into v_auth_user_exists;

  if not v_auth_user_exists then
    raise exception using errcode = 'P0001', message = 'MEMBER_AUTH_USER_NOT_FOUND';
  end if;

  -- Lock the deletion request when one exists. Older soft-deleted members may
  -- not have a request row, so its absence does not block recovery.
  select *
    into v_request
    from public.member_deletion_requests mdr
   where mdr.user_id = p_user_id
   for update;

  v_before := jsonb_build_object(
    'status', v_target.status,
    'isDel', coalesce(v_target.is_del, false),
    'deletedAt', v_target.deleted_at,
    'deletionReasonCode', v_target.deletion_reason_code,
    'deletionReasonText', v_target.deletion_reason_text,
    'marketingAgreed', v_target.marketing_agreed,
    'pushNotificationsEnabled', v_target.push_notifications_enabled,
    'deletionRequestId', v_request.id,
    'deletionRequestStatus', v_request.status
  );

  update public.member m
     set status = 'active',
         is_del = false,
         deleted_at = null,
         deletion_reason_code = null,
         deletion_reason_text = null,
         updated_at = now()
   where m.user_id = p_user_id;

  -- Recovered members must no longer be blocked by the deleted-identifier
  -- reservation. A future deletion will recreate these hashes.
  delete from public.deleted_member_identifiers d
   where d.user_id = p_user_id;
  get diagnostics v_released_identifier_count = row_count;

  if v_request.id is not null then
    update public.member_deletion_requests mdr
       set status = 'cancelled',
           metadata = coalesce(mdr.metadata, '{}'::jsonb) || jsonb_build_object(
             'contactRequiredForReactivation', false,
             'reactivatedAt', now(),
             'reactivatedBy', v_admin.user_id,
             'reactivationAdminGrade', v_admin_grade,
             'reactivationReason', v_reason
           ),
           updated_at = now()
     where mdr.id = v_request.id;
  end if;

  -- Deletion deliberately revoked marketing/push consent and deactivated push
  -- registrations. Do not silently restore either; the user must opt in again.
  select jsonb_build_object(
    'status', m.status,
    'isDel', coalesce(m.is_del, false),
    'deletedAt', m.deleted_at,
    'deletionReasonCode', m.deletion_reason_code,
    'deletionReasonText', m.deletion_reason_text,
    'marketingAgreed', m.marketing_agreed,
    'pushNotificationsEnabled', m.push_notifications_enabled,
    'deletionRequestStatus', (
      select mdr.status
        from public.member_deletion_requests mdr
       where mdr.user_id = p_user_id
    )
  )
    into v_after
    from public.member m
   where m.user_id = p_user_id;

  insert into public.admin_action_logs(
    actor_user_id,
    action_type,
    target_user_id,
    reason,
    before_data,
    after_data,
    metadata
  ) values (
    v_admin.user_id,
    'member.reactivate',
    p_user_id,
    v_reason,
    v_before,
    v_after,
    jsonb_build_object(
      'targetMemberId', v_target.mb_id,
      'adminGrade', v_admin_grade,
      'deletionRequestId', v_request.id,
      'releasedIdentifierCount', v_released_identifier_count,
      'authUserPreserved', true,
      'walletBalancesPreserved', true,
      'transactionsPreserved', true,
      'marketingConsentRestored', false,
      'pushRegistrationRestored', false
    )
  ) returning id into v_log_id;

  return jsonb_build_object(
    'reactivated', true,
    'userId', p_user_id,
    'memberId', v_target.mb_id,
    'status', 'active',
    'isDel', false,
    'deletionRequestId', v_request.id,
    'releasedIdentifierCount', v_released_identifier_count,
    'marketingConsentRestored', false,
    'pushRegistrationRestored', false,
    'adminGrade', v_admin_grade,
    'adminLogId', v_log_id
  );
end;
$$;
revoke all on function public.rpc_admin_reactivate_member(uuid, text)
from public, anon;
grant execute on function public.rpc_admin_reactivate_member(uuid, text)
to authenticated;
comment on function public.rpc_admin_reactivate_member(uuid, text) is
  'Reactivates a soft-deleted member while preserving wallets/transactions. Requires headquarters admin grade; marketing/push opt-ins remain revoked.';

-- Reset an active member's PIN to the agreed operational default.
-- Do not return/log PIN hashes. The supplied precomputed hash is bcrypt(000000).
create or replace function public.rpc_admin_reset_member_pin(
  p_user_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_admin_grade text;
  v_target public.member%rowtype;
  v_reason text := nullif(pg_catalog.btrim(coalesce(p_reason, '')), '');
  v_had_security boolean;
  v_log_id uuid;
begin
  v_admin := private.require_admin();
  v_admin_grade := private.admin_grade_for(v_admin.user_id, v_admin.role);
  if coalesce(v_admin_grade, '') <> 'headquarters' then
    raise exception using errcode = 'P0001', message = 'MEMBER_PIN_RESET_PERMISSION_DENIED';
  end if;
  if p_user_id is null then
    raise exception using errcode = 'P0001', message = 'MEMBER_REQUIRED';
  end if;
  if v_reason is null or pg_catalog.char_length(v_reason) < 2 then
    raise exception using errcode = 'P0001', message = 'MEMBER_PIN_RESET_REASON_REQUIRED';
  end if;
  if pg_catalog.char_length(v_reason) > 500 then
    raise exception using errcode = 'P0001', message = 'MEMBER_PIN_RESET_REASON_TOO_LONG';
  end if;

  -- Lock the member to serialize with deletion/reactivation on the same row.
  select * into v_target
    from public.member m
   where m.user_id = p_user_id
   for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_FOUND';
  end if;
  if coalesce(v_target.is_del, false) or v_target.status = 'deleted' then
    raise exception using errcode = 'P0001', message = 'MEMBER_DELETED';
  end if;
  if v_target.status <> 'active' then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_ACTIVE';
  end if;

  select exists(
    select 1 from public.member_security ms where ms.user_id = p_user_id
  ) into v_had_security;

  insert into public.member_security (
    user_id, pin_hash, pin_updated_at, failed_attempts,
    locked_until, last_failed_at, updated_at
  ) values (
    p_user_id,
    '$2a$10$8RZ.v5qe1LFjRAQvZYR9AOLTWw0fiqxYMx1BqbEjq2fDW2yoDc1SS',
    now(), 0, null, null, now()
  )
  on conflict (user_id) do update set
    pin_hash = excluded.pin_hash,
    pin_updated_at = excluded.pin_updated_at,
    failed_attempts = 0,
    locked_until = null,
    last_failed_at = null,
    updated_at = now();

  -- IP throttles have opaque hash keys; rpc_verify_pin_login invalidates
  -- stale throttle entries when the member first signs in after this reset.
  insert into public.admin_action_logs(
    actor_user_id, action_type, target_user_id, reason,
    before_data, after_data, metadata
  ) values (
    v_admin.user_id,
    'member.pin_reset',
    p_user_id,
    v_reason,
    pg_catalog.jsonb_build_object('pinSecurityRowExisted', v_had_security),
    pg_catalog.jsonb_build_object('pinResetAt', now(), 'failedAttempts', 0, 'lockedUntil', null),
    pg_catalog.jsonb_build_object('targetMemberId', v_target.mb_id, 'adminGrade', v_admin_grade)
  ) returning id into v_log_id;

  return pg_catalog.jsonb_build_object(
    'reset', true,
    'userId', p_user_id,
    'memberId', v_target.mb_id,
    'adminLogId', v_log_id
  );
end;
$$;
revoke all on function public.rpc_admin_reset_member_pin(uuid, text) from public, anon;
grant execute on function public.rpc_admin_reset_member_pin(uuid, text) to authenticated;
comment on function public.rpc_admin_reset_member_pin(uuid, text) is
  'Headquarters-only member PIN reset with lock clearing and audit logging. Never returns a PIN hash.';


create or replace function public.rpc_verify_pin_login(
  p_member_id text,
  p_pin text,
  p_ip_hash text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_security public.member_security%rowtype;
  v_key text := private.signup_hash(lower(trim(coalesce(p_member_id, ''))) || ':' || coalesce(nullif(trim(p_ip_hash), ''), 'no-ip'));
  v_throttle public.pin_login_throttle%rowtype;
  v_success boolean := false;
  v_next_attempts integer;
  v_locked_until timestamptz;
begin
  perform pg_advisory_xact_lock(hashtextextended('pin-login:' || v_key, 0));

  select * into v_throttle
    from public.pin_login_throttle
   where throttle_key = v_key
   for update;

  -- Read member + PIN rotation time before evaluating an old IP lock. Keep
  -- FOR UPDATE to serialize this check with an administrator PIN reset.
  select * into v_member
    from public.member
   where lower(mb_id) = lower(trim(coalesce(p_member_id, '')))
   limit 1
   for update;

  if found and not v_member.is_del and v_member.status = 'active' then
    select * into v_security
      from public.member_security
     where user_id = v_member.user_id
     for update;

    -- The throttle key is a one-way hash of member ID and IP. It cannot be
    -- enumerated during reset, so expire only the current IP's stale lock
    -- when it predates the latest PIN change.
    if v_security.pin_updated_at is not null
       and v_throttle.last_failed_at is not null
       and v_throttle.last_failed_at < v_security.pin_updated_at then
      delete from public.pin_login_throttle where throttle_key = v_key;
      v_throttle.failed_attempts := 0;
      v_throttle.locked_until := null;
      v_throttle.last_failed_at := null;
    end if;
  end if;

  if v_throttle.locked_until is not null and v_throttle.locked_until > now() then
    return jsonb_build_object(
      'verified', false,
      'error', 'PIN_LOGIN_TEMPORARILY_LOCKED',
      'lockedUntil', v_throttle.locked_until
    );
  end if;

  if v_throttle.last_failed_at is not null
     and v_throttle.last_failed_at > now() - interval '1 second' then
    return jsonb_build_object('verified', false, 'error', 'PIN_LOGIN_TRY_AGAIN');
  end if;

  if v_member.user_id is not null and not v_member.is_del and v_member.status = 'active' then
    if v_security.user_id is not null and v_security.locked_until is not null and v_security.locked_until > now() then
      return jsonb_build_object(
        'verified', false,
        'error', 'PIN_LOGIN_TEMPORARILY_LOCKED',
        'lockedUntil', v_security.locked_until
      );
    end if;

    v_success := v_security.pin_hash is not null
      and coalesce(p_pin, '') ~ '^[0-9]{6}$'
      and extensions.crypt(p_pin, v_security.pin_hash) = v_security.pin_hash;
  end if;

  if not v_success then
    v_next_attempts := coalesce(v_throttle.failed_attempts, 0) + 1;
    v_locked_until := case when v_next_attempts >= 5 then now() + interval '15 minutes' else null end;

    insert into public.pin_login_throttle(
      throttle_key,
      failed_attempts,
      locked_until,
      last_failed_at
    ) values (
      v_key,
      v_next_attempts,
      v_locked_until,
      now()
    )
    on conflict (throttle_key) do update set
      failed_attempts = excluded.failed_attempts,
      last_failed_at = excluded.last_failed_at,
      locked_until = excluded.locked_until,
      updated_at = now();

    if v_member.user_id is not null then
      update public.member_security
         set failed_attempts = failed_attempts + 1,
             last_failed_at = now(),
             locked_until = case when failed_attempts + 1 >= 5 then now() + interval '15 minutes' else null end,
             updated_at = now()
       where user_id = v_member.user_id;
    end if;

    return jsonb_build_object(
      'verified', false,
      'error', case when v_locked_until is not null then 'PIN_LOGIN_TEMPORARILY_LOCKED' else 'INVALID_MEMBER_ID_OR_PIN' end,
      'remainingAttempts', greatest(0, 5 - v_next_attempts),
      'lockedUntil', v_locked_until
    );
  end if;

  delete from public.pin_login_throttle where throttle_key = v_key;
  update public.member_security
     set failed_attempts = 0,
         locked_until = null,
         last_failed_at = null,
         last_login_at = now(),
         updated_at = now()
   where user_id = v_member.user_id;
  update public.member
     set last_login_at = now(),
         updated_at = now()
   where user_id = v_member.user_id;

  return jsonb_build_object('verified', true, 'userId', v_member.user_id);
end;
$$;
revoke all on function public.rpc_verify_pin_login(text, text, text) from public, anon, authenticated;
grant execute on function public.rpc_verify_pin_login(text, text, text) to service_role;

notify pgrst, 'reload schema';

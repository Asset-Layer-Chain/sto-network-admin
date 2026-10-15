-- 058: Admin reactivation for soft-deleted members.
--
-- The normal member-deletion flow intentionally preserves auth.users, wallets,
-- transactions, referral data, and other service history. Reactivation therefore
-- restores only account access state and releases the deleted-identifier guard.
-- Marketing/push consent and device activation are intentionally NOT restored;
-- the member must opt in/register again after returning to the service.

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

  -- Reactivation changes account-access state, so keep it above team-lead scope.
  if coalesce(v_admin_grade, '') not in ('center_director', 'headquarters') then
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
  'Reactivates a soft-deleted member while preserving wallets/transactions. Requires center_director or headquarters admin grade; marketing/push opt-ins remain revoked.';

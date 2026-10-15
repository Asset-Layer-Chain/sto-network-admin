-- 023. Marketing popup consent persistence and last-login snapshot fix.

create or replace function private.member_client_snapshot(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_wallet_summary jsonb;
begin
  select * into v_member
    from public.member
   where user_id = p_user_id;

  if not found then
    return 'null'::jsonb;
  end if;

  v_wallet_summary := private.wallet_summary(p_user_id);

  return jsonb_build_object(
    'user_id', v_member.user_id,
    'mb_no', v_member.mb_no,
    'mb_id', v_member.mb_id,
    'mb_name', v_member.mb_name,
    'mb_email', v_member.mb_email,
    'mb_hp', v_member.mb_hp,
    'mb_profile', v_member.mb_profile,
    'status', v_member.status,
    'role', v_member.role,
    'locale', coalesce(v_member.locale, 'ko'),
    'is_del', v_member.is_del,
    'referral_code', v_member.referral_code,
    'referrer_user_id', v_member.referrer_user_id,
    'marketing_agreed', coalesce(v_member.marketing_agreed, false),
    'push_notifications_enabled', coalesce(v_member.push_notifications_enabled, false),
    'last_login_at', v_member.last_login_at
  ) || v_wallet_summary;
end;
$$;
create or replace function public.rpc_touch_member_last_login()
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_member public.member%rowtype;
begin
  if auth.uid() is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  v_member := private.require_active_member();

  update public.member
     set last_login_at = now(),
         updated_at = now()
   where user_id = v_member.user_id
   returning * into v_member;

  return jsonb_build_object(
    'lastLoginAt', v_member.last_login_at,
    'member', private.member_client_snapshot(v_member.user_id)
  );
end;
$$;
create or replace function public.rpc_update_member_consent(
  p_consent_type text,
  p_status text,
  p_source text default 'settings'
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_type text := lower(trim(coalesce(p_consent_type, '')));
  v_status text := lower(trim(coalesce(p_status, '')));
  v_source text := left(coalesce(nullif(trim(p_source), ''), 'settings'), 50);
  v_consent public.member_consents%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  if v_type not in ('marketing_push', 'benefit_push') then
    raise exception using errcode = 'P0001', message = 'INVALID_CONSENT_TYPE';
  end if;

  if v_status not in ('agreed', 'declined') then
    raise exception using errcode = 'P0001', message = 'INVALID_CONSENT_STATUS';
  end if;

  perform private.require_active_member();
  perform pg_advisory_xact_lock(hashtextextended('member-consent:' || v_user_id::text || ':' || v_type, 0));

  insert into public.member_consents (
    user_id,
    consent_type,
    status,
    policy_version,
    source,
    prompted_at,
    consented_at,
    declined_at,
    deferred_at,
    deferred_until
  ) values (
    v_user_id,
    v_type,
    v_status,
    '2025-01-15',
    v_source,
    now(),
    case when v_status = 'agreed' then now() else null end,
    case when v_status = 'declined' then now() else null end,
    case when v_status = 'declined' then now() else null end,
    case when v_status = 'declined' then now() + interval '5 hours' else null end
  )
  on conflict (user_id, consent_type)
  do update set
    status = excluded.status,
    policy_version = excluded.policy_version,
    source = excluded.source,
    prompted_at = coalesce(member_consents.prompted_at, excluded.prompted_at),
    consented_at = case when excluded.status = 'agreed' then now() else null end,
    declined_at = case when excluded.status = 'declined' then now() else null end,
    deferred_at = case when excluded.status = 'declined' then now() else null end,
    deferred_until = case when excluded.status = 'declined' then now() + interval '5 hours' else null end,
    updated_at = now()
  returning * into v_consent;

  if v_type = 'marketing_push' then
    update public.member
       set marketing_agreed = (v_status = 'agreed'),
           updated_at = now()
     where user_id = v_user_id;
  else
    update public.member
       set push_notifications_enabled = (v_status = 'agreed'),
           updated_at = now()
     where user_id = v_user_id;
  end if;

  return jsonb_build_object(
    'consent', jsonb_build_object(
      'type', v_consent.consent_type,
      'status', v_consent.status,
      'policyVersion', v_consent.policy_version,
      'source', v_consent.source,
      'consentedAt', v_consent.consented_at,
      'declinedAt', v_consent.declined_at,
      'deferredAt', v_consent.deferred_at,
      'deferredUntil', v_consent.deferred_until,
      'updatedAt', v_consent.updated_at
    ),
    'member', private.member_client_snapshot(v_user_id)
  );
end;
$$;
create or replace function public.rpc_update_popup_consents(
  p_status text,
  p_source text default 'app_popup'
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_status text := lower(trim(coalesce(p_status, '')));
  v_source text := left(coalesce(nullif(trim(p_source), ''), 'app_popup'), 50);
  v_marketing jsonb;
  v_benefit_push jsonb;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  if v_status not in ('agreed', 'declined') then
    raise exception using errcode = 'P0001', message = 'INVALID_MARKETING_CONSENT_STATUS';
  end if;

  perform private.require_active_member();
  perform pg_advisory_xact_lock(hashtextextended('popup-consent-bundle:' || v_user_id::text, 0));

  v_marketing := public.rpc_update_member_consent('marketing_push', v_status, v_source);
  v_benefit_push := public.rpc_update_member_consent('benefit_push', v_status, v_source);

  return jsonb_build_object(
    'status', v_status,
    'consents', jsonb_build_object(
      'marketing', v_marketing -> 'consent',
      'benefitPush', v_benefit_push -> 'consent'
    ),
    'member', private.member_client_snapshot(v_user_id)
  );
end;
$$;
revoke all on function public.rpc_touch_member_last_login() from public, anon;
revoke all on function public.rpc_update_member_consent(text, text, text) from public, anon;
revoke all on function public.rpc_update_popup_consents(text, text) from public, anon;
grant execute on function public.rpc_touch_member_last_login() to authenticated;
grant execute on function public.rpc_update_member_consent(text, text, text) to authenticated;
grant execute on function public.rpc_update_popup_consents(text, text) to authenticated;

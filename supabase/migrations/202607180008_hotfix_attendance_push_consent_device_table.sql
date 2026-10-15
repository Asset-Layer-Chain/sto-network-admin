-- Hotfix: restore member device storage, debounce consent reminder popup,
-- and add attendance reminder push target/logging support.

-- -----------------------------------------------------------------------------
-- 1. Device table restore/hardening
-- -----------------------------------------------------------------------------
create table if not exists public.member_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.member(user_id) on delete cascade,
  platform text not null default 'android' check (platform in ('web', 'android', 'ios')),
  device_id text,
  push_token text,
  app_version text,
  locale text,
  timezone text not null default 'Asia/Seoul',
  is_active boolean not null default true,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, platform, device_id)
);
alter table public.member_devices
  add column if not exists locale text,
  add column if not exists timezone text not null default 'Asia/Seoul',
  add column if not exists is_active boolean not null default true;
create unique index if not exists member_devices_push_token_uidx
  on public.member_devices(push_token)
  where push_token is not null;
create index if not exists member_devices_user_active_idx
  on public.member_devices(user_id, is_active, last_seen_at desc);
create index if not exists member_devices_active_push_token_idx
  on public.member_devices(push_token)
  where push_token is not null and is_active = true;
do $$
begin
  if not exists (
    select 1
      from pg_trigger
     where tgname = 'member_devices_set_updated_at'
       and tgrelid = 'public.member_devices'::regclass
  ) then
    create trigger member_devices_set_updated_at
    before update on public.member_devices
    for each row execute function public.set_updated_at();
  end if;
end;
$$;
alter table public.member_devices enable row level security;
revoke all on public.member_devices from public, anon, authenticated;
drop policy if exists member_devices_select_self on public.member_devices;
create policy member_devices_select_self
on public.member_devices for select to authenticated
using (
  user_id = (select auth.uid())
  and exists (
    select 1
      from public.member m
     where m.user_id = (select auth.uid())
       and m.is_del = false
       and m.status = 'active'
  )
);
-- Keep device writes behind the RPC.
create or replace function public.rpc_upsert_member_device(
  p_platform text,
  p_device_id text,
  p_push_token text default null,
  p_app_version text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_platform text := lower(trim(coalesce(p_platform, '')));
  v_device_id text := nullif(trim(coalesce(p_device_id, '')), '');
  v_push_token text := nullif(trim(coalesce(p_push_token, '')), '');
  v_device public.member_devices%rowtype;
begin
  v_member := private.require_active_member();

  if v_platform not in ('web', 'android', 'ios') then
    raise exception using errcode = '22023', message = 'INVALID_PLATFORM';
  end if;

  if v_device_id is null then
    raise exception using errcode = '22023', message = 'DEVICE_ID_REQUIRED';
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended('member-device:' || v_member.user_id::text || ':' || v_platform || ':' || v_device_id, 0)
  );

  if v_push_token is not null then
    update public.member_devices
       set push_token = null,
           is_active = false,
           updated_at = now()
     where push_token = v_push_token
       and not (
         user_id = v_member.user_id
         and platform = v_platform
         and device_id = v_device_id
       );
  end if;

  insert into public.member_devices (
    user_id,
    platform,
    device_id,
    push_token,
    app_version,
    is_active,
    last_seen_at
  ) values (
    v_member.user_id,
    v_platform,
    v_device_id,
    v_push_token,
    nullif(trim(coalesce(p_app_version, '')), ''),
    true,
    now()
  )
  on conflict (user_id, platform, device_id)
  do update set
    push_token = excluded.push_token,
    app_version = excluded.app_version,
    is_active = true,
    last_seen_at = now(),
    updated_at = now()
  returning * into v_device;

  return to_jsonb(v_device);
end;
$$;
revoke all on function public.rpc_upsert_member_device(text, text, text, text) from public, anon, authenticated;
grant execute on function public.rpc_upsert_member_device(text, text, text, text) to authenticated;
-- -----------------------------------------------------------------------------
-- 2. Consent popup 5-hour server-side snooze
-- -----------------------------------------------------------------------------
alter table public.member_consents
  add column if not exists deferred_until timestamptz,
  add column if not exists deferred_at timestamptz;
create index if not exists member_consents_deferred_until_idx
  on public.member_consents(user_id, consent_type, deferred_until);
create or replace function public.rpc_get_app_popup_state()
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_member public.member%rowtype;
  v_reward public.member_welcome_rewards%rowtype;
  v_marketing_consent public.member_consents%rowtype;
  v_benefit_push_consent public.member_consents%rowtype;
  v_reward_found boolean := false;
  v_marketing_agreed boolean := false;
  v_benefit_push_agreed boolean := false;
  v_missing text[] := array[]::text[];
  v_prompt_missing text[] := array[]::text[];
  v_should_show_consent boolean := false;
  v_next_prompt_at timestamptz := null;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  select * into v_member
    from public.member
   where user_id = v_user_id
     and status = 'active'
     and coalesce(is_del, false) = false;

  if not found then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_FOUND';
  end if;

  v_marketing_agreed := coalesce(v_member.marketing_agreed, false);
  v_benefit_push_agreed := coalesce(v_member.push_notifications_enabled, false);

  insert into public.member_consents (
    user_id,
    consent_type,
    status,
    policy_version,
    source,
    prompted_at,
    consented_at,
    declined_at
  ) values
  (
    v_user_id,
    'marketing_push',
    case when v_marketing_agreed then 'agreed' else 'pending' end,
    '2025-01-15',
    'app_popup',
    case when v_marketing_agreed then now() else null end,
    case when v_marketing_agreed then now() else null end,
    null
  ),
  (
    v_user_id,
    'benefit_push',
    case when v_benefit_push_agreed then 'agreed' else 'pending' end,
    '2025-01-15',
    'app_popup',
    case when v_benefit_push_agreed then now() else null end,
    case when v_benefit_push_agreed then now() else null end,
    null
  )
  on conflict (user_id, consent_type) do nothing;

  select * into v_marketing_consent
    from public.member_consents
   where user_id = v_user_id
     and consent_type = 'marketing_push';

  select * into v_benefit_push_consent
    from public.member_consents
   where user_id = v_user_id
     and consent_type = 'benefit_push';

  if not v_marketing_agreed then
    v_missing := array_append(v_missing, 'marketing_push');
    if coalesce(v_marketing_consent.deferred_until, '-infinity'::timestamptz) <= now() then
      v_prompt_missing := array_append(v_prompt_missing, 'marketing_push');
    else
      v_next_prompt_at := least(
        coalesce(v_next_prompt_at, v_marketing_consent.deferred_until),
        v_marketing_consent.deferred_until
      );
    end if;
  end if;

  if not v_benefit_push_agreed then
    v_missing := array_append(v_missing, 'benefit_push');
    if coalesce(v_benefit_push_consent.deferred_until, '-infinity'::timestamptz) <= now() then
      v_prompt_missing := array_append(v_prompt_missing, 'benefit_push');
    else
      v_next_prompt_at := least(
        coalesce(v_next_prompt_at, v_benefit_push_consent.deferred_until),
        v_benefit_push_consent.deferred_until
      );
    end if;
  end if;

  v_should_show_consent := coalesce(array_length(v_prompt_missing, 1), 0) > 0;

  if v_should_show_consent then
    update public.member_consents
       set prompted_at = coalesce(prompted_at, now()),
           updated_at = now()
     where user_id = v_user_id
       and consent_type = any(v_prompt_missing);

    select * into v_marketing_consent
      from public.member_consents
     where user_id = v_user_id
       and consent_type = 'marketing_push';

    select * into v_benefit_push_consent
      from public.member_consents
     where user_id = v_user_id
       and consent_type = 'benefit_push';
  end if;

  select * into v_reward
    from public.member_welcome_rewards
   where user_id = v_user_id;
  v_reward_found := found;

  return jsonb_build_object(
    'welcomeReward', case
      when v_reward_found then jsonb_build_object(
        'id', v_reward.id,
        'status', v_reward.status,
        'show', v_reward.status = 'completed' and v_reward.popup_acknowledged_at is null,
        'targetKrwAmount', v_reward.target_krw_amount,
        'referencePrice', v_reward.reference_price,
        'grantedAmount', v_reward.granted_amount,
        'grantedKrwValue', v_reward.granted_krw_value,
        'priceAt', v_reward.price_at,
        'completedAt', v_reward.completed_at,
        'acknowledgedAt', v_reward.popup_acknowledged_at
      )
      else jsonb_build_object(
        'status', 'eligible',
        'show', false,
        'targetKrwAmount', 100000
      )
    end,
    'consentReminder', jsonb_build_object(
      'status', case when coalesce(array_length(v_missing, 1), 0) > 0 then 'pending' else 'agreed' end,
      'show', v_should_show_consent,
      'marketingAgreed', v_marketing_agreed,
      'benefitPushAgreed', v_benefit_push_agreed,
      'missing', to_jsonb(v_prompt_missing),
      'allMissing', to_jsonb(v_missing),
      'nextPromptAt', v_next_prompt_at,
      'marketing', jsonb_build_object(
        'status', coalesce(v_marketing_consent.status, case when v_marketing_agreed then 'agreed' else 'pending' end),
        'policyVersion', coalesce(v_marketing_consent.policy_version, '2025-01-15'),
        'promptedAt', v_marketing_consent.prompted_at,
        'deferredAt', v_marketing_consent.deferred_at,
        'deferredUntil', v_marketing_consent.deferred_until,
        'updatedAt', v_marketing_consent.updated_at
      ),
      'benefitPush', jsonb_build_object(
        'status', coalesce(v_benefit_push_consent.status, case when v_benefit_push_agreed then 'agreed' else 'pending' end),
        'policyVersion', coalesce(v_benefit_push_consent.policy_version, '2025-01-15'),
        'promptedAt', v_benefit_push_consent.prompted_at,
        'deferredAt', v_benefit_push_consent.deferred_at,
        'deferredUntil', v_benefit_push_consent.deferred_until,
        'updatedAt', v_benefit_push_consent.updated_at
      )
    ),
    'marketingConsent', jsonb_build_object(
      'status', case when coalesce(array_length(v_missing, 1), 0) > 0 then 'pending' else 'agreed' end,
      'show', v_should_show_consent,
      'policyVersion', coalesce(v_marketing_consent.policy_version, '2025-01-15'),
      'promptedAt', v_marketing_consent.prompted_at,
      'deferredAt', v_marketing_consent.deferred_at,
      'deferredUntil', v_marketing_consent.deferred_until,
      'nextPromptAt', v_next_prompt_at,
      'updatedAt', nullif(greatest(
        coalesce(v_marketing_consent.updated_at, '-infinity'::timestamptz),
        coalesce(v_benefit_push_consent.updated_at, '-infinity'::timestamptz)
      ), '-infinity'::timestamptz)
    )
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
    'member', private.member_snapshot(v_user_id)
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
  perform pg_advisory_xact_lock(
    hashtextextended('popup-consent-bundle:' || v_user_id::text, 0)
  );

  v_marketing := public.rpc_update_member_consent('marketing_push', v_status, v_source);
  v_benefit_push := public.rpc_update_member_consent('benefit_push', v_status, v_source);

  return jsonb_build_object(
    'status', v_status,
    'consents', jsonb_build_object(
      'marketing', v_marketing -> 'consent',
      'benefitPush', v_benefit_push -> 'consent'
    ),
    'member', private.member_snapshot(v_user_id)
  );
end;
$$;
create or replace function public.rpc_defer_popup_consents(
  p_source text default 'app_popup'
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_source text := left(coalesce(nullif(trim(p_source), ''), 'app_popup'), 50);
  v_member public.member%rowtype;
  v_deferred_until timestamptz := now() + interval '5 hours';
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  v_member := private.require_active_member();
  perform pg_advisory_xact_lock(
    hashtextextended('popup-consent-defer:' || v_user_id::text, 0)
  );

  insert into public.member_consents (
    user_id,
    consent_type,
    status,
    policy_version,
    source,
    prompted_at,
    deferred_at,
    deferred_until
  )
  select
    v_user_id,
    v.consent_type,
    'pending',
    '2025-01-15',
    v_source,
    now(),
    now(),
    v_deferred_until
  from (values ('marketing_push'), ('benefit_push')) as v(consent_type)
  where (v.consent_type = 'marketing_push' and not coalesce(v_member.marketing_agreed, false))
     or (v.consent_type = 'benefit_push' and not coalesce(v_member.push_notifications_enabled, false))
  on conflict (user_id, consent_type)
  do update set
    status = case when member_consents.status = 'agreed' then 'agreed' else 'pending' end,
    source = excluded.source,
    prompted_at = coalesce(member_consents.prompted_at, excluded.prompted_at),
    deferred_at = excluded.deferred_at,
    deferred_until = excluded.deferred_until,
    updated_at = now();

  return jsonb_build_object(
    'status', 'deferred',
    'deferredUntil', v_deferred_until,
    'member', private.member_snapshot(v_user_id)
  );
end;
$$;
create or replace function public.rpc_update_marketing_consent(
  p_status text,
  p_source text default 'app_popup'
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
begin
  return public.rpc_update_popup_consents(p_status, p_source);
end;
$$;
revoke all on function public.rpc_get_app_popup_state() from public, anon;
revoke all on function public.rpc_update_member_consent(text, text, text) from public, anon;
revoke all on function public.rpc_update_popup_consents(text, text) from public, anon;
revoke all on function public.rpc_defer_popup_consents(text) from public, anon;
revoke all on function public.rpc_update_marketing_consent(text, text) from public, anon;
grant execute on function public.rpc_get_app_popup_state() to authenticated;
grant execute on function public.rpc_update_member_consent(text, text, text) to authenticated;
grant execute on function public.rpc_update_popup_consents(text, text) to authenticated;
grant execute on function public.rpc_defer_popup_consents(text) to authenticated;
grant execute on function public.rpc_update_marketing_consent(text, text) to authenticated;
-- -----------------------------------------------------------------------------
-- 3. Member deletion guard. The device table is restored above, but the RPC also
--    guards the update so a future accidental drop does not block withdrawal.
-- -----------------------------------------------------------------------------
create or replace function public.rpc_request_member_deletion(
  p_reason_code text,
  p_reason_text text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_auth_user auth.users%rowtype;
  v_reason_code text := lower(trim(coalesce(p_reason_code, '')));
  v_reason_text text := nullif(trim(coalesce(p_reason_text, '')), '');
  v_request public.member_deletion_requests%rowtype;
begin
  v_member := private.require_active_member();

  if v_reason_code not in (
    'delete_records',
    'inconvenient',
    'low_usage',
    'not_needed',
    'other'
  ) then
    raise exception using errcode = 'P0001', message = 'DELETION_REASON_REQUIRED';
  end if;

  if v_reason_code = 'other' and v_reason_text is null then
    raise exception using errcode = 'P0001', message = 'DELETION_REASON_TEXT_REQUIRED';
  end if;

  if v_reason_text is not null and length(v_reason_text) > 500 then
    raise exception using errcode = 'P0001', message = 'DELETION_REASON_TEXT_TOO_LONG';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('member-delete:' || v_member.user_id::text, 0));

  select * into v_auth_user
    from auth.users
   where id = v_member.user_id;

  with identifiers(identifier_type, identifier_value) as (
    values
      ('member_id', v_member.mb_id),
      ('member_email', v_member.mb_email),
      ('member_phone', regexp_replace(coalesce(v_member.mb_hp, ''), '[^0-9]', '', 'g')),
      ('google_id', v_member.google_id),
      ('auth_email', v_auth_user.email),
      ('auth_phone', regexp_replace(coalesce(v_auth_user.phone, ''), '[^0-9]', '', 'g'))
  )
  insert into public.deleted_member_identifiers (
    user_id,
    identifier_type,
    identifier_hash
  )
  select
    v_member.user_id,
    i.identifier_type,
    private.deleted_identifier_hash(i.identifier_value)
  from identifiers i
  where nullif(trim(i.identifier_value), '') is not null
  on conflict (identifier_type, identifier_hash) do nothing;

  insert into public.member_deletion_requests (
    user_id,
    reason_code,
    reason_text,
    status,
    completed_at,
    metadata
  ) values (
    v_member.user_id,
    v_reason_code,
    v_reason_text,
    'completed',
    now(),
    jsonb_build_object(
      'balancePreserved', true,
      'authUserPreserved', true,
      'contactRequiredForReactivation', true
    )
  )
  on conflict (user_id)
  do update set
    reason_code = excluded.reason_code,
    reason_text = excluded.reason_text,
    status = 'completed',
    completed_at = now(),
    metadata = excluded.metadata,
    updated_at = now()
  returning * into v_request;

  update public.member
     set is_del = true,
         status = 'deleted',
         deleted_at = now(),
         deletion_reason_code = v_reason_code,
         deletion_reason_text = v_reason_text,
         marketing_agreed = false,
         push_notifications_enabled = false,
         updated_at = now()
   where user_id = v_member.user_id;

  update public.member_consents
     set status = 'declined',
         source = 'member_deletion',
         consented_at = null,
         declined_at = now(),
         deferred_at = null,
         deferred_until = null,
         updated_at = now()
   where user_id = v_member.user_id
     and consent_type in ('marketing_push', 'benefit_push');

  if to_regclass('public.member_devices') is not null then
    update public.member_devices
       set push_token = null,
           is_active = false,
           updated_at = now()
     where user_id = v_member.user_id;
  end if;

  return jsonb_build_object(
    'deleted', true,
    'is_del', true,
    'deletedAt', now(),
    'requestId', v_request.id,
    'contactRequired', true,
    'inquiryType', 'deleted_account_reactivation'
  );
end;
$$;
revoke all on function public.rpc_request_member_deletion(text, text) from public, anon;
grant execute on function public.rpc_request_member_deletion(text, text) to authenticated;
-- -----------------------------------------------------------------------------
-- 4. Attendance reminder push target/logging support
-- -----------------------------------------------------------------------------
create table if not exists public.push_notification_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.member(user_id) on delete cascade,
  device_id uuid references public.member_devices(id) on delete set null,
  notification_type text not null,
  notification_key text not null,
  title text not null,
  body text not null,
  status text not null default 'pending'
    check (status in ('pending', 'sent', 'failed', 'skipped')),
  provider_message_id text,
  error_message text,
  local_date date not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  updated_at timestamptz not null default now()
);
create unique index if not exists push_notification_logs_once_per_user_day_uidx
  on public.push_notification_logs(user_id, notification_key, local_date);
create index if not exists push_notification_logs_status_created_idx
  on public.push_notification_logs(status, created_at desc);
do $$
begin
  if not exists (
    select 1
      from pg_trigger
     where tgname = 'push_notification_logs_set_updated_at'
       and tgrelid = 'public.push_notification_logs'::regclass
  ) then
    create trigger push_notification_logs_set_updated_at
    before update on public.push_notification_logs
    for each row execute function public.set_updated_at();
  end if;
end;
$$;
alter table public.push_notification_logs enable row level security;
revoke all on public.push_notification_logs from public, anon, authenticated;
create or replace function public.rpc_claim_attendance_reminder_push_targets(
  p_local_date date,
  p_limit integer default 500
)
returns table(
  log_id uuid,
  user_id uuid,
  device_id uuid,
  push_token text,
  title text,
  body text,
  local_date date
)
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
begin
  return query
  with candidate_devices as (
    select distinct on (m.user_id)
      m.user_id,
      d.id as device_id,
      d.push_token
    from public.member m
    join public.member_devices d
      on d.user_id = m.user_id
     and d.is_active = true
     and d.push_token is not null
    where m.status = 'active'
      and coalesce(m.is_del, false) = false
      and coalesce(m.marketing_agreed, false) = true
      and coalesce(m.push_notifications_enabled, false) = true
      and not exists (
        select 1
          from public.user_daily_attendance a
         where a.user_id = m.user_id
           and a.check_date = p_local_date
      )
    order by m.user_id, d.last_seen_at desc nulls last, d.updated_at desc nulls last
    limit greatest(1, least(coalesce(p_limit, 500), 1000))
  ), inserted_logs as (
    insert into public.push_notification_logs (
      user_id,
      device_id,
      notification_type,
      notification_key,
      title,
      body,
      status,
      local_date,
      metadata
    )
    select
      c.user_id,
      c.device_id,
      'attendance_reminder',
      'attendance-reminder',
      'STO Network',
      '오늘 출석 포인트 챙기셨나요? 🎁',
      'pending',
      p_local_date,
      jsonb_build_object('source', 'attendance-reminder-push')
    from candidate_devices c
    on conflict (user_id, notification_key, local_date) do nothing
    returning
      id,
      push_notification_logs.user_id,
      push_notification_logs.device_id,
      push_notification_logs.title,
      push_notification_logs.body,
      push_notification_logs.local_date
  )
  select
    l.id as log_id,
    l.user_id,
    l.device_id,
    d.push_token,
    l.title,
    l.body,
    l.local_date
  from inserted_logs l
  join public.member_devices d on d.id = l.device_id
  where d.push_token is not null;
end;
$$;
create or replace function public.rpc_mark_push_notification_log(
  p_log_id uuid,
  p_status text,
  p_provider_message_id text default null,
  p_error_message text default null
)
returns void
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_status text := lower(trim(coalesce(p_status, '')));
begin
  if v_status not in ('sent', 'failed', 'skipped') then
    raise exception using errcode = '22023', message = 'INVALID_PUSH_LOG_STATUS';
  end if;

  update public.push_notification_logs
     set status = v_status,
         provider_message_id = nullif(trim(coalesce(p_provider_message_id, '')), ''),
         error_message = nullif(left(coalesce(p_error_message, ''), 1000), ''),
         sent_at = case when v_status = 'sent' then now() else sent_at end,
         updated_at = now()
   where id = p_log_id;
end;
$$;
revoke all on function public.rpc_claim_attendance_reminder_push_targets(date, integer)
  from public, anon, authenticated;
revoke all on function public.rpc_mark_push_notification_log(uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function public.rpc_claim_attendance_reminder_push_targets(date, integer) to service_role;
grant execute on function public.rpc_mark_push_notification_log(uuid, text, text, text) to service_role;
notify pgrst, 'reload schema';

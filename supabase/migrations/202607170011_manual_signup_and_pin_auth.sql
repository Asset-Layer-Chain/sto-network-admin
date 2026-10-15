-- Manual member signup, phone verification, Google member-id generation,
-- and real Supabase sessions for legacy mb_id + PIN login.

alter table public.member
  add column if not exists signup_method text not null default 'legacy',
  add column if not exists signup_completed_at timestamptz,
  add column if not exists phone_verified_at timestamptz;
update public.member
   set signup_completed_at = coalesce(signup_completed_at, created_at),
       signup_method = case when google_linked then 'google' else coalesce(nullif(signup_method, 'legacy'), 'legacy') end
 where signup_completed_at is null;
create unique index if not exists member_mb_id_lower_uidx
  on public.member(lower(mb_id));
alter table public.member_security
  add column if not exists failed_attempts integer not null default 0,
  add column if not exists locked_until timestamptz,
  add column if not exists last_failed_at timestamptz,
  add column if not exists last_login_at timestamptz;
-- Older installations may still carry a plaintext member.mb_pin column.
-- Copy it once into member_security without overwriting a newer hashed PIN.
do $migration$
begin
  if exists (
    select 1
      from information_schema.columns
     where table_schema = 'public'
       and table_name = 'member'
       and column_name = 'mb_pin'
  ) then
    execute $sql$
      insert into public.member_security (user_id, pin_hash, pin_updated_at)
      select
        m.user_id,
        extensions.crypt(trim(m.mb_pin::text), extensions.gen_salt('bf', 10)),
        now()
      from public.member m
      where trim(coalesce(m.mb_pin::text, '')) ~ '^[0-9]{6}$'
      on conflict (user_id) do update set
        pin_hash = coalesce(member_security.pin_hash, excluded.pin_hash),
        pin_updated_at = coalesce(member_security.pin_updated_at, excluded.pin_updated_at),
        updated_at = now()
    $sql$;
  end if;
end;
$migration$;
create table if not exists public.phone_verification_requests (
  id uuid primary key default extensions.gen_random_uuid(),
  phone_normalized text not null,
  phone_hash text not null,
  code_hash text not null,
  ticket_hash text,
  purpose text not null default 'signup',
  attempts integer not null default 0,
  max_attempts integer not null default 5,
  expires_at timestamptz not null,
  resend_available_at timestamptz not null,
  verified_at timestamptz,
  used_at timestamptz,
  requester_ip_hash text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists phone_verification_phone_created_idx
  on public.phone_verification_requests(phone_hash, created_at desc);
create trigger phone_verification_requests_set_updated_at
before update on public.phone_verification_requests
for each row execute function public.set_updated_at();
create table if not exists public.pin_login_throttle (
  throttle_key text primary key,
  failed_attempts integer not null default 0,
  locked_until timestamptz,
  last_failed_at timestamptz,
  updated_at timestamptz not null default now()
);
revoke all on public.phone_verification_requests from public, anon, authenticated;
revoke all on public.pin_login_throttle from public, anon, authenticated;
create or replace function private.normalize_signup_phone(p_phone text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
$$;
create or replace function private.signup_hash(p_value text)
returns text
language sql
immutable
strict
set search_path = public, extensions, pg_temp
as $$
  select encode(extensions.digest(lower(trim(p_value)), 'sha256'), 'hex');
$$;
revoke all on function private.normalize_signup_phone(text) from public, anon, authenticated;
revoke all on function private.signup_hash(text) from public, anon, authenticated;
-- 012의 소셜 가입 자동 동의를 제거한다. 신규 소셜 가입도 화면에서 선택한 값만 저장한다.
drop trigger if exists member_apply_social_signup_consents_before_insert on public.member;
create or replace function public.rpc_create_phone_verification(
  p_phone text,
  p_code text,
  p_ip_hash text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_phone text := private.normalize_signup_phone(p_phone);
  v_phone_hash text;
  v_request public.phone_verification_requests%rowtype;
  v_recent_count integer;
begin
  if v_phone !~ '^01[0-9]{8,9}$' then
    raise exception using errcode = 'P0001', message = 'INVALID_PHONE_NUMBER';
  end if;
  if coalesce(p_code, '') !~ '^[0-9]{6}$' then
    raise exception using errcode = 'P0001', message = 'INVALID_VERIFICATION_CODE';
  end if;

  v_phone_hash := private.signup_hash(v_phone);
  perform pg_advisory_xact_lock(hashtextextended('phone-verify:' || v_phone_hash, 0));

  if exists (
    select 1 from public.member m
     where private.normalize_signup_phone(m.mb_hp) = v_phone
       and m.is_del = false
  ) then
    raise exception using errcode = 'P0001', message = 'PHONE_ALREADY_REGISTERED';
  end if;

  if exists (
    select 1 from public.deleted_member_identifiers d
     where d.identifier_type in ('member_phone', 'auth_phone')
       and d.identifier_hash = private.deleted_identifier_hash(v_phone)
  ) then
    raise exception using errcode = 'P0001', message = 'ACCOUNT_DELETED_CONTACT_REQUIRED';
  end if;

  select count(*)::integer into v_recent_count
    from public.phone_verification_requests r
   where r.phone_hash = v_phone_hash
     and r.created_at >= now() - interval '1 day';

  if v_recent_count >= 10 then
    raise exception using errcode = 'P0001', message = 'SMS_DAILY_LIMIT_EXCEEDED';
  end if;

  if nullif(trim(coalesce(p_ip_hash, '')), '') is not null and (
    select count(*)
      from public.phone_verification_requests r
     where r.requester_ip_hash = trim(p_ip_hash)
       and r.created_at >= now() - interval '1 day'
  ) >= 30 then
    raise exception using errcode = 'P0001', message = 'SMS_IP_DAILY_LIMIT_EXCEEDED';
  end if;

  if exists (
    select 1 from public.phone_verification_requests r
     where r.phone_hash = v_phone_hash
       and r.resend_available_at > now()
       and r.verified_at is null
  ) then
    raise exception using errcode = 'P0001', message = 'SMS_RESEND_TOO_SOON';
  end if;

  insert into public.phone_verification_requests (
    phone_normalized,
    phone_hash,
    code_hash,
    expires_at,
    resend_available_at,
    requester_ip_hash
  ) values (
    v_phone,
    v_phone_hash,
    extensions.crypt(p_code, extensions.gen_salt('bf', 8)),
    now() + interval '5 minutes',
    now() + interval '60 seconds',
    nullif(trim(coalesce(p_ip_hash, '')), '')
  ) returning * into v_request;

  return jsonb_build_object(
    'requestId', v_request.id,
    'expiresAt', v_request.expires_at,
    'resendAvailableAt', v_request.resend_available_at
  );
end;
$$;
create or replace function public.rpc_verify_phone_code(
  p_request_id uuid,
  p_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_request public.phone_verification_requests%rowtype;
  v_ticket text;
  v_next_attempts integer;
begin
  select * into v_request
    from public.phone_verification_requests
   where id = p_request_id
   for update;

  if not found or v_request.used_at is not null then
    return jsonb_build_object('verified', false, 'error', 'VERIFICATION_REQUEST_NOT_FOUND');
  end if;
  if v_request.verified_at is not null then
    return jsonb_build_object('verified', false, 'error', 'VERIFICATION_ALREADY_COMPLETED');
  end if;
  if v_request.expires_at <= now() then
    return jsonb_build_object('verified', false, 'error', 'VERIFICATION_CODE_EXPIRED');
  end if;
  if v_request.attempts >= v_request.max_attempts then
    return jsonb_build_object('verified', false, 'error', 'VERIFICATION_ATTEMPTS_EXCEEDED');
  end if;

  if extensions.crypt(coalesce(p_code, ''), v_request.code_hash) <> v_request.code_hash then
    v_next_attempts := v_request.attempts + 1;
    update public.phone_verification_requests
       set attempts = v_next_attempts,
           updated_at = now()
     where id = p_request_id;

    return jsonb_build_object(
      'verified', false,
      'error', case
        when v_next_attempts >= v_request.max_attempts then 'VERIFICATION_ATTEMPTS_EXCEEDED'
        else 'VERIFICATION_CODE_MISMATCH'
      end,
      'remainingAttempts', greatest(0, v_request.max_attempts - v_next_attempts)
    );
  end if;

  v_ticket := encode(extensions.gen_random_bytes(32), 'hex');
  update public.phone_verification_requests
     set verified_at = now(),
         ticket_hash = private.signup_hash(v_ticket),
         updated_at = now()
   where id = p_request_id;

  return jsonb_build_object(
    'verified', true,
    'phone', v_request.phone_normalized,
    'signupTicket', v_ticket
  );
end;
$$;
create or replace function private.next_google_member_id(p_email text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_local text := lower(regexp_replace(split_part(coalesce(p_email, 'user'), '@', 1), '[^a-zA-Z0-9]', '', 'g'));
  v_base text;
  v_candidate text;
  v_suffix integer := 1;
begin
  v_base := left(coalesce(nullif(v_local, ''), 'user'), 28) || '_google';
  v_candidate := v_base;
  while exists (select 1 from public.member m where lower(m.mb_id) = lower(v_candidate)) loop
    v_suffix := v_suffix + 1;
    v_candidate := left(v_base, 36) || v_suffix::text;
  end loop;
  return v_candidate;
end;
$$;
revoke all on function private.next_google_member_id(text) from public, anon, authenticated;
create or replace function public.rpc_complete_member_signup(
  p_user_id uuid,
  p_signup_ticket text,
  p_member_id text,
  p_name text,
  p_phone text,
  p_pin text,
  p_referral_code text default null,
  p_provider text default 'manual',
  p_email text default null,
  p_google_id text default null,
  p_avatar_url text default null,
  p_service_agreed boolean default false,
  p_privacy_agreed boolean default false,
  p_marketing_agreed boolean default false,
  p_benefit_push_agreed boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_phone text := private.normalize_signup_phone(p_phone);
  v_provider text := lower(trim(coalesce(p_provider, 'manual')));
  v_member_id text := lower(trim(coalesce(p_member_id, '')));
  v_name text := trim(coalesce(p_name, ''));
  v_request public.phone_verification_requests%rowtype;
  v_referrer public.member%rowtype;
  v_member public.member%rowtype;
  v_email text := lower(trim(coalesce(p_email, '')));
begin
  if p_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_USER_REQUIRED';
  end if;
  if not p_service_agreed or not p_privacy_agreed then
    raise exception using errcode = 'P0001', message = 'REQUIRED_TERMS_NOT_AGREED';
  end if;
  if v_name = '' then
    raise exception using errcode = 'P0001', message = 'NAME_REQUIRED';
  end if;
  if coalesce(p_pin, '') !~ '^[0-9]{6}$' then
    raise exception using errcode = 'P0001', message = 'PIN_MUST_BE_SIX_DIGITS';
  end if;

  select * into v_request
    from public.phone_verification_requests r
   where r.phone_hash = private.signup_hash(v_phone)
     and r.ticket_hash = private.signup_hash(coalesce(p_signup_ticket, ''))
     and r.verified_at is not null
     and r.used_at is null
     and r.verified_at > now() - interval '15 minutes'
   order by r.created_at desc
   limit 1
   for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'PHONE_VERIFICATION_REQUIRED';
  end if;

  if exists (select 1 from public.member where user_id = p_user_id) then
    raise exception using errcode = 'P0001', message = 'MEMBER_ALREADY_EXISTS';
  end if;

  if v_provider in ('google', 'apple', 'kakao', 'naver', 'social') then
    perform pg_advisory_xact_lock(hashtextextended('social-id:' || coalesce(v_email, p_user_id::text), 0));
    v_member_id := private.next_google_member_id(v_email);
  else
    if v_member_id !~ '^[a-z0-9]{4,20}$' then
      raise exception using errcode = 'P0001', message = 'INVALID_MEMBER_ID';
    end if;
  end if;

  perform pg_advisory_xact_lock(hashtextextended('member-id:' || v_member_id, 0));

  if exists (
    select 1
      from public.deleted_member_identifiers d
     where (d.identifier_type = 'member_id'
            and d.identifier_hash = private.deleted_identifier_hash(v_member_id))
        or (nullif(v_email, '') is not null
            and d.identifier_type in ('member_email', 'auth_email')
            and d.identifier_hash = private.deleted_identifier_hash(v_email))
        or (nullif(trim(coalesce(p_google_id, '')), '') is not null
            and d.identifier_type = 'google_id'
            and d.identifier_hash = private.deleted_identifier_hash(trim(p_google_id)))
  ) then
    raise exception using errcode = 'P0001', message = 'ACCOUNT_DELETED_CONTACT_REQUIRED';
  end if;

  if exists (select 1 from public.member where lower(mb_id) = lower(v_member_id)) then
    raise exception using errcode = 'P0001', message = 'MEMBER_ID_ALREADY_USED';
  end if;
  if exists (select 1 from public.member where private.normalize_signup_phone(mb_hp) = v_phone) then
    raise exception using errcode = 'P0001', message = 'PHONE_ALREADY_REGISTERED';
  end if;

  insert into public.member (
    user_id, mb_id, mb_name, mb_email, mb_hp, mb_profile,
    status, referral_code, google_linked, google_id,
    marketing_agreed, push_notifications_enabled, reg_channel,
    signup_method, signup_completed_at, phone_verified_at, last_login_at
  ) values (
    p_user_id,
    v_member_id,
    v_name,
    coalesce(nullif(v_email, ''), v_member_id || '@member.stonetwork.invalid'),
    v_phone,
    nullif(trim(coalesce(p_avatar_url, '')), ''),
    'active',
    upper(left(replace(p_user_id::text, '-', ''), 10)),
    v_provider = 'google',
    case when v_provider = 'google' then nullif(trim(coalesce(p_google_id, '')), '') else null end,
    coalesce(p_marketing_agreed, false),
    coalesce(p_benefit_push_agreed, false),
    case when v_provider = 'manual' then 'manual' else v_provider end,
    case when v_provider = 'manual' then 'manual' else v_provider end,
    now(),
    now(),
    now()
  ) returning * into v_member;

  insert into public.member_security (
    user_id, pin_hash, pin_updated_at, failed_attempts
  ) values (
    p_user_id,
    extensions.crypt(p_pin, extensions.gen_salt('bf', 10)),
    now(),
    0
  )
  on conflict (user_id) do update set
    pin_hash = excluded.pin_hash,
    pin_updated_at = excluded.pin_updated_at,
    failed_attempts = 0,
    locked_until = null,
    updated_at = now();

  insert into public.wallet_accounts (user_id, asset_code, account_type)
  values (p_user_id, 'STOC_INT', 'internal'), (p_user_id, 'BNB', 'internal')
  on conflict (user_id, asset_code, account_type) do nothing;

  if nullif(trim(coalesce(p_referral_code, '')), '') is not null then
    select * into v_referrer
      from public.member m
     where m.user_id <> p_user_id
       and m.status = 'active'
       and not m.is_del
       and (lower(m.referral_code) = lower(trim(p_referral_code)) or lower(m.mb_id) = lower(trim(p_referral_code)))
     order by case when lower(m.referral_code) = lower(trim(p_referral_code)) then 0 else 1 end
     limit 1;

    if found then
      update public.member set referrer_user_id = v_referrer.user_id where user_id = p_user_id;
      insert into public.referral_network(referrer_user_id, referred_user_id, depth, status)
      values (v_referrer.user_id, p_user_id, 1, 'active')
      on conflict (referrer_user_id, referred_user_id, depth) do update set status = 'active';
    end if;
  end if;

  insert into public.member_consents(user_id, consent_type, status, policy_version, source, prompted_at, consented_at, declined_at)
  values
    (p_user_id, 'service_terms', 'agreed', '2025-01-15', 'signup', now(), now(), null),
    (p_user_id, 'privacy_policy', 'agreed', '2025-01-15', 'signup', now(), now(), null),
    (p_user_id, 'marketing_push', case when p_marketing_agreed then 'agreed' else 'declined' end, '2025-01-15', 'signup', now(), case when p_marketing_agreed then now() end, case when not p_marketing_agreed then now() end),
    (p_user_id, 'benefit_push', case when p_benefit_push_agreed then 'agreed' else 'declined' end, '2025-01-15', 'signup', now(), case when p_benefit_push_agreed then now() end, case when not p_benefit_push_agreed then now() end)
  on conflict (user_id, consent_type) do update set
    status = excluded.status,
    policy_version = excluded.policy_version,
    source = excluded.source,
    prompted_at = excluded.prompted_at,
    consented_at = excluded.consented_at,
    declined_at = excluded.declined_at,
    updated_at = now();

  update public.phone_verification_requests set used_at = now(), updated_at = now() where id = v_request.id;

  return jsonb_build_object(
    'memberId', v_member_id,
    'member', private.member_snapshot(p_user_id),
    'signupCompleted', true
  );
end;
$$;
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

  if found and v_throttle.locked_until is not null and v_throttle.locked_until > now() then
    return jsonb_build_object(
      'verified', false,
      'error', 'PIN_LOGIN_TEMPORARILY_LOCKED',
      'lockedUntil', v_throttle.locked_until
    );
  end if;

  if found and v_throttle.last_failed_at is not null
     and v_throttle.last_failed_at > now() - interval '1 second' then
    return jsonb_build_object('verified', false, 'error', 'PIN_LOGIN_TRY_AGAIN');
  end if;

  select * into v_member
    from public.member
   where lower(mb_id) = lower(trim(coalesce(p_member_id, '')))
   limit 1;

  if found and not v_member.is_del and v_member.status = 'active' then
    select * into v_security
      from public.member_security
     where user_id = v_member.user_id
     for update;

    if found and v_security.locked_until is not null and v_security.locked_until > now() then
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
revoke all on function public.rpc_create_phone_verification(text, text, text) from public, anon, authenticated;
revoke all on function public.rpc_verify_phone_code(uuid, text) from public, anon, authenticated;
revoke all on function public.rpc_complete_member_signup(uuid, text, text, text, text, text, text, text, text, text, text, boolean, boolean, boolean, boolean) from public, anon, authenticated;
revoke all on function public.rpc_verify_pin_login(text, text, text) from public, anon, authenticated;
grant execute on function public.rpc_create_phone_verification(text, text, text) to service_role;
grant execute on function public.rpc_verify_phone_code(uuid, text) to service_role;
grant execute on function public.rpc_complete_member_signup(uuid, text, text, text, text, text, text, text, text, text, text, boolean, boolean, boolean, boolean) to service_role;
grant execute on function public.rpc_verify_pin_login(text, text, text) to service_role;
notify pgrst, 'reload schema';

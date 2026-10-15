-- Member soft deletion, reactivation inquiry guard, and PIN update support.
-- STOC balances and transaction rows are intentionally preserved.

alter table public.member
  add column if not exists is_del boolean not null default false,
  add column if not exists deleted_at timestamptz,
  add column if not exists deletion_reason_code text,
  add column if not exists deletion_reason_text text;
create index if not exists member_active_user_idx
  on public.member(user_id)
  where is_del = false and status = 'active';
create table if not exists public.member_security (
  user_id uuid primary key references public.member(user_id) on delete restrict,
  pin_hash text,
  pin_updated_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger member_security_set_updated_at
before update on public.member_security
for each row execute function public.set_updated_at();
create table if not exists public.member_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references public.member(user_id) on delete restrict,
  reason_code text not null,
  reason_text text,
  status text not null default 'completed'
    check (status in ('requested', 'completed', 'cancelled')),
  requested_at timestamptz not null default now(),
  completed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger member_deletion_requests_set_updated_at
before update on public.member_deletion_requests
for each row execute function public.set_updated_at();
create table if not exists public.deleted_member_identifiers (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.member(user_id) on delete restrict,
  identifier_type text not null,
  identifier_hash text not null,
  created_at timestamptz not null default now(),
  unique (identifier_type, identifier_hash)
);
create index if not exists deleted_member_identifiers_user_idx
  on public.deleted_member_identifiers(user_id, identifier_type);
revoke all on public.member_security from public, anon, authenticated;
revoke all on public.member_deletion_requests from public, anon, authenticated;
revoke all on public.deleted_member_identifiers from public, anon, authenticated;
create or replace function private.deleted_identifier_hash(p_identifier text)
returns text
language sql
immutable
strict
set search_path = public, extensions, pg_temp
as $$
  select encode(extensions.digest(lower(trim(p_identifier)), 'sha256'), 'hex');
$$;
revoke all on function private.deleted_identifier_hash(text)
  from public, anon, authenticated;
-- Every existing RPC using this helper now rejects deleted members.
create or replace function private.require_active_member()
returns public.member
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_member public.member%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  select *
    into v_member
    from public.member
   where user_id = v_user_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_FOUND';
  end if;

  if v_member.is_del or v_member.status = 'deleted' then
    raise exception using errcode = 'P0001', message = 'ACCOUNT_DELETED_CONTACT_REQUIRED';
  end if;

  if v_member.status <> 'active' then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_ACTIVE';
  end if;

  return v_member;
end;
$$;
revoke all on function private.require_active_member()
  from public, anon, authenticated;
-- This RPC is intentionally callable even after soft deletion so the app can
-- replace the service UI with the future common-inquiry flow.
create or replace function public.rpc_get_member_access_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_member public.member%rowtype;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  select * into v_member
    from public.member
   where user_id = v_user_id;

  if not found then
    return jsonb_build_object(
      'status', 'missing',
      'serviceAllowed', true,
      'contactRequired', false
    );
  end if;

  if v_member.is_del or v_member.status = 'deleted' then
    return jsonb_build_object(
      'status', 'deleted',
      'serviceAllowed', false,
      'contactRequired', true,
      'inquiryType', 'deleted_account_reactivation',
      'member', jsonb_build_object(
        'user_id', v_member.user_id,
        'mb_id', v_member.mb_id,
        'mb_email', v_member.mb_email,
        'is_del', true,
        'deleted_at', v_member.deleted_at
      )
    );
  end if;

  return jsonb_build_object(
    'status', v_member.status,
    'serviceAllowed', v_member.status = 'active',
    'contactRequired', false,
    'member', jsonb_build_object(
      'user_id', v_member.user_id,
      'mb_id', v_member.mb_id,
      'mb_email', v_member.mb_email,
      'is_del', false
    )
  );
end;
$$;
create or replace function public.rpc_update_member_pin(p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_pin text := trim(coalesce(p_pin, ''));
begin
  v_member := private.require_active_member();

  if v_pin !~ '^[0-9]{6}$' then
    raise exception using errcode = 'P0001', message = 'PIN_MUST_BE_SIX_DIGITS';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('member-pin:' || v_member.user_id::text, 0));

  insert into public.member_security (
    user_id,
    pin_hash,
    pin_updated_at
  ) values (
    v_member.user_id,
    extensions.crypt(v_pin, extensions.gen_salt('bf', 10)),
    now()
  )
  on conflict (user_id)
  do update set
    pin_hash = excluded.pin_hash,
    pin_updated_at = excluded.pin_updated_at,
    updated_at = now();

  return jsonb_build_object(
    'updated', true,
    'pinUpdatedAt', now()
  );
end;
$$;
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
         updated_at = now()
   where user_id = v_member.user_id
     and consent_type in ('marketing_push', 'benefit_push');

  update public.member_devices
     set push_token = null,
         updated_at = now()
   where user_id = v_member.user_id;

  -- Wallet balances and the transaction ledger are intentionally untouched.
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
-- Preserve every identifier for contact-only reactivation. Because the Auth
-- user and member row are retained, normal re-signup is already blocked; this
-- trigger also protects future member creation paths.
create or replace function private.block_deleted_member_identifier_reuse()
returns trigger
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
begin
  if exists (
    select 1
      from public.deleted_member_identifiers d
     where (d.identifier_type in ('member_id')
            and d.identifier_hash = private.deleted_identifier_hash(new.mb_id))
        or (d.identifier_type in ('member_email', 'auth_email')
            and d.identifier_hash = private.deleted_identifier_hash(new.mb_email))
        or (new.mb_hp is not null
            and d.identifier_type in ('member_phone', 'auth_phone')
            and d.identifier_hash = private.deleted_identifier_hash(regexp_replace(new.mb_hp, '[^0-9]', '', 'g')))
        or (new.google_id is not null
            and d.identifier_type = 'google_id'
            and d.identifier_hash = private.deleted_identifier_hash(new.google_id))
  ) then
    raise exception using errcode = 'P0001', message = 'ACCOUNT_DELETED_CONTACT_REQUIRED';
  end if;

  return new;
end;
$$;
revoke all on function private.block_deleted_member_identifier_reuse()
  from public, anon, authenticated;
drop trigger if exists member_block_deleted_identifier_reuse on public.member;
create trigger member_block_deleted_identifier_reuse
before insert or update of mb_id, mb_email, mb_hp, google_id on public.member
for each row execute function private.block_deleted_member_identifier_reuse();
-- Deleted users may not directly read protected rows while a previously issued
-- JWT is still alive. The access-state RPC above remains available.
drop policy if exists member_select_self on public.member;
create policy member_select_self
on public.member for select to authenticated
using (
  user_id = (select auth.uid())
  and is_del = false
  and status = 'active'
);
drop policy if exists wallet_accounts_select_self on public.wallet_accounts;
create policy wallet_accounts_select_self
on public.wallet_accounts for select to authenticated
using (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.member m
     where m.user_id = (select auth.uid())
       and m.is_del = false
       and m.status = 'active'
  )
);
drop policy if exists wallet_addresses_select_self on public.wallet_addresses;
create policy wallet_addresses_select_self
on public.wallet_addresses for select to authenticated
using (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.member m
     where m.user_id = (select auth.uid())
       and m.is_del = false
       and m.status = 'active'
  )
);
drop policy if exists transactions_select_participant on public.transactions;
create policy transactions_select_participant
on public.transactions for select to authenticated
using (
  (sender_user_id = (select auth.uid()) or receiver_user_id = (select auth.uid()))
  and exists (
    select 1 from public.member m
     where m.user_id = (select auth.uid())
       and m.is_del = false
       and m.status = 'active'
  )
);
drop policy if exists attendance_select_self on public.user_daily_attendance;
create policy attendance_select_self
on public.user_daily_attendance for select to authenticated
using (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.member m
     where m.user_id = (select auth.uid())
       and m.is_del = false
       and m.status = 'active'
  )
);
drop policy if exists roulette_select_self on public.roulette_spins;
create policy roulette_select_self
on public.roulette_spins for select to authenticated
using (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.member m
     where m.user_id = (select auth.uid())
       and m.is_del = false
       and m.status = 'active'
  )
);
drop policy if exists collector_select_self on public.collector_sessions;
create policy collector_select_self
on public.collector_sessions for select to authenticated
using (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.member m
     where m.user_id = (select auth.uid())
       and m.is_del = false
       and m.status = 'active'
  )
);
drop policy if exists notifications_select_self on public.notifications;
create policy notifications_select_self
on public.notifications for select to authenticated
using (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.member m
     where m.user_id = (select auth.uid())
       and m.is_del = false
       and m.status = 'active'
  )
);
drop policy if exists member_devices_select_self on public.member_devices;
create policy member_devices_select_self
on public.member_devices for select to authenticated
using (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.member m
     where m.user_id = (select auth.uid())
       and m.is_del = false
       and m.status = 'active'
  )
);
drop policy if exists referral_network_select_related on public.referral_network;
create policy referral_network_select_related
on public.referral_network for select to authenticated
using (
  (referrer_user_id = (select auth.uid()) or referred_user_id = (select auth.uid()))
  and exists (
    select 1 from public.member m
     where m.user_id = (select auth.uid())
       and m.is_del = false
       and m.status = 'active'
  )
);
drop policy if exists event_participants_select_self on public.event_participants;
create policy event_participants_select_self
on public.event_participants for select to authenticated
using (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.member m
     where m.user_id = (select auth.uid())
       and m.is_del = false
       and m.status = 'active'
  )
);
drop policy if exists daily_quiz_progress_select_self on public.daily_quiz_progress;
create policy daily_quiz_progress_select_self
on public.daily_quiz_progress for select to authenticated
using (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.member m
     where m.user_id = (select auth.uid())
       and m.is_del = false
       and m.status = 'active'
  )
);
drop policy if exists prediction_records_select_self on public.prediction_records;
create policy prediction_records_select_self
on public.prediction_records for select to authenticated
using (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.member m
     where m.user_id = (select auth.uid())
       and m.is_del = false
       and m.status = 'active'
  )
);
drop policy if exists sim_orders_select_self on public.sim_orders;
create policy sim_orders_select_self
on public.sim_orders for select to authenticated
using (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.member m
     where m.user_id = (select auth.uid())
       and m.is_del = false
       and m.status = 'active'
  )
);
drop policy if exists sim_positions_select_self on public.sim_positions;
create policy sim_positions_select_self
on public.sim_positions for select to authenticated
using (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.member m
     where m.user_id = (select auth.uid())
       and m.is_del = false
       and m.status = 'active'
  )
);
drop policy if exists qr_sessions_select_self on public.qr_sessions;
create policy qr_sessions_select_self
on public.qr_sessions for select to authenticated
using (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.member m
     where m.user_id = (select auth.uid())
       and m.is_del = false
       and m.status = 'active'
  )
);
revoke all on function public.rpc_get_member_access_state() from public, anon;
revoke all on function public.rpc_update_member_pin(text) from public, anon;
revoke all on function public.rpc_request_member_deletion(text, text) from public, anon;
grant execute on function public.rpc_get_member_access_state() to authenticated;
grant execute on function public.rpc_update_member_pin(text) to authenticated;
grant execute on function public.rpc_request_member_deletion(text, text) to authenticated;
notify pgrst, 'reload schema';

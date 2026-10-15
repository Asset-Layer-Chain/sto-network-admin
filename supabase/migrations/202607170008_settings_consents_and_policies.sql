-- Settings consent synchronization.
-- Keeps marketing consent and benefit Push consent independently auditable.

insert into public.member_consents (
  user_id,
  consent_type,
  status,
  policy_version,
  source,
  prompted_at,
  consented_at,
  declined_at,
  created_at,
  updated_at
)
select
  m.user_id,
  'benefit_push',
  case when m.push_notifications_enabled then 'agreed' else 'declined' end,
  '2025-01-15',
  'migration',
  now(),
  case when m.push_notifications_enabled then now() else null end,
  case when not m.push_notifications_enabled then now() else null end,
  now(),
  now()
from public.member m
on conflict (user_id, consent_type) do nothing;
create or replace function private.seed_member_consents_after_insert()
returns trigger
language plpgsql
security definer
set search_path = public, private, extensions, pg_temp
as $$
begin
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
    new.user_id,
    'marketing_push',
    case when new.marketing_agreed then 'agreed' else 'pending' end,
    '2025-01-15',
    'member_create',
    case when new.marketing_agreed then now() else null end,
    case when new.marketing_agreed then now() else null end,
    null
  ),
  (
    new.user_id,
    'benefit_push',
    case when new.push_notifications_enabled then 'agreed' else 'declined' end,
    '2025-01-15',
    'member_create',
    now(),
    case when new.push_notifications_enabled then now() else null end,
    case when not new.push_notifications_enabled then now() else null end
  )
  on conflict (user_id, consent_type) do nothing;

  return new;
end;
$$;
revoke all on function private.seed_member_consents_after_insert()
  from public, anon, authenticated;
drop trigger if exists member_seed_consents_after_insert on public.member;
create trigger member_seed_consents_after_insert
after insert on public.member
for each row execute function private.seed_member_consents_after_insert();
create or replace function public.rpc_get_member_consents()
returns jsonb
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

  select * into v_member
    from public.member
   where user_id = v_user_id
     and status = 'active';

  if not found then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_FOUND';
  end if;

  return jsonb_build_object(
    'marketing', jsonb_build_object(
      'agreed', v_member.marketing_agreed,
      'record', coalesce((
        select to_jsonb(c) - 'user_id'
          from public.member_consents c
         where c.user_id = v_user_id
           and c.consent_type = 'marketing_push'
      ), '{}'::jsonb)
    ),
    'benefitPush', jsonb_build_object(
      'agreed', v_member.push_notifications_enabled,
      'record', coalesce((
        select to_jsonb(c) - 'user_id'
          from public.member_consents c
         where c.user_id = v_user_id
           and c.consent_type = 'benefit_push'
      ), '{}'::jsonb)
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
    declined_at
  ) values (
    v_user_id,
    v_type,
    v_status,
    '2025-01-15',
    v_source,
    now(),
    case when v_status = 'agreed' then now() else null end,
    case when v_status = 'declined' then now() else null end
  )
  on conflict (user_id, consent_type)
  do update set
    status = excluded.status,
    policy_version = excluded.policy_version,
    source = excluded.source,
    prompted_at = coalesce(member_consents.prompted_at, excluded.prompted_at),
    consented_at = case when excluded.status = 'agreed' then now() else null end,
    declined_at = case when excluded.status = 'declined' then now() else null end,
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
      'updatedAt', v_consent.updated_at
    ),
    'member', private.member_snapshot(v_user_id)
  );
end;
$$;
-- Backward-compatible function used by the first-entry PopupQueue.
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
  return public.rpc_update_member_consent('marketing_push', p_status, p_source);
end;
$$;
revoke all on function public.rpc_get_member_consents() from public, anon;
revoke all on function public.rpc_update_member_consent(text, text, text) from public, anon;
revoke all on function public.rpc_update_marketing_consent(text, text) from public, anon;
grant execute on function public.rpc_get_member_consents() to authenticated;
grant execute on function public.rpc_update_member_consent(text, text, text) to authenticated;
grant execute on function public.rpc_update_marketing_consent(text, text) to authenticated;
notify pgrst, 'reload schema';

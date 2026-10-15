-- 059: Refactor notifications from per-user inbox rows to global broadcast notices.
--
-- This migration is intentionally destructive to the legacy per-user columns.
-- Abort if any legacy notification row exists so production data cannot be
-- discarded accidentally. The application had not used this table yet at the
-- time of this refactor.

do $$
begin
  if exists (select 1 from public.notifications limit 1) then
    raise exception using
      errcode = 'P0001',
      message = 'NOTIFICATIONS_TABLE_NOT_EMPTY';
  end if;
end;
$$;
-- Remove the legacy per-member read model.
drop function if exists public.rpc_mark_notifications_read(uuid[]);
drop policy if exists notifications_select_self on public.notifications;
drop index if exists public.notifications_user_read_created_idx;
alter table public.notifications
  drop constraint if exists notifications_user_id_fkey,
  drop column if exists user_id,
  drop column if exists is_read,
  drop column if exists read_at,
  alter column type set default 'notice',
  add column if not exists is_active boolean not null default true,
  add column if not exists starts_at timestamptz,
  add column if not exists ends_at timestamptz,
  add column if not exists created_by uuid,
  add column if not exists updated_at timestamptz not null default now();
alter table public.notifications
  add constraint notifications_created_by_fkey
    foreign key (created_by) references public.member(user_id) on delete set null,
  add constraint notifications_title_not_blank
    check (btrim(title) <> ''),
  add constraint notifications_message_not_blank
    check (btrim(message) <> ''),
  add constraint notifications_schedule_valid
    check (starts_at is null or ends_at is null or ends_at > starts_at);
create index if not exists notifications_active_created_idx
  on public.notifications(created_at desc)
  where is_active = true;
create index if not exists notifications_schedule_idx
  on public.notifications(starts_at, ends_at)
  where is_active = true;
drop trigger if exists notifications_set_updated_at on public.notifications;
create trigger notifications_set_updated_at
before update on public.notifications
for each row execute function public.set_updated_at();
alter table public.notifications enable row level security;
revoke all on public.notifications from public, anon, authenticated;
-- Active notices are read through an RPC so the table stays closed to direct
-- client writes and future audience logic can be added without changing clients.
create or replace function public.rpc_get_notifications()
returns table (
  id uuid,
  type text,
  title text,
  message text,
  payload jsonb,
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_active_member();

  return query
  select
    n.id,
    n.type,
    n.title,
    n.message,
    n.payload,
    n.starts_at,
    n.ends_at,
    n.created_at,
    n.updated_at
  from public.notifications n
  where n.is_active = true
    and (n.starts_at is null or n.starts_at <= now())
    and (n.ends_at is null or n.ends_at > now())
  order by coalesce(n.starts_at, n.created_at) desc, n.created_at desc
  limit 100;
end;
$$;
-- Global notices affect every member, so only headquarters administrators may
-- publish or modify them.
create or replace function public.rpc_admin_list_notifications(
  p_limit integer default 100,
  p_offset integer default 0
)
returns table (
  id uuid,
  type text,
  title text,
  message text,
  payload jsonb,
  is_active boolean,
  starts_at timestamptz,
  ends_at timestamptz,
  created_by uuid,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_admin_grade text;
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 500);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  v_admin := private.require_admin();
  v_admin_grade := private.admin_grade_for(v_admin.user_id, v_admin.role);

  if coalesce(v_admin_grade, '') <> 'headquarters' then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_BROADCAST_PERMISSION_DENIED';
  end if;

  return query
  select
    n.id,
    n.type,
    n.title,
    n.message,
    n.payload,
    n.is_active,
    n.starts_at,
    n.ends_at,
    n.created_by,
    n.created_at,
    n.updated_at
  from public.notifications n
  order by n.created_at desc
  limit v_limit
  offset v_offset;
end;
$$;
create or replace function public.rpc_admin_create_notification(
  p_title text,
  p_message text,
  p_type text default 'notice',
  p_payload jsonb default '{}'::jsonb,
  p_starts_at timestamptz default null,
  p_ends_at timestamptz default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_admin_grade text;
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
  v_message text := nullif(btrim(coalesce(p_message, '')), '');
  v_type text := nullif(btrim(coalesce(p_type, '')), '');
  v_notification public.notifications%rowtype;
begin
  v_admin := private.require_admin();
  v_admin_grade := private.admin_grade_for(v_admin.user_id, v_admin.role);

  if coalesce(v_admin_grade, '') <> 'headquarters' then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_BROADCAST_PERMISSION_DENIED';
  end if;

  if v_title is null then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_TITLE_REQUIRED';
  end if;
  if char_length(v_title) > 200 then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_TITLE_TOO_LONG';
  end if;
  if v_message is null then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_MESSAGE_REQUIRED';
  end if;
  if char_length(v_message) > 10000 then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_MESSAGE_TOO_LONG';
  end if;
  if v_type is null or char_length(v_type) > 50 then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_TYPE_INVALID';
  end if;
  if p_starts_at is not null and p_ends_at is not null and p_ends_at <= p_starts_at then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_SCHEDULE_INVALID';
  end if;

  insert into public.notifications(
    type,
    title,
    message,
    payload,
    is_active,
    starts_at,
    ends_at,
    created_by
  ) values (
    v_type,
    v_title,
    v_message,
    coalesce(p_payload, '{}'::jsonb),
    true,
    p_starts_at,
    p_ends_at,
    v_admin.user_id
  )
  returning * into v_notification;

  insert into public.admin_action_logs(
    actor_user_id,
    action_type,
    reason,
    before_data,
    after_data,
    metadata
  ) values (
    v_admin.user_id,
    'notification.create',
    '전체 공지 등록',
    '{}'::jsonb,
    to_jsonb(v_notification),
    jsonb_build_object(
      'notificationId', v_notification.id,
      'adminGrade', v_admin_grade,
      'broadcast', true
    )
  );

  return jsonb_build_object(
    'notification', to_jsonb(v_notification),
    'adminGrade', v_admin_grade
  );
end;
$$;
create or replace function public.rpc_admin_update_notification(
  p_notification_id uuid,
  p_patch jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_admin_grade text;
  v_before public.notifications%rowtype;
  v_after public.notifications%rowtype;
  v_patch jsonb := coalesce(p_patch, '{}'::jsonb);
  v_title text;
  v_message text;
  v_type text;
  v_starts_at timestamptz;
  v_ends_at timestamptz;
begin
  v_admin := private.require_admin();
  v_admin_grade := private.admin_grade_for(v_admin.user_id, v_admin.role);

  if coalesce(v_admin_grade, '') <> 'headquarters' then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_BROADCAST_PERMISSION_DENIED';
  end if;

  if p_notification_id is null then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_REQUIRED';
  end if;

  if jsonb_typeof(v_patch) <> 'object' then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_PATCH_INVALID';
  end if;

  if exists (
    select 1
    from jsonb_object_keys(v_patch) as k(key)
    where k.key not in ('title', 'message', 'type', 'payload', 'is_active', 'starts_at', 'ends_at')
  ) then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_PATCH_INVALID';
  end if;

  select * into v_before
  from public.notifications n
  where n.id = p_notification_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_NOT_FOUND';
  end if;

  v_title := case
    when v_patch ? 'title' then nullif(btrim(coalesce(v_patch ->> 'title', '')), '')
    else v_before.title
  end;
  v_message := case
    when v_patch ? 'message' then nullif(btrim(coalesce(v_patch ->> 'message', '')), '')
    else v_before.message
  end;
  v_type := case
    when v_patch ? 'type' then nullif(btrim(coalesce(v_patch ->> 'type', '')), '')
    else v_before.type
  end;
  v_starts_at := case
    when v_patch ? 'starts_at' and jsonb_typeof(v_patch -> 'starts_at') = 'null' then null
    when v_patch ? 'starts_at' then (v_patch ->> 'starts_at')::timestamptz
    else v_before.starts_at
  end;
  v_ends_at := case
    when v_patch ? 'ends_at' and jsonb_typeof(v_patch -> 'ends_at') = 'null' then null
    when v_patch ? 'ends_at' then (v_patch ->> 'ends_at')::timestamptz
    else v_before.ends_at
  end;

  if v_title is null then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_TITLE_REQUIRED';
  end if;
  if char_length(v_title) > 200 then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_TITLE_TOO_LONG';
  end if;
  if v_message is null then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_MESSAGE_REQUIRED';
  end if;
  if char_length(v_message) > 10000 then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_MESSAGE_TOO_LONG';
  end if;
  if v_type is null or char_length(v_type) > 50 then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_TYPE_INVALID';
  end if;
  if v_starts_at is not null and v_ends_at is not null and v_ends_at <= v_starts_at then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_SCHEDULE_INVALID';
  end if;

  update public.notifications n
  set title = v_title,
      message = v_message,
      type = v_type,
      payload = case when v_patch ? 'payload' then coalesce(v_patch -> 'payload', '{}'::jsonb) else n.payload end,
      is_active = case when v_patch ? 'is_active' then (v_patch ->> 'is_active')::boolean else n.is_active end,
      starts_at = v_starts_at,
      ends_at = v_ends_at
  where n.id = p_notification_id
  returning * into v_after;

  insert into public.admin_action_logs(
    actor_user_id,
    action_type,
    reason,
    before_data,
    after_data,
    metadata
  ) values (
    v_admin.user_id,
    'notification.update',
    '전체 공지 수정',
    to_jsonb(v_before),
    to_jsonb(v_after),
    jsonb_build_object(
      'notificationId', p_notification_id,
      'adminGrade', v_admin_grade,
      'broadcast', true
    )
  );

  return jsonb_build_object(
    'notification', to_jsonb(v_after),
    'adminGrade', v_admin_grade
  );
end;
$$;
create or replace function public.rpc_admin_disable_notification(
  p_notification_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_admin_grade text;
  v_before public.notifications%rowtype;
  v_after public.notifications%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  v_admin := private.require_admin();
  v_admin_grade := private.admin_grade_for(v_admin.user_id, v_admin.role);

  if coalesce(v_admin_grade, '') <> 'headquarters' then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_BROADCAST_PERMISSION_DENIED';
  end if;

  if p_notification_id is null then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_REQUIRED';
  end if;

  select * into v_before
  from public.notifications n
  where n.id = p_notification_id
  for update;

  if not found then
    raise exception using errcode = 'P0001', message = 'NOTIFICATION_NOT_FOUND';
  end if;

  update public.notifications n
  set is_active = false
  where n.id = p_notification_id
  returning * into v_after;

  insert into public.admin_action_logs(
    actor_user_id,
    action_type,
    reason,
    before_data,
    after_data,
    metadata
  ) values (
    v_admin.user_id,
    'notification.disable',
    coalesce(v_reason, '전체 공지 비활성화'),
    to_jsonb(v_before),
    to_jsonb(v_after),
    jsonb_build_object(
      'notificationId', p_notification_id,
      'adminGrade', v_admin_grade,
      'broadcast', true
    )
  );

  return jsonb_build_object(
    'notification', to_jsonb(v_after),
    'adminGrade', v_admin_grade
  );
end;
$$;
-- Remove per-user unread aggregation from snapshot/bootstrap RPCs. Chat unread
-- remains unchanged.
create or replace function public.rpc_get_home_snapshot()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_member_snapshot jsonb;
  v_wallet_summary jsonb;
begin
  v_member := private.require_active_member();
  v_member_snapshot := private.member_client_snapshot(v_member.user_id);
  v_wallet_summary := private.wallet_summary(v_member.user_id);

  return jsonb_build_object(
    'member', v_member_snapshot,
    'initial_aidas', (v_wallet_summary ->> 'totalStocBalance')::numeric,
    'totalStocBalance', (v_wallet_summary ->> 'totalStocBalance')::numeric,
    'internalStocBalance', (v_wallet_summary ->> 'internalStocBalance')::numeric,
    'walletNetworks', v_wallet_summary -> 'walletNetworks'
  );
end;
$$;
create or replace function public.rpc_get_app_bootstrap()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, extensions, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_member public.member%rowtype;
  v_access_state jsonb;
  v_member_snapshot jsonb := null;
  v_popup_state jsonb := null;
  v_chat_unread_total integer := 0;
begin
  if v_user_id is null then
    raise exception using errcode = 'P0001', message = 'AUTH_REQUIRED';
  end if;

  select * into v_member
  from public.member
  where user_id = v_user_id;

  if not found then
    v_access_state := jsonb_build_object(
      'status', 'missing',
      'serviceAllowed', true,
      'contactRequired', false
    );

    return jsonb_build_object(
      'memberAccessState', v_access_state,
      'member', null,
      'popupState', null,
      'chatUnreadTotal', 0,
      'locale', 'ko',
      'serverTime', now()
    );
  end if;

  if v_member.is_del or v_member.status = 'deleted' then
    v_access_state := jsonb_build_object(
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

    return jsonb_build_object(
      'memberAccessState', v_access_state,
      'member', null,
      'popupState', null,
      'chatUnreadTotal', 0,
      'locale', coalesce(v_member.locale, 'ko'),
      'serverTime', now()
    );
  end if;

  v_access_state := jsonb_build_object(
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

  v_member_snapshot := private.member_client_snapshot(v_member.user_id);

  select coalesce(sum(cm.unread_count), 0)::integer
  into v_chat_unread_total
  from public.chat_members cm
  where cm.user_id = v_member.user_id
    and cm.left_at is null;

  begin
    v_popup_state := public.rpc_get_app_popup_state();
  exception when others then
    v_popup_state := null;
  end;

  return jsonb_build_object(
    'memberAccessState', v_access_state,
    'member', v_member_snapshot,
    'popupState', v_popup_state,
    'chatUnreadTotal', coalesce(v_chat_unread_total, 0),
    'locale', coalesce(v_member.locale, 'ko'),
    'serverTime', now()
  );
end;
$$;
revoke all on function public.rpc_get_notifications() from public, anon, authenticated;
revoke all on function public.rpc_admin_list_notifications(integer, integer) from public, anon, authenticated;
revoke all on function public.rpc_admin_create_notification(text, text, text, jsonb, timestamptz, timestamptz) from public, anon, authenticated;
revoke all on function public.rpc_admin_update_notification(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.rpc_admin_disable_notification(uuid, text) from public, anon, authenticated;
revoke all on function public.rpc_get_home_snapshot() from public, anon, authenticated;
revoke all on function public.rpc_get_app_bootstrap() from public, anon, authenticated;
grant execute on function public.rpc_get_notifications() to authenticated;
grant execute on function public.rpc_admin_list_notifications(integer, integer) to authenticated;
grant execute on function public.rpc_admin_create_notification(text, text, text, jsonb, timestamptz, timestamptz) to authenticated;
grant execute on function public.rpc_admin_update_notification(uuid, jsonb) to authenticated;
grant execute on function public.rpc_admin_disable_notification(uuid, text) to authenticated;
grant execute on function public.rpc_get_home_snapshot() to authenticated;
grant execute on function public.rpc_get_app_bootstrap() to authenticated;
comment on function public.rpc_get_notifications() is
  'Returns currently active global notices for an active member. Read/unread state is intentionally not tracked.';
comment on function public.rpc_admin_list_notifications(integer, integer) is
  'Lists global notices including scheduled/inactive rows. Headquarters admin only.';
comment on function public.rpc_admin_create_notification(text, text, text, jsonb, timestamptz, timestamptz) is
  'Creates a global notice. Headquarters admin only.';
comment on function public.rpc_admin_update_notification(uuid, jsonb) is
  'Updates a global notice using a controlled JSON patch. Headquarters admin only.';
comment on function public.rpc_admin_disable_notification(uuid, text) is
  'Soft-disables a global notice and records the admin action. Headquarters admin only.';

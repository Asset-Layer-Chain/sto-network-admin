-- Chat core: 1:1/group rooms, cursor pagination, unread counts, and rate-limited RPCs.
-- Realtime private channel/broadcast is intentionally left for the next patch.

create extension if not exists pgcrypto;
create table if not exists public.chat_rooms (
  id uuid primary key default gen_random_uuid(),
  room_type text not null default 'direct'
    check (room_type in ('direct', 'group')),
  title text,
  direct_key text unique,
  created_by uuid references public.member(user_id) on delete set null,
  last_message_id bigint,
  last_message_preview text,
  last_message_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (room_type = 'direct' and direct_key is not null)
    or (room_type = 'group' and direct_key is null)
  )
);
create trigger chat_rooms_set_updated_at
before update on public.chat_rooms
for each row execute function public.set_updated_at();
create table if not exists public.chat_members (
  room_id uuid not null references public.chat_rooms(id) on delete cascade,
  user_id uuid not null references public.member(user_id) on delete cascade,
  role text not null default 'member'
    check (role in ('member', 'admin')),
  last_read_message_id bigint,
  unread_count integer not null default 0 check (unread_count >= 0),
  muted boolean not null default false,
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  primary key (room_id, user_id)
);
create table if not exists public.chat_messages (
  id bigint generated always as identity primary key,
  room_id uuid not null references public.chat_rooms(id) on delete cascade,
  sender_id uuid not null references public.member(user_id) on delete cascade,
  client_message_id uuid not null,
  content text not null check (char_length(trim(content)) between 1 and 1000),
  content_hash text not null,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  unique (sender_id, client_message_id)
);
create table if not exists public.chat_user_blocks (
  blocker_id uuid not null references public.member(user_id) on delete cascade,
  blocked_id uuid not null references public.member(user_id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index if not exists chat_members_user_rooms_idx
  on public.chat_members(user_id, room_id)
  where left_at is null;
create index if not exists chat_members_room_active_idx
  on public.chat_members(room_id, user_id)
  where left_at is null;
create index if not exists chat_messages_room_cursor_idx
  on public.chat_messages(room_id, id desc);
create index if not exists chat_messages_sender_recent_idx
  on public.chat_messages(sender_id, created_at desc);
create index if not exists chat_messages_sender_hash_recent_idx
  on public.chat_messages(sender_id, room_id, content_hash, created_at desc);
create index if not exists chat_rooms_last_message_idx
  on public.chat_rooms(last_message_at desc nulls last, created_at desc);
create index if not exists chat_user_blocks_blocked_idx
  on public.chat_user_blocks(blocked_id, blocker_id);
alter table public.chat_rooms enable row level security;
alter table public.chat_members enable row level security;
alter table public.chat_messages enable row level security;
alter table public.chat_user_blocks enable row level security;
drop policy if exists chat_rooms_select_member on public.chat_rooms;
create policy chat_rooms_select_member
on public.chat_rooms for select to authenticated
using (
  exists (
    select 1
      from public.chat_members cm
     where cm.room_id = chat_rooms.id
       and cm.user_id = (select auth.uid())
       and cm.left_at is null
  )
);
drop policy if exists chat_members_select_self on public.chat_members;
create policy chat_members_select_self
on public.chat_members for select to authenticated
using (user_id = (select auth.uid()));
drop policy if exists chat_messages_select_member on public.chat_messages;
create policy chat_messages_select_member
on public.chat_messages for select to authenticated
using (
  exists (
    select 1
      from public.chat_members cm
     where cm.room_id = chat_messages.room_id
       and cm.user_id = (select auth.uid())
       and cm.left_at is null
  )
);
drop policy if exists chat_user_blocks_select_self on public.chat_user_blocks;
create policy chat_user_blocks_select_self
on public.chat_user_blocks for select to authenticated
using (blocker_id = (select auth.uid()) or blocked_id = (select auth.uid()));
create or replace function private.normalize_chat_content(p_content text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $$
  select trim(regexp_replace(coalesce(p_content, ''), '\s+', ' ', 'g'));
$$;
create or replace function private.chat_is_active_member(p_room_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
      from public.chat_members cm
     where cm.room_id = p_room_id
       and cm.user_id = p_user_id
       and cm.left_at is null
  );
$$;
create or replace function private.chat_are_friends(p_user_id uuid, p_friend_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select p_user_id <> p_friend_user_id
     and exists (
       select 1
         from public.referral_network rn
        where rn.depth = 1
          and rn.status = 'active'
          and (
            (rn.referrer_user_id = p_user_id and rn.referred_user_id = p_friend_user_id)
            or (rn.referrer_user_id = p_friend_user_id and rn.referred_user_id = p_user_id)
          )
     );
$$;
create or replace function private.chat_message_payload(p_message_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_message public.chat_messages%rowtype;
  v_sender public.member%rowtype;
begin
  select * into v_message
    from public.chat_messages
   where id = p_message_id;

  if not found then
    return null;
  end if;

  select * into v_sender
    from public.member
   where user_id = v_message.sender_id;

  return jsonb_build_object(
    'id', v_message.id,
    'roomId', v_message.room_id,
    'senderId', v_message.sender_id,
    'senderName', coalesce(v_sender.mb_name, v_sender.mb_id, 'STO 회원'),
    'clientMessageId', v_message.client_message_id,
    'content', case when v_message.deleted_at is null then v_message.content else '' end,
    'deletedAt', v_message.deleted_at,
    'createdAt', v_message.created_at
  );
end;
$$;
create or replace function private.chat_room_payload(p_room_id uuid, p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_room public.chat_rooms%rowtype;
  v_title text;
  v_member_count integer;
  v_unread_count integer;
  v_members jsonb;
begin
  select * into v_room
    from public.chat_rooms
   where id = p_room_id;

  if not found then
    return null;
  end if;

  select count(*)::integer
    into v_member_count
    from public.chat_members cm
   where cm.room_id = p_room_id
     and cm.left_at is null;

  select coalesce(cm.unread_count, 0)
    into v_unread_count
    from public.chat_members cm
   where cm.room_id = p_room_id
     and cm.user_id = p_user_id
     and cm.left_at is null;

  select coalesce(jsonb_agg(jsonb_build_object(
      'userId', m.user_id,
      'memberId', m.mb_id,
      'name', m.mb_name,
      'avatarUrl', m.mb_profile,
      'role', cm.role
    ) order by case when m.user_id = p_user_id then 0 else 1 end, m.mb_name), '[]'::jsonb)
    into v_members
    from public.chat_members cm
    join public.member m on m.user_id = cm.user_id
   where cm.room_id = p_room_id
     and cm.left_at is null;

  if v_room.room_type = 'direct' then
    select coalesce(m.mb_name, m.mb_id, 'STO 회원')
      into v_title
      from public.chat_members cm
      join public.member m on m.user_id = cm.user_id
     where cm.room_id = p_room_id
       and cm.user_id <> p_user_id
       and cm.left_at is null
     order by cm.joined_at
     limit 1;
  else
    v_title := nullif(trim(coalesce(v_room.title, '')), '');
  end if;

  return jsonb_build_object(
    'id', v_room.id,
    'roomId', v_room.id,
    'roomType', v_room.room_type,
    'title', coalesce(v_title, '그룹 채팅'),
    'lastMessageId', v_room.last_message_id,
    'lastMessagePreview', coalesce(v_room.last_message_preview, ''),
    'lastMessageAt', v_room.last_message_at,
    'unreadCount', coalesce(v_unread_count, 0),
    'memberCount', coalesce(v_member_count, 0),
    'members', v_members,
    'createdAt', v_room.created_at
  );
end;
$$;
create or replace function public.rpc_get_chat_unread_total()
returns integer
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_total integer;
begin
  v_member := private.require_active_member();

  select coalesce(sum(cm.unread_count), 0)::integer
    into v_total
    from public.chat_members cm
   where cm.user_id = v_member.user_id
     and cm.left_at is null;

  return coalesce(v_total, 0);
end;
$$;
create or replace function public.rpc_list_chat_friends()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_result jsonb;
begin
  v_member := private.require_active_member();

  with friend_ids as (
    select rn.referred_user_id as user_id
      from public.referral_network rn
     where rn.referrer_user_id = v_member.user_id
       and rn.depth = 1
       and rn.status = 'active'
    union
    select rn.referrer_user_id as user_id
      from public.referral_network rn
     where rn.referred_user_id = v_member.user_id
       and rn.depth = 1
       and rn.status = 'active'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'userId', m.user_id,
      'memberId', m.mb_id,
      'name', m.mb_name,
      'email', m.mb_email,
      'avatarUrl', m.mb_profile
    ) order by m.mb_name, m.mb_id), '[]'::jsonb)
    into v_result
    from friend_ids f
    join public.member m on m.user_id = f.user_id
   where m.status = 'active';

  return coalesce(v_result, '[]'::jsonb);
end;
$$;
create or replace function public.rpc_list_chat_rooms()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_result jsonb;
begin
  v_member := private.require_active_member();

  select coalesce(jsonb_agg(private.chat_room_payload(cr.id, v_member.user_id)
           order by cr.last_message_at desc nulls last, cr.created_at desc), '[]'::jsonb)
    into v_result
    from public.chat_members cm
    join public.chat_rooms cr on cr.id = cm.room_id
   where cm.user_id = v_member.user_id
     and cm.left_at is null;

  return coalesce(v_result, '[]'::jsonb);
end;
$$;
create or replace function public.rpc_get_chat_room(p_room_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
begin
  v_member := private.require_active_member();

  if not private.chat_is_active_member(p_room_id, v_member.user_id) then
    raise exception using errcode = 'P0001', message = 'CHAT_MEMBER_REQUIRED';
  end if;

  return private.chat_room_payload(p_room_id, v_member.user_id);
end;
$$;
create or replace function public.rpc_create_direct_chat(p_friend_user_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_friend public.member%rowtype;
  v_direct_key text;
  v_room_id uuid;
begin
  v_member := private.require_active_member();

  select * into v_friend
    from public.member
   where user_id = p_friend_user_id
     and status = 'active';

  if not found then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_FOUND';
  end if;

  if not private.chat_are_friends(v_member.user_id, p_friend_user_id) then
    raise exception using errcode = 'P0001', message = 'CHAT_FRIEND_REQUIRED';
  end if;

  if exists (
    select 1 from public.chat_user_blocks b
     where (b.blocker_id = v_member.user_id and b.blocked_id = p_friend_user_id)
        or (b.blocker_id = p_friend_user_id and b.blocked_id = v_member.user_id)
  ) then
    raise exception using errcode = 'P0001', message = 'CHAT_FRIEND_REQUIRED';
  end if;

  v_direct_key := least(v_member.user_id::text, p_friend_user_id::text)
    || ':' || greatest(v_member.user_id::text, p_friend_user_id::text);

  insert into public.chat_rooms (room_type, direct_key, created_by)
  values ('direct', v_direct_key, v_member.user_id)
  on conflict (direct_key) do update set updated_at = public.chat_rooms.updated_at
  returning id into v_room_id;

  insert into public.chat_members (room_id, user_id, role, left_at)
  values
    (v_room_id, v_member.user_id, 'member', null),
    (v_room_id, p_friend_user_id, 'member', null)
  on conflict (room_id, user_id) do update set left_at = null;

  return private.chat_room_payload(v_room_id, v_member.user_id);
end;
$$;
create or replace function public.rpc_create_group_chat(p_title text, p_member_ids uuid[])
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_member_ids uuid[];
  v_member_count integer;
  v_valid_count integer;
  v_room_id uuid;
  v_title text;
begin
  v_member := private.require_active_member();

  select coalesce(array_agg(distinct x), '{}'::uuid[])
    into v_member_ids
    from unnest(coalesce(p_member_ids, '{}'::uuid[])) x
   where x is not null
     and x <> v_member.user_id;

  v_member_count := coalesce(array_length(v_member_ids, 1), 0) + 1;
  if v_member_count < 3 or v_member_count > 30 then
    raise exception using errcode = 'P0001', message = 'CHAT_GROUP_MEMBER_COUNT_INVALID';
  end if;

  select count(*)::integer
    into v_valid_count
    from public.member m
   where m.user_id = any(v_member_ids)
     and m.status = 'active'
     and private.chat_are_friends(v_member.user_id, m.user_id)
     and not exists (
       select 1 from public.chat_user_blocks b
        where (b.blocker_id = v_member.user_id and b.blocked_id = m.user_id)
           or (b.blocker_id = m.user_id and b.blocked_id = v_member.user_id)
     );

  if v_valid_count <> coalesce(array_length(v_member_ids, 1), 0) then
    raise exception using errcode = 'P0001', message = 'CHAT_FRIEND_REQUIRED';
  end if;

  v_title := nullif(left(trim(coalesce(p_title, '')), 40), '');

  insert into public.chat_rooms (room_type, title, created_by)
  values ('group', v_title, v_member.user_id)
  returning id into v_room_id;

  insert into public.chat_members (room_id, user_id, role)
  values (v_room_id, v_member.user_id, 'admin');

  insert into public.chat_members (room_id, user_id, role)
  select v_room_id, unnest(v_member_ids), 'member';

  return private.chat_room_payload(v_room_id, v_member.user_id);
end;
$$;
create or replace function public.rpc_invite_group_members(p_room_id uuid, p_member_ids uuid[])
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_room public.chat_rooms%rowtype;
  v_member_ids uuid[];
  v_current_count integer;
  v_valid_count integer;
begin
  v_member := private.require_active_member();

  select * into v_room
    from public.chat_rooms
   where id = p_room_id
     and room_type = 'group';

  if not found then
    raise exception using errcode = 'P0001', message = 'CHAT_ROOM_NOT_FOUND';
  end if;

  if not exists (
    select 1 from public.chat_members cm
     where cm.room_id = p_room_id
       and cm.user_id = v_member.user_id
       and cm.role = 'admin'
       and cm.left_at is null
  ) then
    raise exception using errcode = 'P0001', message = 'CHAT_MEMBER_REQUIRED';
  end if;

  select coalesce(array_agg(distinct x), '{}'::uuid[])
    into v_member_ids
    from unnest(coalesce(p_member_ids, '{}'::uuid[])) x
   where x is not null
     and x <> v_member.user_id;

  select count(*)::integer into v_current_count
    from public.chat_members cm
   where cm.room_id = p_room_id
     and cm.left_at is null;

  if v_current_count + coalesce(array_length(v_member_ids, 1), 0) > 30 then
    raise exception using errcode = 'P0001', message = 'CHAT_GROUP_MEMBER_COUNT_INVALID';
  end if;

  select count(*)::integer
    into v_valid_count
    from public.member m
   where m.user_id = any(v_member_ids)
     and m.status = 'active'
     and private.chat_are_friends(v_member.user_id, m.user_id);

  if v_valid_count <> coalesce(array_length(v_member_ids, 1), 0) then
    raise exception using errcode = 'P0001', message = 'CHAT_FRIEND_REQUIRED';
  end if;

  insert into public.chat_members (room_id, user_id, role, left_at)
  select p_room_id, unnest(v_member_ids), 'member', null
  on conflict (room_id, user_id) do update set left_at = null;

  return private.chat_room_payload(p_room_id, v_member.user_id);
end;
$$;
create or replace function public.rpc_get_chat_messages(
  p_room_id uuid,
  p_before_message_id bigint default null,
  p_limit integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 50);
  v_result jsonb;
begin
  v_member := private.require_active_member();

  if not private.chat_is_active_member(p_room_id, v_member.user_id) then
    raise exception using errcode = 'P0001', message = 'CHAT_MEMBER_REQUIRED';
  end if;

  with page as (
    select cm.id
      from public.chat_messages cm
     where cm.room_id = p_room_id
       and (p_before_message_id is null or cm.id < p_before_message_id)
     order by cm.id desc
     limit v_limit
  )
  select coalesce(jsonb_agg(private.chat_message_payload(page.id) order by page.id asc), '[]'::jsonb)
    into v_result
    from page;

  return coalesce(v_result, '[]'::jsonb);
end;
$$;
create or replace function public.rpc_send_chat_message(
  p_room_id uuid,
  p_client_message_id uuid,
  p_content text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_normalized text;
  v_hash text;
  v_now timestamptz := now();
  v_last_sent_at timestamptz;
  v_recent_count integer;
  v_same_count integer;
  v_message_id bigint;
begin
  v_member := private.require_active_member();

  if p_client_message_id is null then
    raise exception using errcode = 'P0001', message = 'CHAT_MESSAGE_INVALID';
  end if;

  if not private.chat_is_active_member(p_room_id, v_member.user_id) then
    raise exception using errcode = 'P0001', message = 'CHAT_MEMBER_REQUIRED';
  end if;

  v_normalized := private.normalize_chat_content(p_content);
  if char_length(v_normalized) < 1 or char_length(v_normalized) > 1000 then
    raise exception using errcode = 'P0001', message = 'CHAT_MESSAGE_INVALID';
  end if;

  v_hash := encode(digest(v_normalized, 'sha256'), 'hex');

  select max(created_at)
    into v_last_sent_at
    from public.chat_messages
   where sender_id = v_member.user_id;

  if v_last_sent_at is not null and v_last_sent_at > (v_now - interval '200 milliseconds') then
    raise exception using errcode = 'P0001', message = 'CHAT_MESSAGE_TOO_FAST';
  end if;

  select count(*)::integer
    into v_recent_count
    from public.chat_messages
   where sender_id = v_member.user_id
     and created_at > (v_now - interval '1 second');

  if v_recent_count >= 3 then
    raise exception using errcode = 'P0001', message = 'CHAT_MESSAGE_RATE_LIMITED';
  end if;

  select count(*)::integer
    into v_same_count
    from public.chat_messages
   where sender_id = v_member.user_id
     and room_id = p_room_id
     and content_hash = v_hash
     and created_at > (v_now - interval '10 seconds');

  if v_same_count >= 3 then
    raise exception using errcode = 'P0001', message = 'CHAT_MESSAGE_DUPLICATED';
  end if;

  insert into public.chat_messages (room_id, sender_id, client_message_id, content, content_hash, created_at)
  values (p_room_id, v_member.user_id, p_client_message_id, v_normalized, v_hash, v_now)
  on conflict (sender_id, client_message_id) do update set content = public.chat_messages.content
  returning id into v_message_id;

  update public.chat_rooms
     set last_message_id = v_message_id,
         last_message_preview = left(v_normalized, 120),
         last_message_at = v_now
   where id = p_room_id;

  update public.chat_members
     set unread_count = case when user_id = v_member.user_id then 0 else unread_count + 1 end,
         last_read_message_id = case when user_id = v_member.user_id then greatest(coalesce(last_read_message_id, 0), v_message_id) else last_read_message_id end
   where room_id = p_room_id
     and left_at is null;

  return private.chat_message_payload(v_message_id);
end;
$$;
create or replace function public.rpc_mark_chat_room_read(p_room_id uuid, p_last_message_id bigint default null)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_last_message_id bigint;
begin
  v_member := private.require_active_member();

  if not private.chat_is_active_member(p_room_id, v_member.user_id) then
    raise exception using errcode = 'P0001', message = 'CHAT_MEMBER_REQUIRED';
  end if;

  select coalesce(p_last_message_id, last_message_id)
    into v_last_message_id
    from public.chat_rooms
   where id = p_room_id;

  update public.chat_members
     set unread_count = 0,
         last_read_message_id = greatest(coalesce(last_read_message_id, 0), coalesce(v_last_message_id, 0))
   where room_id = p_room_id
     and user_id = v_member.user_id
     and left_at is null;

  return jsonb_build_object('success', true, 'unreadTotal', public.rpc_get_chat_unread_total());
end;
$$;
revoke all on function private.normalize_chat_content(text) from public, anon, authenticated;
revoke all on function private.chat_is_active_member(uuid, uuid) from public, anon, authenticated;
revoke all on function private.chat_are_friends(uuid, uuid) from public, anon, authenticated;
revoke all on function private.chat_message_payload(bigint) from public, anon, authenticated;
revoke all on function private.chat_room_payload(uuid, uuid) from public, anon, authenticated;
grant execute on function public.rpc_get_chat_unread_total() to authenticated;
grant execute on function public.rpc_list_chat_friends() to authenticated;
grant execute on function public.rpc_list_chat_rooms() to authenticated;
grant execute on function public.rpc_get_chat_room(uuid) to authenticated;
grant execute on function public.rpc_create_direct_chat(uuid) to authenticated;
grant execute on function public.rpc_create_group_chat(text, uuid[]) to authenticated;
grant execute on function public.rpc_invite_group_members(uuid, uuid[]) to authenticated;
grant execute on function public.rpc_get_chat_messages(uuid, bigint, integer) to authenticated;
grant execute on function public.rpc_send_chat_message(uuid, uuid, text) to authenticated;
grant execute on function public.rpc_mark_chat_room_read(uuid, bigint) to authenticated;

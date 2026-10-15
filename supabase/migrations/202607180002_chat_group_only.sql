-- 039: 사용자 화면에서는 그룹 채팅만 노출하고, 채팅방 생성/초대는 관리자 기능으로 분리할 때까지 막는다.

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
    join public.chat_rooms cr on cr.id = cm.room_id
   where cm.user_id = v_member.user_id
     and cm.left_at is null
     and cr.room_type = 'group';

  return coalesce(v_total, 0);
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
     and cm.left_at is null
     and cr.room_type = 'group';

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
  v_room_type text;
begin
  v_member := private.require_active_member();

  select cr.room_type
    into v_room_type
    from public.chat_rooms cr
   where cr.id = p_room_id;

  if v_room_type is distinct from 'group' then
    raise exception using errcode = 'P0001', message = 'CHAT_ROOM_NOT_FOUND';
  end if;

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
begin
  perform private.require_active_member();
  raise exception using errcode = 'P0001', message = 'CHAT_MANAGED_BY_ADMIN';
end;
$$;
create or replace function public.rpc_create_group_chat(p_title text, p_member_ids uuid[])
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  perform private.require_active_member();
  raise exception using errcode = 'P0001', message = 'CHAT_MANAGED_BY_ADMIN';
end;
$$;
create or replace function public.rpc_invite_group_members(p_room_id uuid, p_member_ids uuid[])
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, pg_temp
as $$
begin
  perform private.require_active_member();
  raise exception using errcode = 'P0001', message = 'CHAT_MANAGED_BY_ADMIN';
end;
$$;
grant execute on function public.rpc_get_chat_unread_total() to authenticated;
grant execute on function public.rpc_list_chat_rooms() to authenticated;
grant execute on function public.rpc_get_chat_room(uuid) to authenticated;
grant execute on function public.rpc_create_direct_chat(uuid) to authenticated;
grant execute on function public.rpc_create_group_chat(text, uuid[]) to authenticated;
grant execute on function public.rpc_invite_group_members(uuid, uuid[]) to authenticated;

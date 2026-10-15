-- Fix chat message hashing in environments where pgcrypto functions are not in the public search path.

create extension if not exists pgcrypto with schema extensions;
create or replace function public.rpc_send_chat_message(
  p_room_id uuid,
  p_client_message_id uuid,
  p_content text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public, extensions, pg_temp
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
grant execute on function public.rpc_send_chat_message(uuid, uuid, text) to authenticated;

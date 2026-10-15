-- Chat profile display: include sender profile image in message payloads.

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
    'senderAvatar', coalesce(v_sender.mb_profile, ''),
    'clientMessageId', v_message.client_message_id,
    'content', case when v_message.deleted_at is null then v_message.content else '' end,
    'deletedAt', v_message.deleted_at,
    'createdAt', v_message.created_at
  );
end;
$$;
revoke all on function private.chat_message_payload(bigint) from public, anon, authenticated;
select pg_notify('pgrst', 'reload schema');

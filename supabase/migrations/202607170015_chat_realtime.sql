-- Chat realtime: publish chat message inserts and expose a guarded single-message payload RPC.

alter table public.chat_messages replica identity full;
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1
         from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename = 'chat_messages'
     ) then
    alter publication supabase_realtime add table public.chat_messages;
  end if;
end $$;
create or replace function public.rpc_get_chat_message(p_message_id bigint)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_member public.member%rowtype;
  v_room_id uuid;
begin
  v_member := private.require_active_member();

  select room_id
    into v_room_id
    from public.chat_messages
   where id = p_message_id;

  if not found then
    raise exception using errcode = 'P0001', message = 'CHAT_MESSAGE_NOT_FOUND';
  end if;

  if not private.chat_is_active_member(v_room_id, v_member.user_id) then
    raise exception using errcode = 'P0001', message = 'CHAT_MEMBER_REQUIRED';
  end if;

  return private.chat_message_payload(p_message_id);
end;
$$;
grant execute on function public.rpc_get_chat_message(bigint) to authenticated;

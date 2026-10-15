-- App bootstrap RPC for reducing repeated initial reads.
-- This returns only lightweight app state. Home snapshot remains separate and is cached client-side.

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
  v_notification_unread_total integer := 0;
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
      'notificationUnreadTotal', 0,
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
      'notificationUnreadTotal', 0,
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

  v_member_snapshot := private.member_snapshot(v_member.user_id);

  select count(*)::integer
    into v_notification_unread_total
    from public.notifications
   where user_id = v_member.user_id
     and is_read = false;

  select coalesce(sum(cm.unread_count), 0)::integer
    into v_chat_unread_total
    from public.chat_members cm
   where cm.user_id = v_member.user_id
     and cm.left_at is null;

  v_chat_unread_total := coalesce(v_chat_unread_total, 0);

  begin
    v_popup_state := public.rpc_get_app_popup_state();
  exception when others then
    v_popup_state := null;
  end;

  return jsonb_build_object(
    'memberAccessState', v_access_state,
    'member', v_member_snapshot,
    'popupState', v_popup_state,
    'chatUnreadTotal', v_chat_unread_total,
    'notificationUnreadTotal', v_notification_unread_total,
    'locale', coalesce(v_member.locale, 'ko'),
    'serverTime', now()
  );
end;
$$;
revoke all on function public.rpc_get_app_bootstrap() from public, anon, authenticated;
grant execute on function public.rpc_get_app_bootstrap() to authenticated;

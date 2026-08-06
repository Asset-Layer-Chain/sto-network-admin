-- STO Network Product Admin - 마케팅 유입 이벤트 first_touch / last_touch / signup 확장
-- 회원 상세 payload의 attributionEvents는 event_type별 최신 이벤트 1건씩 반환한다.
-- 각 이벤트 반환 컬럼: channel, source, medium, campaign, ad_group, ad_creative, referral_code, created_at

create or replace function public.rpc_admin_get_member(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_member public.member%rowtype;
  v_internal_balance numeric;
  v_wallet_accounts jsonb;
  v_wallet_addresses jsonb;
  v_deletion_request jsonb;
  v_attribution_events jsonb;
  v_recent_transactions jsonb;
  v_chat_rooms jsonb;
begin
  v_admin := private.require_admin();

  select * into v_member
    from public.member m
   where m.user_id = p_user_id;
  if not found then
    raise exception using errcode = 'P0001', message = 'MEMBER_NOT_FOUND';
  end if;

  select coalesce(wa.available_balance, 0::numeric)
    into v_internal_balance
    from public.wallet_accounts wa
   where wa.user_id = p_user_id
     and wa.asset_code = 'STOC_INT'
     and wa.account_type = 'internal';
  v_internal_balance := coalesce(v_internal_balance, 0::numeric);

  select coalesce(jsonb_agg(
           to_jsonb(wa) || jsonb_build_object(
             'available_balance', wa.available_balance::text,
             'locked_balance', wa.locked_balance::text,
             'wallet_address_id', wad.id,
             'walletAddressId', wad.id,
             'address', wad.address,
             'address_status', wad.status,
             'addressStatus', wad.status,
             'memo_tag', wad.memo_tag,
             'memoTag', wad.memo_tag,
             'address_created_at', wad.created_at,
             'addressCreatedAt', wad.created_at,
             'address_updated_at', wad.updated_at,
             'addressUpdatedAt', wad.updated_at
           ) order by wa.asset_code, wa.account_type
         ), '[]'::jsonb)
    into v_wallet_accounts
    from public.wallet_accounts wa
    left join lateral (
      select wad.*
        from public.wallet_addresses wad
       where wad.user_id = wa.user_id
         and wad.chain = wa.chain
         and (wad.asset_code = wa.asset_code or wad.asset_code = 'STOC_INT')
       order by
         case when wad.asset_code = wa.asset_code then 0 else 1 end,
         case when wad.status = 'active' then 0 else 1 end,
         wad.created_at desc
       limit 1
    ) wad on true
   where wa.user_id = p_user_id;

  select coalesce(jsonb_agg(to_jsonb(wad) order by wad.chain, wad.asset_code), '[]'::jsonb)
    into v_wallet_addresses
    from public.wallet_addresses wad
   where wad.user_id = p_user_id;

  select to_jsonb(mdr)
    into v_deletion_request
    from public.member_deletion_requests mdr
   where mdr.user_id = p_user_id;

  with ranked_events as (
    select
      mae.event_type,
      jsonb_build_object(
        'channel', mae.channel,
        'source', mae.source,
        'medium', mae.medium,
        'campaign', mae.campaign,
        'ad_group', mae.ad_group,
        'ad_creative', mae.ad_creative,
        'referral_code', mae.referral_code,
        'created_at', mae.created_at
      ) as payload,
      row_number() over (
        partition by mae.event_type
        order by mae.created_at desc, mae.id desc
      ) as rn
    from public.marketing_attribution_events mae
    where mae.user_id = p_user_id
      and mae.event_type in ('first_touch', 'last_touch', 'signup')
  ), latest_events as (
    select event_type, payload
      from ranked_events
     where rn = 1
  )
  select jsonb_build_object(
    'firstTouch', (select payload from latest_events where event_type = 'first_touch'),
    'lastTouch', (select payload from latest_events where event_type = 'last_touch'),
    'signup', (select payload from latest_events where event_type = 'signup')
  )
    into v_attribution_events;

  select coalesce(jsonb_agg(private.admin_transaction_payload(q.id) order by q.created_at desc), '[]'::jsonb)
    into v_recent_transactions
    from (
      select t.id, t.created_at
        from public.transactions t
       where t.sender_user_id = p_user_id or t.receiver_user_id = p_user_id
       order by t.created_at desc, t.id desc
       limit 100
    ) q;

  select coalesce(jsonb_agg(jsonb_build_object(
    'roomId', cr.id,
    'title', coalesce(nullif(trim(cr.title), ''), '그룹 채팅'),
    'role', cm.role,
    'joinedAt', cm.joined_at,
    'leftAt', cm.left_at,
    'lastMessageAt', cr.last_message_at
  ) order by cr.last_message_at desc nulls last, cr.created_at desc), '[]'::jsonb)
    into v_chat_rooms
    from public.chat_members cm
    join public.chat_rooms cr on cr.id = cm.room_id
   where cm.user_id = p_user_id
     and cr.room_type = 'group';

  return jsonb_build_object(
    'member', to_jsonb(v_member),
    'internalStocBalance', v_internal_balance::text,
    'walletAccounts', coalesce(v_wallet_accounts, '[]'::jsonb),
    'walletAddresses', coalesce(v_wallet_addresses, '[]'::jsonb),
    'deletionRequest', v_deletion_request,
    'attributionEvents', coalesce(v_attribution_events, jsonb_build_object(
      'firstTouch', null,
      'lastTouch', null,
      'signup', null
    )),
    'recentTransactions', coalesce(v_recent_transactions, '[]'::jsonb),
    'chatRooms', coalesce(v_chat_rooms, '[]'::jsonb)
  );
end;
$$;

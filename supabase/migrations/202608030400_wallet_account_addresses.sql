-- STO Network Product Admin - 지갑 계정 주소 표시 및 주소 기반 회원 검색
-- 회원 상세의 walletAccounts payload에 wallet_addresses.address를 연결하고,
-- 회원 관리 검색어로 지갑 주소를 사용할 수 있게 한다.

create index if not exists idx_wallet_addresses_lower_address
on public.wallet_addresses (lower(address));

create index if not exists idx_wallet_addresses_user_asset_chain
on public.wallet_addresses (user_id, asset_code, chain);

create index if not exists idx_wallet_addresses_user_chain_stoc_int
on public.wallet_addresses (user_id, chain)
where asset_code = 'STOC_INT';

create or replace function public.rpc_admin_list_members(
  p_search text default null,
  p_status text default null,
  p_role text default null,
  p_signup_method text default null,
  p_reg_channel text default null,
  p_is_deleted boolean default null,
  p_page integer default 1,
  p_page_size integer default 30,
  p_sort_column text default 'created_at',
  p_sort_direction text default 'desc'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_admin_grade text;
  v_search_only boolean;
  v_page integer := greatest(coalesce(p_page, 1), 1);
  v_page_size integer;
  v_offset integer;
  v_search text := nullif(trim(coalesce(p_search, '')), '');
  v_sort_column text := lower(coalesce(p_sort_column, 'created_at'));
  v_sort_direction text := lower(coalesce(p_sort_direction, 'desc'));
  v_total bigint;
  v_items jsonb;
begin
  v_admin := private.require_admin();
  v_admin_grade := private.admin_grade_for(v_admin.user_id, v_admin.role);
  v_search_only := v_admin_grade = 'team_lead';
  v_page_size := case
    when v_search_only then least(greatest(coalesce(p_page_size, 20), 1), 20)
    else least(greatest(coalesce(p_page_size, 30), 1), 100)
  end;
  v_offset := (v_page - 1) * v_page_size;

  if v_search_only and v_search is null then
    return jsonb_build_object(
      'items', '[]'::jsonb,
      'page', 1,
      'pageSize', v_page_size,
      'totalCount', 0,
      'searchRequired', true
    );
  end if;

  if v_sort_column not in ('mb_no', 'mb_id', 'mb_name', 'mb_email', 'status', 'role', 'last_login_at', 'created_at', 'updated_at', 'internal_stoc_balance') then
    v_sort_column := 'created_at';
  end if;
  if v_sort_direction not in ('asc', 'desc') then
    v_sort_direction := 'desc';
  end if;

  with filtered as (
    select m.*,
           coalesce(wa.available_balance, 0::numeric) as internal_stoc_balance
      from public.member m
      left join public.wallet_accounts wa
        on wa.user_id = m.user_id
       and wa.asset_code = 'STOC_INT'
       and wa.account_type = 'internal'
     where (
       case
         when v_search_only then
           private.team_lead_member_search_match(
             m.user_id, m.mb_no, m.mb_id, m.mb_name, m.mb_email, m.mb_hp, v_search
           )
           or exists (
             select 1
               from public.wallet_addresses wad
              where wad.user_id = m.user_id
                and lower(wad.address) = lower(v_search)
           )
         else v_search is null or
              m.mb_id ilike '%' || v_search || '%' or
              m.mb_name ilike '%' || v_search || '%' or
              m.mb_email ilike '%' || v_search || '%' or
              coalesce(m.mb_hp, '') ilike '%' || v_search || '%' or
              m.user_id::text ilike '%' || v_search || '%' or
              m.mb_no::text ilike '%' || v_search || '%' or
              m.referral_code ilike '%' || v_search || '%' or
              exists (
                select 1
                  from public.wallet_addresses wad
                 where wad.user_id = m.user_id
                   and wad.address ilike '%' || v_search || '%'
              )
       end
     )
       and (p_status is null or p_status = '' or m.status = p_status)
       and (p_role is null or p_role = '' or m.role = p_role)
       and (p_signup_method is null or p_signup_method = '' or m.signup_method = p_signup_method)
       and (p_reg_channel is null or p_reg_channel = '' or m.reg_channel = p_reg_channel)
       and (p_is_deleted is null or coalesce(m.is_del, false) = p_is_deleted)
  )
  select count(*) into v_total from filtered;

  with filtered as (
    select m.*,
           coalesce(wa.available_balance, 0::numeric) as internal_stoc_balance
      from public.member m
      left join public.wallet_accounts wa
        on wa.user_id = m.user_id
       and wa.asset_code = 'STOC_INT'
       and wa.account_type = 'internal'
     where (
       case
         when v_search_only then
           private.team_lead_member_search_match(
             m.user_id, m.mb_no, m.mb_id, m.mb_name, m.mb_email, m.mb_hp, v_search
           )
           or exists (
             select 1
               from public.wallet_addresses wad
              where wad.user_id = m.user_id
                and lower(wad.address) = lower(v_search)
           )
         else v_search is null or
              m.mb_id ilike '%' || v_search || '%' or
              m.mb_name ilike '%' || v_search || '%' or
              m.mb_email ilike '%' || v_search || '%' or
              coalesce(m.mb_hp, '') ilike '%' || v_search || '%' or
              m.user_id::text ilike '%' || v_search || '%' or
              m.mb_no::text ilike '%' || v_search || '%' or
              m.referral_code ilike '%' || v_search || '%' or
              exists (
                select 1
                  from public.wallet_addresses wad
                 where wad.user_id = m.user_id
                   and wad.address ilike '%' || v_search || '%'
              )
       end
     )
       and (p_status is null or p_status = '' or m.status = p_status)
       and (p_role is null or p_role = '' or m.role = p_role)
       and (p_signup_method is null or p_signup_method = '' or m.signup_method = p_signup_method)
       and (p_reg_channel is null or p_reg_channel = '' or m.reg_channel = p_reg_channel)
       and (p_is_deleted is null or coalesce(m.is_del, false) = p_is_deleted)
  ), page_data as (
    select *
      from filtered f
     order by
       case when v_sort_column = 'mb_no' and v_sort_direction = 'asc' then f.mb_no end asc,
       case when v_sort_column = 'mb_no' and v_sort_direction = 'desc' then f.mb_no end desc,
       case when v_sort_column = 'mb_id' and v_sort_direction = 'asc' then f.mb_id end asc,
       case when v_sort_column = 'mb_id' and v_sort_direction = 'desc' then f.mb_id end desc,
       case when v_sort_column = 'mb_name' and v_sort_direction = 'asc' then f.mb_name end asc,
       case when v_sort_column = 'mb_name' and v_sort_direction = 'desc' then f.mb_name end desc,
       case when v_sort_column = 'mb_email' and v_sort_direction = 'asc' then f.mb_email end asc,
       case when v_sort_column = 'mb_email' and v_sort_direction = 'desc' then f.mb_email end desc,
       case when v_sort_column = 'status' and v_sort_direction = 'asc' then f.status end asc,
       case when v_sort_column = 'status' and v_sort_direction = 'desc' then f.status end desc,
       case when v_sort_column = 'role' and v_sort_direction = 'asc' then f.role end asc,
       case when v_sort_column = 'role' and v_sort_direction = 'desc' then f.role end desc,
       case when v_sort_column = 'last_login_at' and v_sort_direction = 'asc' then f.last_login_at end asc nulls last,
       case when v_sort_column = 'last_login_at' and v_sort_direction = 'desc' then f.last_login_at end desc nulls last,
       case when v_sort_column = 'created_at' and v_sort_direction = 'asc' then f.created_at end asc,
       case when v_sort_column = 'created_at' and v_sort_direction = 'desc' then f.created_at end desc,
       case when v_sort_column = 'updated_at' and v_sort_direction = 'asc' then f.updated_at end asc,
       case when v_sort_column = 'updated_at' and v_sort_direction = 'desc' then f.updated_at end desc,
       case when v_sort_column = 'internal_stoc_balance' and v_sort_direction = 'asc' then f.internal_stoc_balance end asc,
       case when v_sort_column = 'internal_stoc_balance' and v_sort_direction = 'desc' then f.internal_stoc_balance end desc,
       f.user_id
     offset v_offset
     limit v_page_size
  )
  select coalesce(jsonb_agg(
           to_jsonb(page_data) || jsonb_build_object(
             'internal_stoc_balance', page_data.internal_stoc_balance::text
           )
         ), '[]'::jsonb)
    into v_items
    from page_data;

  return jsonb_build_object(
    'items', coalesce(v_items, '[]'::jsonb),
    'page', v_page,
    'pageSize', v_page_size,
    'totalCount', coalesce(v_total, 0),
    'searchRequired', false
  );
end;
$$;

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
  v_devices jsonb;
  v_consents jsonb;
  v_deletion_request jsonb;
  v_marketing_attribution jsonb;
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

  select coalesce(jsonb_agg(to_jsonb(md) - 'push_token' order by md.last_seen_at desc), '[]'::jsonb)
    into v_devices
    from public.member_devices md
   where md.user_id = p_user_id;

  select coalesce(jsonb_agg(to_jsonb(mc) order by mc.created_at desc), '[]'::jsonb)
    into v_consents
    from public.member_consents mc
   where mc.user_id = p_user_id;

  select to_jsonb(mdr)
    into v_deletion_request
    from public.member_deletion_requests mdr
   where mdr.user_id = p_user_id;

  select to_jsonb(mma)
    into v_marketing_attribution
    from public.member_marketing_attribution mma
   where mma.user_id = p_user_id;

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
    'devices', coalesce(v_devices, '[]'::jsonb),
    'consents', coalesce(v_consents, '[]'::jsonb),
    'deletionRequest', v_deletion_request,
    'marketingAttribution', v_marketing_attribution,
    'recentTransactions', coalesce(v_recent_transactions, '[]'::jsonb),
    'chatRooms', coalesce(v_chat_rooms, '[]'::jsonb)
  );
end;
$$;

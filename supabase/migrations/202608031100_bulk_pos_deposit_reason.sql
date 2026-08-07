-- STO Network Product Admin - POS 일괄 지급 처리 사유 프리셋 연동
-- 본부급 POS 일괄 지급 실행 시 회원 상세 지급과 동일하게 deposit 처리 사유를 선택/수정해서 기록한다.

alter table public.admin_bulk_payout_batches
  add column if not exists reason_preset_id uuid references public.admin_transaction_reason_presets(id),
  add column if not exists reason text;

create or replace function private.admin_bulk_payout_batch_payload(p_batch public.admin_bulk_payout_batches)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_batch.id,
    'adminUserId', p_batch.admin_user_id,
    'fileName', p_batch.file_name,
    'fileHash', p_batch.file_hash,
    'status', p_batch.status,
    'totalRows', p_batch.total_rows,
    'payableRows', p_batch.payable_rows,
    'rejectedRows', p_batch.rejected_rows,
    'totalAmount', p_batch.total_amount::text,
    'confirmText', p_batch.confirm_text,
    'reasonPresetId', p_batch.reason_preset_id,
    'reason', p_batch.reason,
    'createdAt', p_batch.created_at,
    'validatedAt', p_batch.validated_at,
    'executedAt', p_batch.executed_at,
    'updatedAt', p_batch.updated_at
  );
$$;

revoke all on function private.admin_bulk_payout_batch_payload(public.admin_bulk_payout_batches) from public, anon, authenticated;

create or replace function public.rpc_admin_execute_bulk_pos_deposit(
  p_batch_id uuid,
  p_confirm_text text,
  p_reason_preset_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_admin_grade text;
  v_batch public.admin_bulk_payout_batches%rowtype;
  v_item public.admin_bulk_payout_items%rowtype;
  v_wallet public.wallet_accounts%rowtype;
  v_balance_before numeric;
  v_balance_after numeric;
  v_transaction_id uuid;
  v_log_id uuid;
  v_items jsonb;
  v_match_count integer;
  v_reason text := trim(coalesce(p_reason, ''));
begin
  v_admin := private.require_admin();
  v_admin_grade := private.require_admin_bulk_deposit_permission(v_admin.user_id, v_admin.role);

  select * into v_batch
    from public.admin_bulk_payout_batches b
   where b.id = p_batch_id
   for update;
  if not found then
    raise exception using errcode = 'P0001', message = 'BULK_POS_BATCH_NOT_FOUND';
  end if;
  if v_batch.status <> 'validated' then
    raise exception using errcode = 'P0001', message = 'BULK_POS_BATCH_NOT_VALIDATED';
  end if;
  if trim(coalesce(p_confirm_text, '')) <> v_batch.confirm_text then
    raise exception using errcode = 'P0001', message = 'BULK_POS_CONFIRM_TEXT_INVALID';
  end if;
  if char_length(v_reason) < 1 then
    raise exception using errcode = 'P0001', message = 'BULK_POS_REASON_REQUIRED';
  end if;
  if char_length(v_reason) > 200 then
    raise exception using errcode = 'P0001', message = 'BULK_POS_REASON_TOO_LONG';
  end if;
  if p_reason_preset_id is not null then
    perform 1
      from public.admin_transaction_reason_presets rp
     where rp.id = p_reason_preset_id
       and rp.action = 'deposit'
       and rp.is_active = true;
    if not found then
      raise exception using errcode = 'P0001', message = 'ADMIN_REASON_PRESET_NOT_FOUND';
    end if;
  end if;
  if exists (
    select 1
      from public.admin_bulk_payout_batches b
     where b.file_hash = v_batch.file_hash
       and b.status = 'completed'
       and b.id <> v_batch.id
    union all
    select 1
      from public.transactions t
     where t.reference_type = 'admin_bulk_pos_deposit'
       and t.status = 'completed'
       and t.metadata ->> 'file_hash' = v_batch.file_hash
    limit 1
  ) then
    raise exception using errcode = 'P0001', message = 'BULK_POS_FILE_ALREADY_COMPLETED';
  end if;
  if exists (
    select 1 from public.admin_bulk_payout_items i
     where i.batch_id = v_batch.id
       and i.status <> 'PAYABLE'
  ) then
    raise exception using errcode = 'P0001', message = 'BULK_POS_HAS_REJECTED_ROWS';
  end if;

  update public.admin_bulk_payout_batches b
     set status = 'processing',
         reason_preset_id = p_reason_preset_id,
         reason = v_reason,
         metadata = coalesce(b.metadata, '{}'::jsonb) || jsonb_build_object(
           'reason', v_reason,
           'reasonPresetId', p_reason_preset_id
         )
   where b.id = v_batch.id
  returning * into v_batch;

  -- 실행 직전 회원명·연락처·지갑주소 매칭을 다시 검증한다.
  for v_item in
    select *
      from public.admin_bulk_payout_items i
     where i.batch_id = v_batch.id
       and i.status = 'PAYABLE'
     order by i.row_no, i.id
     for update
  loop
    select count(*)::integer
      into v_match_count
      from public.member m
      join public.wallet_addresses wad on wad.user_id = m.user_id
     where m.user_id = v_item.user_id
       and lower(trim(coalesce(m.mb_name, ''))) = lower(v_item.mb_name)
       and private.normalize_admin_bulk_pos_phone(m.mb_hp) = v_item.normalized_phone
       and lower(trim(coalesce(wad.address, ''))) = v_item.normalized_wallet_address
       and coalesce(m.is_del, false) = false
       and coalesce(m.status, '') <> 'deleted';

    if v_match_count <> 1 then
      raise exception using errcode = 'P0001', message = 'BULK_POS_HAS_REJECTED_ROWS';
    end if;
  end loop;

  for v_item in
    select *
      from public.admin_bulk_payout_items i
     where i.batch_id = v_batch.id
       and i.status = 'PAYABLE'
     order by i.row_no, i.id
     for update
  loop
    insert into public.wallet_accounts(user_id, asset_code, account_type, available_balance, locked_balance)
    values (v_item.user_id, 'STOC_INT', 'internal', 0, 0)
    on conflict (user_id, asset_code, account_type) do nothing;

    select * into v_wallet
      from public.wallet_accounts wa
     where wa.user_id = v_item.user_id
       and wa.asset_code = 'STOC_INT'
       and wa.account_type = 'internal'
     for update;

    v_balance_before := v_wallet.available_balance;

    update public.wallet_accounts wa
       set available_balance = wa.available_balance + v_item.amount,
           updated_at = now()
     where wa.id = v_wallet.id
    returning wa.available_balance into v_balance_after;

    insert into public.transactions(
      sender_user_id,
      receiver_user_id,
      asset_code,
      amount,
      fee_amount,
      transaction_type,
      status,
      description,
      reference_type,
      idempotency_key,
      metadata,
      processed_at
    ) values (
      null,
      v_item.user_id,
      'STOC_INT',
      v_item.amount,
      0,
      'deposit',
      'completed',
      v_reason,
      'admin_bulk_pos_deposit',
      'admin_bulk_pos_deposit:' || v_batch.id::text || ':' || v_item.id::text,
      jsonb_build_object(
        'source', 'admin_bulk_pos_deposit',
        'batch_id', v_batch.id,
        'batch_item_id', v_item.id,
        'file_name', v_batch.file_name,
        'file_hash', v_batch.file_hash,
        'row_no', v_item.row_no,
        'admin_actor_user_id', v_admin.user_id,
        'admin_actor_member_id', v_admin.mb_id,
        'admin_grade', v_admin_grade,
        'target_user_id', v_item.user_id,
        'member_name', v_item.mb_name,
        'phone', v_item.mb_hp,
        'normalized_phone', v_item.normalized_phone,
        'contract_period', v_item.contract_period,
        'wallet_address', v_item.wallet_address,
        'reason', v_reason,
        'reason_preset_id', p_reason_preset_id,
        'balance_before', v_balance_before,
        'balance_after', v_balance_after
      ),
      now()
    ) returning id into v_transaction_id;

    update public.admin_bulk_payout_items i
       set status = 'PAID',
           transaction_id = v_transaction_id
     where i.id = v_item.id;

    insert into public.admin_action_logs(
      actor_user_id, action_type, target_user_id, transaction_id,
      reason, idempotency_key, before_data, after_data, metadata
    ) values (
      v_admin.user_id,
      'wallet.deposit.bulk_pos',
      v_item.user_id,
      v_transaction_id,
      v_reason,
      'admin_bulk_pos_deposit:' || v_batch.id::text || ':' || v_item.id::text,
      jsonb_build_object('assetCode', 'STOC_INT', 'availableBalance', v_balance_before),
      jsonb_build_object('assetCode', 'STOC_INT', 'availableBalance', v_balance_after),
      jsonb_build_object(
        'amount', v_item.amount,
        'batchId', v_batch.id,
        'rowNo', v_item.row_no,
        'fileName', v_batch.file_name,
        'fileHash', v_batch.file_hash,
        'contractPeriod', v_item.contract_period,
        'walletAddress', v_item.wallet_address,
        'adminGrade', v_admin_grade,
        'reason', v_reason,
        'reasonPresetId', p_reason_preset_id
      )
    ) returning id into v_log_id;
  end loop;

  update public.admin_bulk_payout_batches b
     set status = 'completed',
         executed_at = now()
   where b.id = v_batch.id
  returning * into v_batch;

  select coalesce(jsonb_agg(private.admin_bulk_payout_item_payload(i) order by i.row_no, i.id), '[]'::jsonb)
    into v_items
    from public.admin_bulk_payout_items i
   where i.batch_id = v_batch.id;

  return jsonb_build_object(
    'batch', private.admin_bulk_payout_batch_payload(v_batch),
    'items', coalesce(v_items, '[]'::jsonb),
    'summary', jsonb_build_object(
      'totalRows', v_batch.total_rows,
      'payableRows', v_batch.payable_rows,
      'rejectedRows', v_batch.rejected_rows,
      'totalAmount', v_batch.total_amount::text
    )
  );
end;
$$;



create or replace function public.rpc_admin_execute_bulk_pos_deposit(
  p_batch_id uuid,
  p_confirm_text text
)
returns jsonb
language sql
volatile
security definer
set search_path = ''
as $$
  select public.rpc_admin_execute_bulk_pos_deposit(p_batch_id, p_confirm_text, null::uuid, 'POS 일괄 지급'::text);
$$;

revoke all on function public.rpc_admin_execute_bulk_pos_deposit(uuid, text, uuid, text) from public, anon, authenticated;
revoke all on function public.rpc_admin_execute_bulk_pos_deposit(uuid, text) from public, anon, authenticated;

grant execute on function public.rpc_admin_execute_bulk_pos_deposit(uuid, text, uuid, text) to authenticated;
grant execute on function public.rpc_admin_execute_bulk_pos_deposit(uuid, text) to authenticated;

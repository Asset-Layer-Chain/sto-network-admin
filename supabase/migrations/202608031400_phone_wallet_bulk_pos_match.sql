-- STO Network Product Admin - POS 일괄 지급 연락처+지갑주소 매칭
-- 회원명은 검증 조건에서 제외하고 기록/표시용으로만 보존한다.
-- 지급 대상은 연락처와 지갑주소가 정확히 1명의 활성 회원에 매칭될 때만 통과한다.


alter table public.admin_bulk_payout_items
  drop constraint if exists admin_bulk_payout_items_status_check;

alter table public.admin_bulk_payout_items
  add constraint admin_bulk_payout_items_status_check
  check (status in (
    'PAYABLE',
    'PAID',
    'INVALID_ROW',
    'INVALID_AMOUNT',
    'NOT_FOUND',
    'MULTIPLE_MATCHES',
    'DUPLICATED_IN_EXCEL',
    'FILE_ALREADY_COMPLETED',
    'FAILED'
  ));

create index if not exists member_bulk_pos_phone_active_idx
  on public.member (private.normalize_admin_bulk_pos_phone(mb_hp), user_id)
  where coalesce(is_del, false) = false
    and coalesce(status, '') <> 'deleted';

create or replace function private.admin_bulk_payout_item_payload(p_item public.admin_bulk_payout_items)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', p_item.id,
    'batchId', p_item.batch_id,
    'rowNo', p_item.row_no,
    'userId', p_item.user_id,
    'memberName', p_item.mb_name,
    'excelMemberName', p_item.mb_name,
    'dbMemberName', p_item.metadata ->> 'dbMemberName',
    'phone', p_item.mb_hp,
    'normalizedPhone', p_item.normalized_phone,
    'contractPeriod', p_item.contract_period,
    'walletAddress', p_item.wallet_address,
    'amount', case when p_item.amount is null then null else p_item.amount::text end,
    'status', p_item.status,
    'errorCode', p_item.error_code,
    'transactionId', p_item.transaction_id,
    'createdAt', p_item.created_at,
    'updatedAt', p_item.updated_at
  );
$$;

revoke all on function private.admin_bulk_payout_item_payload(public.admin_bulk_payout_items) from public, anon, authenticated;

create or replace function public.rpc_admin_validate_bulk_pos_deposit(
  p_file_name text,
  p_file_hash text,
  p_rows jsonb
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_grade text;
  v_file_name text := trim(coalesce(p_file_name, ''));
  v_file_hash text := lower(trim(coalesce(p_file_hash, '')));
  v_rows jsonb := coalesce(p_rows, '[]'::jsonb);
  v_row_count integer;
  v_file_completed boolean;
  v_batch public.admin_bulk_payout_batches%rowtype;
  v_status text;
  v_payable_rows integer;
  v_rejected_rows integer;
  v_total_amount numeric;
  v_items jsonb;
begin
  v_admin := private.require_admin();
  v_grade := private.require_admin_bulk_deposit_permission(v_admin.user_id, v_admin.role);

  if jsonb_typeof(v_rows) <> 'array' then
    raise exception using errcode = 'P0001', message = 'BULK_POS_ROWS_REQUIRED';
  end if;

  v_row_count := jsonb_array_length(v_rows);

  if v_row_count < 1 then
    raise exception using errcode = 'P0001', message = 'BULK_POS_ROWS_REQUIRED';
  end if;

  if v_row_count > 2000 then
    raise exception using errcode = 'P0001', message = 'BULK_POS_TOO_MANY_ROWS';
  end if;

  if v_file_name = '' or v_file_hash = '' then
    raise exception using errcode = 'P0001', message = 'BULK_POS_INVALID_ROW';
  end if;

  select exists (
    select 1
      from public.admin_bulk_payout_batches b
     where b.file_hash = v_file_hash
       and b.status = 'completed'
    union all
    select 1
      from public.transactions t
     where t.reference_type = 'admin_bulk_pos_deposit'
       and t.status = 'completed'
       and t.metadata ->> 'file_hash' = v_file_hash
    limit 1
  ) into v_file_completed;

  insert into public.admin_bulk_payout_batches(
    admin_user_id,
    file_name,
    file_hash,
    status,
    total_rows,
    metadata
  ) values (
    v_admin.user_id,
    v_file_name,
    v_file_hash,
    'validated',
    v_row_count,
    jsonb_build_object('source', 'admin_bulk_pos_deposit_validate', 'adminGrade', v_grade, 'validationVersion', 'phone_wallet_v1')
  ) returning * into v_batch;

  with raw_rows as (
    select
      row_number() over ()::integer as input_index,
      r."rowNo",
      r."memberName",
      r.phone,
      r."contractPeriod",
      r."walletAddress",
      r.amount
    from jsonb_to_recordset(v_rows) as r(
      "rowNo" integer,
      "memberName" text,
      phone text,
      "contractPeriod" text,
      "walletAddress" text,
      amount text
    )
  ), input_rows as (
    select
      rr.input_index,
      coalesce(rr."rowNo", rr.input_index + 1)::integer as row_no,
      trim(coalesce(rr."memberName", '')) as member_name,
      trim(coalesce(rr.phone, '')) as phone,
      private.normalize_admin_bulk_pos_phone(rr.phone) as normalized_phone,
      trim(coalesce(rr."contractPeriod", '')) as contract_period,
      trim(coalesce(rr."walletAddress", '')) as wallet_address,
      lower(trim(coalesce(rr."walletAddress", ''))) as normalized_wallet_address,
      regexp_replace(replace(trim(coalesce(rr.amount, '')), ',', ''), '[[:space:]]+', '', 'g') as raw_amount
    from raw_rows rr
  ), amount_rows as (
    select
      ir.*,
      case
        when ir.raw_amount ~ '^[0-9]+(\.[0-9]*)?$' then
          split_part(ir.raw_amount, '.', 1) ||
          case
            when position('.' in ir.raw_amount) > 0 and left(split_part(ir.raw_amount, '.', 2), 8) <> ''
            then '.' || left(split_part(ir.raw_amount, '.', 2), 8)
            else ''
          end
        else ir.raw_amount
      end as amount_normalized
    from input_rows ir
  ), normalized_rows as (
    select
      ar.*,
      case
        when ar.amount_normalized ~ '^[0-9]+(\.[0-9]{1,8})?$'
         and ar.amount_normalized::numeric > 0
         and ar.amount_normalized::numeric <= 999999999999999.99999999::numeric
        then ar.amount_normalized::numeric
        else null
      end as amount_numeric,
      case
        when ar.amount_normalized ~ '^[0-9]+(\.[0-9]{1,8})?$'
         and ar.amount_normalized::numeric > 0
         and ar.amount_normalized::numeric <= 999999999999999.99999999::numeric
        then ar.amount_normalized::numeric::text
        else ar.amount_normalized
      end as amount_key,
      (
        ar.normalized_phone = ''
        or ar.contract_period = ''
        or ar.normalized_wallet_address = ''
        or ar.raw_amount = ''
      ) as has_missing_required
    from amount_rows ar
  ), duplicate_check as (
    select
      nr.*,
      count(*) over (
        partition by nr.normalized_phone, nr.normalized_wallet_address
      ) as duplicate_count
    from normalized_rows nr
  ), match_counts as (
    select
      dc.input_index,
      min(m.user_id::text)::uuid as user_id,
      min(nullif(trim(coalesce(m.mb_name, '')), '')) as db_member_name,
      count(distinct m.user_id)::integer as match_count
    from duplicate_check dc
    left join public.wallet_addresses wad
      on dc.normalized_wallet_address <> ''
     and lower(trim(coalesce(wad.address, ''))) = dc.normalized_wallet_address
    left join public.member m
      on dc.normalized_phone <> ''
     and m.user_id = wad.user_id
     and private.normalize_admin_bulk_pos_phone(m.mb_hp) = dc.normalized_phone
     and coalesce(m.is_del, false) = false
     and coalesce(m.status, '') <> 'deleted'
    group by dc.input_index
  ), matched_rows as (
    select
      dc.*,
      mc.user_id,
      mc.db_member_name,
      coalesce(mc.match_count, 0) as match_count
    from duplicate_check dc
    left join match_counts mc on mc.input_index = dc.input_index
  ), final_rows as (
    select
      mr.*,
      case
        when v_file_completed then 'FILE_ALREADY_COMPLETED'
        when mr.has_missing_required then 'INVALID_ROW'
        when mr.amount_numeric is null then 'INVALID_AMOUNT'
        when mr.duplicate_count > 1 then 'DUPLICATED_IN_EXCEL'
        when mr.match_count = 0 then 'NOT_FOUND'
        when mr.match_count > 1 then 'MULTIPLE_MATCHES'
        else 'PAYABLE'
      end as final_status,
      case
        when v_file_completed then 'FILE_ALREADY_COMPLETED'
        when mr.has_missing_required then 'INVALID_ROW'
        when mr.amount_numeric is null then 'INVALID_AMOUNT'
        when mr.duplicate_count > 1 then 'DUPLICATED_IN_EXCEL'
        when mr.match_count = 0 then 'NOT_FOUND'
        when mr.match_count > 1 then 'MULTIPLE_MATCHES'
        else null
      end as error_code
    from matched_rows mr
  )
  insert into public.admin_bulk_payout_items(
    batch_id,
    row_no,
    user_id,
    mb_name,
    mb_hp,
    normalized_phone,
    contract_period,
    wallet_address,
    normalized_wallet_address,
    amount,
    status,
    error_code,
    metadata
  )
  select
    v_batch.id,
    fr.row_no,
    case when fr.final_status = 'PAYABLE' then fr.user_id else null end,
    fr.member_name,
    fr.phone,
    fr.normalized_phone,
    fr.contract_period,
    fr.wallet_address,
    fr.normalized_wallet_address,
    fr.amount_numeric,
    fr.final_status,
    fr.error_code,
    jsonb_build_object(
      'duplicateCount', fr.duplicate_count,
      'matchCount', fr.match_count,
      'matchCriteria', 'phone_wallet',
      'duplicateCriteria', 'phone_wallet',
      'excelMemberName', fr.member_name,
      'dbMemberName', fr.db_member_name,
      'rawAmount', fr.raw_amount,
      'normalizedAmount', fr.amount_key,
      'validationVersion', 'phone_wallet_v1'
    )
  from final_rows fr;

  select
    count(*) filter (where i.status = 'PAYABLE')::integer,
    count(*) filter (where i.status <> 'PAYABLE')::integer,
    coalesce(sum(i.amount) filter (where i.status = 'PAYABLE'), 0::numeric)
    into v_payable_rows, v_rejected_rows, v_total_amount
    from public.admin_bulk_payout_items i
   where i.batch_id = v_batch.id;

  v_status := case when v_rejected_rows = 0 and v_payable_rows = v_row_count then 'validated' else 'rejected' end;

  update public.admin_bulk_payout_batches b
     set status = v_status,
         payable_rows = v_payable_rows,
         rejected_rows = v_rejected_rows,
         total_amount = v_total_amount,
         confirm_text = 'PAY_' || v_payable_rows::text || '_ROWS',
         validated_at = now(),
         metadata = coalesce(b.metadata, '{}'::jsonb) || jsonb_build_object('validationVersion', 'phone_wallet_v1')
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
    ),
    'canExecute', v_batch.status = 'validated',
    'confirmText', v_batch.confirm_text
  );
end;
$$;


-- 실행 직전 재검증도 연락처+지갑주소 기준으로 맞춘다.
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

  -- 실행 직전 연락처·지갑주소 매칭을 다시 검증한다. 회원명은 검증 조건에서 제외한다.
  for v_item in
    select *
      from public.admin_bulk_payout_items i
     where i.batch_id = v_batch.id
       and i.status = 'PAYABLE'
     order by i.row_no, i.id
     for update
  loop
    select count(distinct m.user_id)::integer
      into v_match_count
      from public.member m
      join public.wallet_addresses wad on wad.user_id = m.user_id
     where m.user_id = v_item.user_id
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
        'member_name', coalesce(v_item.metadata ->> 'dbMemberName', v_item.mb_name),
        'excel_member_name', v_item.mb_name,
        'db_member_name', v_item.metadata ->> 'dbMemberName',
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
        'excelMemberName', v_item.mb_name,
        'dbMemberName', v_item.metadata ->> 'dbMemberName',
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

-- STO Network Product Admin - POS 일괄 지급 검증 성능 개선
-- 1,000건 이상 Excel 검증 시 row별 lateral scan으로 statement_timeout이 발생할 수 있어
-- 주소/파일해시 인덱스를 추가하고 검증 RPC의 회원·지갑 매칭을 set-based join으로 변경한다.

create index if not exists wallet_addresses_bulk_pos_address_user_idx
  on public.wallet_addresses (lower(trim(coalesce(address, ''))), user_id);

create index if not exists transactions_bulk_pos_completed_file_hash_idx
  on public.transactions ((metadata ->> 'file_hash'))
  where reference_type = 'admin_bulk_pos_deposit'
    and status = 'completed';

create index if not exists member_bulk_pos_name_phone_active_idx
  on public.member (lower(trim(coalesce(mb_name, ''))), private.normalize_admin_bulk_pos_phone(mb_hp))
  where coalesce(is_del, false) = false
    and coalesce(status, '') <> 'deleted';

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
    jsonb_build_object('source', 'admin_bulk_pos_deposit_validate', 'adminGrade', v_grade, 'validationVersion', 'set_based_v2')
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
      replace(trim(coalesce(rr.amount, '')), ',', '') as raw_amount
    from raw_rows rr
  ), normalized_rows as (
    select
      ir.*,
      case
        when ir.raw_amount ~ '^[0-9]+(\.[0-9]{1,8})?$'
         and ir.raw_amount::numeric > 0
         and ir.raw_amount::numeric <= 999999999999999.99999999::numeric
        then ir.raw_amount::numeric
        else null
      end as amount_numeric,
      case
        when ir.raw_amount ~ '^[0-9]+(\.[0-9]{1,8})?$'
         and ir.raw_amount::numeric > 0
         and ir.raw_amount::numeric <= 999999999999999.99999999::numeric
        then ir.raw_amount::numeric::text
        else ir.raw_amount
      end as amount_key,
      (
        ir.member_name = ''
        or ir.normalized_phone = ''
        or ir.contract_period = ''
        or ir.normalized_wallet_address = ''
        or ir.raw_amount = ''
      ) as has_missing_required
    from input_rows ir
  ), duplicate_check as (
    select
      nr.*,
      count(*) over (
        partition by lower(nr.member_name), nr.normalized_phone, nr.contract_period, nr.normalized_wallet_address, nr.amount_key
      ) as duplicate_count
    from normalized_rows nr
  ), match_counts as (
    select
      dc.input_index,
      min(m.user_id::text)::uuid as user_id,
      count(distinct m.user_id)::integer as match_count
    from duplicate_check dc
    left join public.wallet_addresses wad
      on lower(trim(coalesce(wad.address, ''))) = dc.normalized_wallet_address
    left join public.member m
      on m.user_id = wad.user_id
     and lower(trim(coalesce(m.mb_name, ''))) = lower(dc.member_name)
     and private.normalize_admin_bulk_pos_phone(m.mb_hp) = dc.normalized_phone
     and coalesce(m.is_del, false) = false
     and coalesce(m.status, '') <> 'deleted'
    group by dc.input_index
  ), matched_rows as (
    select
      dc.*,
      mc.user_id,
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
        when mr.match_count <> 1 then 'NOT_FOUND'
        else 'PAYABLE'
      end as final_status,
      case
        when v_file_completed then 'FILE_ALREADY_COMPLETED'
        when mr.has_missing_required then 'INVALID_ROW'
        when mr.amount_numeric is null then 'INVALID_AMOUNT'
        when mr.duplicate_count > 1 then 'DUPLICATED_IN_EXCEL'
        when mr.match_count <> 1 then 'NOT_FOUND'
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
      'rawAmount', fr.raw_amount,
      'validationVersion', 'set_based_v2'
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
         metadata = coalesce(b.metadata, '{}'::jsonb) || jsonb_build_object('validationVersion', 'set_based_v2')
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

-- STO Network Product Admin - POS 일괄 지급
-- 본부(headquarters) 전용. 엑셀 검증 결과에 제외 건이 있으면 전체 실행을 반려한다.
-- 이미 지급 완료된 동일 파일 SHA-256 해시는 재사용할 수 없다.

create table if not exists public.admin_bulk_payout_batches (
  id uuid primary key default extensions.gen_random_uuid(),
  admin_user_id uuid not null references public.member(user_id),
  file_name text not null,
  file_hash text not null,
  status text not null default 'validated' check (status in ('validated', 'rejected', 'processing', 'completed', 'failed')),
  total_rows integer not null default 0,
  payable_rows integer not null default 0,
  rejected_rows integer not null default 0,
  total_amount numeric not null default 0,
  confirm_text text,
  created_at timestamptz not null default now(),
  validated_at timestamptz,
  executed_at timestamptz,
  updated_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

create table if not exists public.admin_bulk_payout_items (
  id uuid primary key default extensions.gen_random_uuid(),
  batch_id uuid not null references public.admin_bulk_payout_batches(id) on delete cascade,
  row_no integer not null,
  user_id uuid references public.member(user_id),
  mb_name text not null,
  mb_hp text not null,
  normalized_phone text not null,
  contract_period text not null,
  wallet_address text not null,
  normalized_wallet_address text not null,
  amount numeric,
  status text not null check (status in ('PAYABLE', 'PAID', 'INVALID_ROW', 'INVALID_AMOUNT', 'NOT_FOUND', 'DUPLICATED_IN_EXCEL', 'FILE_ALREADY_COMPLETED', 'FAILED')),
  error_code text,
  transaction_id uuid references public.transactions(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

create unique index if not exists admin_bulk_payout_batches_completed_file_hash_uidx
  on public.admin_bulk_payout_batches(file_hash)
  where status = 'completed';

create index if not exists admin_bulk_payout_batches_admin_created_idx
  on public.admin_bulk_payout_batches(admin_user_id, created_at desc);

create index if not exists admin_bulk_payout_items_batch_row_idx
  on public.admin_bulk_payout_items(batch_id, row_no);

create index if not exists admin_bulk_payout_items_user_created_idx
  on public.admin_bulk_payout_items(user_id, created_at desc)
  where user_id is not null;

alter table public.admin_bulk_payout_batches enable row level security;
alter table public.admin_bulk_payout_items enable row level security;
revoke all on public.admin_bulk_payout_batches from public, anon, authenticated;
revoke all on public.admin_bulk_payout_items from public, anon, authenticated;

create or replace function private.touch_admin_bulk_payout_updated_at()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

revoke all on function private.touch_admin_bulk_payout_updated_at() from public, anon, authenticated;

drop trigger if exists admin_bulk_payout_batches_touch_updated_at on public.admin_bulk_payout_batches;
create trigger admin_bulk_payout_batches_touch_updated_at
before update on public.admin_bulk_payout_batches
for each row execute function private.touch_admin_bulk_payout_updated_at();

drop trigger if exists admin_bulk_payout_items_touch_updated_at on public.admin_bulk_payout_items;
create trigger admin_bulk_payout_items_touch_updated_at
before update on public.admin_bulk_payout_items
for each row execute function private.touch_admin_bulk_payout_updated_at();

create or replace function private.normalize_admin_bulk_pos_phone(p_phone text)
returns text
language sql
immutable
security definer
set search_path = ''
as $$
  select regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
$$;

create or replace function private.require_admin_bulk_deposit_permission(
  p_user_id uuid,
  p_member_role text
)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_grade text;
begin
  v_grade := private.admin_grade_for(p_user_id, p_member_role);
  if v_grade <> 'headquarters' then
    raise exception using errcode = 'P0001', message = 'ADMIN_BULK_DEPOSIT_PERMISSION_DENIED';
  end if;
  return v_grade;
end;
$$;

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
    'createdAt', p_batch.created_at,
    'validatedAt', p_batch.validated_at,
    'executedAt', p_batch.executed_at,
    'updatedAt', p_batch.updated_at
  );
$$;

revoke all on function private.normalize_admin_bulk_pos_phone(text) from public, anon, authenticated;
revoke all on function private.require_admin_bulk_deposit_permission(uuid, text) from public, anon, authenticated;
revoke all on function private.admin_bulk_payout_item_payload(public.admin_bulk_payout_items) from public, anon, authenticated;
revoke all on function private.admin_bulk_payout_batch_payload(public.admin_bulk_payout_batches) from public, anon, authenticated;

create or replace function public.rpc_admin_get_session()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_admin public.member%rowtype;
  v_grade text;
  v_grade_label text;
begin
  v_admin := private.require_admin();
  v_grade := private.admin_grade_for(v_admin.user_id, v_admin.role);
  v_grade_label := case v_grade
    when 'team_lead' then '팀장급'
    when 'center_director' then '센터장'
    when 'headquarters' then '본부'
    else '자산 권한 미설정'
  end;

  return jsonb_build_object(
    'userId', v_admin.user_id,
    'memberNo', v_admin.mb_no,
    'memberId', v_admin.mb_id,
    'name', v_admin.mb_name,
    'email', v_admin.mb_email,
    'profile', v_admin.mb_profile,
    'role', v_admin.role,
    'adminGrade', v_grade,
    'adminGradeLabel', v_grade_label,
    'permissions', jsonb_build_object(
      'memberRead', true,
      'memberListBrowse', v_grade is distinct from 'team_lead',
      'memberSearch', true,
      'assetDeposit', v_grade = 'headquarters',
      'assetWithdrawal', v_grade in ('center_director', 'headquarters'),
      'assetAirdrop', v_grade in ('team_lead', 'center_director', 'headquarters'),
      'reasonPresetManage', v_grade in ('center_director', 'headquarters'),
      'bulkDepositManage', v_grade = 'headquarters',
      'chatManage', true,
      'adminLogRead', true
    )
  );
end;
$$;

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
    jsonb_build_object('source', 'admin_bulk_pos_deposit_validate', 'adminGrade', v_grade)
  ) returning * into v_batch;

  with input_rows as (
    select
      coalesce(r."rowNo", row_number() over ())::integer as row_no,
      trim(coalesce(r."memberName", '')) as member_name,
      trim(coalesce(r.phone, '')) as phone,
      private.normalize_admin_bulk_pos_phone(r.phone) as normalized_phone,
      trim(coalesce(r."contractPeriod", '')) as contract_period,
      trim(coalesce(r."walletAddress", '')) as wallet_address,
      lower(trim(coalesce(r."walletAddress", ''))) as normalized_wallet_address,
      replace(trim(coalesce(r.amount, '')), ',', '') as raw_amount
    from jsonb_to_recordset(v_rows) as r(
      "rowNo" integer,
      "memberName" text,
      phone text,
      "contractPeriod" text,
      "walletAddress" text,
      amount text
    )
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
  ), matched_rows as (
    select
      dc.*,
      match_result.user_id,
      match_result.match_count
    from duplicate_check dc
    left join lateral (
      select min(m.user_id) as user_id, count(*)::integer as match_count
        from public.member m
        join public.wallet_addresses wad on wad.user_id = m.user_id
       where lower(trim(coalesce(m.mb_name, ''))) = lower(dc.member_name)
         and private.normalize_admin_bulk_pos_phone(m.mb_hp) = dc.normalized_phone
         and lower(trim(coalesce(wad.address, ''))) = dc.normalized_wallet_address
         and coalesce(m.is_del, false) = false
         and coalesce(m.status, '') <> 'deleted'
    ) match_result on true
  ), final_rows as (
    select
      mr.*,
      case
        when v_file_completed then 'FILE_ALREADY_COMPLETED'
        when mr.has_missing_required then 'INVALID_ROW'
        when mr.amount_numeric is null then 'INVALID_AMOUNT'
        when mr.duplicate_count > 1 then 'DUPLICATED_IN_EXCEL'
        when coalesce(mr.match_count, 0) <> 1 then 'NOT_FOUND'
        else 'PAYABLE'
      end as final_status,
      case
        when v_file_completed then 'FILE_ALREADY_COMPLETED'
        when mr.has_missing_required then 'INVALID_ROW'
        when mr.amount_numeric is null then 'INVALID_AMOUNT'
        when mr.duplicate_count > 1 then 'DUPLICATED_IN_EXCEL'
        when coalesce(mr.match_count, 0) <> 1 then 'NOT_FOUND'
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
    jsonb_build_object('duplicateCount', fr.duplicate_count, 'matchCount', coalesce(fr.match_count, 0), 'rawAmount', fr.raw_amount)
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
         validated_at = now()
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

create or replace function public.rpc_admin_execute_bulk_pos_deposit(
  p_batch_id uuid,
  p_confirm_text text
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
     set status = 'processing'
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
      'POS 일괄 지급',
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
        'reason', 'POS 일괄 지급',
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
      'POS 일괄 지급',
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
        'adminGrade', v_admin_grade
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

revoke all on function public.rpc_admin_get_session() from public, anon;
revoke all on function public.rpc_admin_validate_bulk_pos_deposit(text, text, jsonb) from public, anon;
revoke all on function public.rpc_admin_execute_bulk_pos_deposit(uuid, text) from public, anon;

grant execute on function public.rpc_admin_get_session() to authenticated;
grant execute on function public.rpc_admin_validate_bulk_pos_deposit(text, text, jsonb) to authenticated;
grant execute on function public.rpc_admin_execute_bulk_pos_deposit(uuid, text) to authenticated;

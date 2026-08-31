import { callRpc, createIdempotencyKey } from './rpcClient.js';

function toIso(value) {
  if (!value) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

export function adjustStoc({ userId, action, amount, reason, idempotencyKey }) {
  return callRpc('rpc_admin_adjust_stoc', {
    p_target_user_id: userId,
    p_action: action,
    p_amount: String(amount || '').trim(),
    p_reason: String(reason || '').trim(),
    p_idempotency_key: idempotencyKey || createIdempotencyKey(`admin-${action}`),
  });
}

export async function listTransactions(filters = {}) {
  const result = await callRpc('rpc_admin_list_transactions_cursor', {
    p_search: filters.search || null,
    p_transaction_type: filters.transactionType || null,
    p_status: filters.status || null,
    p_asset_code: filters.assetCode || null,
    p_user_id: filters.userId || null,
    p_from_at: toIso(filters.fromAt),
    p_to_at: toIso(filters.toAt),
    p_cursor_created_at: filters.cursor?.createdAt || null,
    p_cursor_id: filters.cursor?.id || null,
    p_include_total: filters.includeTotal !== false,
    p_page: Number(filters.page || 1),
    p_page_size: Number(filters.pageSize || 30),
  });

  const rawTotalCount = result?.totalCount ?? result?.total_count ?? null;
  return {
    items: Array.isArray(result?.items) ? result.items : [],
    page: Number(result?.page || 1),
    pageSize: Number(result?.pageSize || result?.page_size || 30),
    totalCount: rawTotalCount == null ? null : Number(rawTotalCount),
    hasNext: Boolean(result?.hasNext ?? result?.has_next),
    nextCursor: result?.nextCursor || result?.next_cursor || null,
  };
}

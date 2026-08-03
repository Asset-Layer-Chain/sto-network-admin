import { callRpc } from './rpcClient.js';

function toIso(value) {
  if (!value) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

export async function listAdminLogs(filters = {}) {
  const result = await callRpc('rpc_admin_list_action_logs', {
    p_search: filters.search || null,
    p_action_type: filters.actionType || null,
    p_actor_user_id: filters.actorUserId || null,
    p_from_at: toIso(filters.fromAt),
    p_to_at: toIso(filters.toAt),
    p_page: Number(filters.page || 1),
    p_page_size: Number(filters.pageSize || 30),
  });
  return {
    items: Array.isArray(result?.items) ? result.items : [],
    page: Number(result?.page || 1),
    pageSize: Number(result?.pageSize || result?.page_size || 30),
    totalCount: Number(result?.totalCount || result?.total_count || 0),
  };
}

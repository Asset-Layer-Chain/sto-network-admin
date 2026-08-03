import { callRpc } from './rpcClient.js';

export async function listMembers(filters = {}) {
  const result = await callRpc('rpc_admin_list_members', {
    p_search: filters.search || null,
    p_status: filters.status || null,
    p_role: filters.role || null,
    p_signup_method: filters.signupMethod || null,
    p_reg_channel: filters.regChannel || null,
    p_is_deleted: filters.isDeleted === '' || filters.isDeleted === undefined ? null : filters.isDeleted === true || filters.isDeleted === 'true',
    p_page: Number(filters.page || 1),
    p_page_size: Number(filters.pageSize || 30),
    p_sort_column: filters.sortColumn || 'created_at',
    p_sort_direction: filters.sortDirection || 'desc',
  });
  return {
    items: Array.isArray(result?.items) ? result.items : [],
    page: Number(result?.page || 1),
    pageSize: Number(result?.pageSize || result?.page_size || 30),
    totalCount: Number(result?.totalCount || result?.total_count || 0),
    searchRequired: Boolean(result?.searchRequired || result?.search_required),
  };
}

export function getMember(userId) {
  return callRpc('rpc_admin_get_member', { p_user_id: userId });
}

export async function searchMembers(search, { limit = 30, excludeRoomId = null } = {}) {
  const result = await callRpc('rpc_admin_search_members', {
    p_search: search || null,
    p_limit: limit,
    p_exclude_room_id: excludeRoomId,
  });
  return Array.isArray(result) ? result : [];
}

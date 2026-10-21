import { callRpc } from './rpcClient.js';

export async function listNodeApplications({ search = '', status = '', fromDate = '', toDate = '', page = 1, pageSize = 30 } = {}) {
  const result = await callRpc('rpc_admin_list_node_setup_applications', {
    p_search: search.trim() || null,
    p_status: status || null,
    p_from_date: fromDate || null,
    p_to_date: toDate || null,
    p_page: page,
    p_page_size: pageSize,
  });
  return {
    items: Array.isArray(result?.items) ? result.items : [],
    page: Number(result?.page || page),
    pageSize: Number(result?.pageSize || pageSize),
    totalCount: Number(result?.totalCount || 0),
  };
}

export function getNodeApplication(applicationId) {
  return callRpc('rpc_admin_get_node_setup_application', { p_application_id: applicationId });
}

export function updateNodeApplication({ applicationId, status, answer, expectedUpdatedAt }) {
  return callRpc('rpc_admin_update_node_setup_application', {
    p_application_id: applicationId,
    p_status: status,
    p_admin_note: answer,
    p_expected_updated_at: expectedUpdatedAt,
  });
}

import React from 'react';
import { Badge } from './Common.jsx';

export const NODE_APPLICATION_STATUS = {
  pending: { label: '신청 대기', tone: 'warning' },
  contacting: { label: '연락 중', tone: 'info' },
  completed: { label: '처리 완료', tone: 'success' },
  rejected: { label: '반려', tone: 'danger' },
};

export function NodeApplicationStatus({ status }) {
  const item = NODE_APPLICATION_STATUS[status];
  return <Badge tone={item?.tone || 'neutral'}>{item?.label || status || '-'}</Badge>;
}

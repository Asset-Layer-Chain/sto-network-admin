import React, { useCallback, useEffect, useState } from 'react';
import { getNodeApplication, updateNodeApplication } from '../api/adminNodeApplicationApi.js';
import { useAuth } from '../auth/AuthContext.jsx';
import { AdminLayout } from '../components/AdminLayout.jsx';
import { Button, Card, CopyButton, EmptyState, Loading, Modal, PageHeader, Select, Textarea } from '../components/Common.jsx';
import { NodeApplicationStatus, NODE_APPLICATION_STATUS } from '../components/NodeApplicationStatus.jsx';
import { useToast } from '../components/Toast.jsx';
import { navigate, useLocation } from '../router.js';
import { formatDateTime } from '../utils/format.js';
import { formatPhoneNumberOrDash } from '../utils/phone.js';

const NEXT_STATUSES = {
  pending: ['contacting', 'completed', 'rejected'],
  contacting: ['completed', 'rejected'],
};

function DetailField({ label, value, copy = false, children }) {
  return (
    <div className="node-detail-field">
      <dt>{label}</dt>
      <dd>{children || value || '-'}{copy && value ? <CopyButton value={value} /> : null}</dd>
    </div>
  );
}

export function NodeApplicationDetailPage({ applicationId }) {
  const { admin } = useAuth();
  const { search } = useLocation();
  const { showToast } = useToast();
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [saveError, setSaveError] = useState('');
  const [nextStatus, setNextStatus] = useState('contacting');
  const [answer, setAnswer] = useState('');
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [saving, setSaving] = useState(false);

  const back = () => navigate(`/node-applications${search}`);
  const load = useCallback(async () => {
    setLoading(true);
    setError('');
    try {
      const next = await getNodeApplication(applicationId);
      setData(next);
      setNextStatus((NEXT_STATUSES[next?.application?.status] || [])[0] || '');
      setAnswer('');
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }, [applicationId]);

  useEffect(() => { load(); }, [load]);

  const item = data?.application;
  const nextOptions = NEXT_STATUSES[item?.status] || [];
  const canManage = Boolean(admin?.permissions?.nodeApplicationManage)
    && item?.memberStatus === 'active' && !item?.memberDeleted && nextOptions.length > 0;
  const validAnswer = answer.trim().length >= 2 && answer.trim().length <= 1000;

  const save = async () => {
    if (!canManage || !nextOptions.includes(nextStatus) || !validAnswer || saving) return;
    setSaving(true);
    setSaveError('');
    try {
      await updateNodeApplication({
        applicationId,
        status: nextStatus,
        answer: answer.trim(),
        expectedUpdatedAt: item.updatedAt,
      });
      setConfirmOpen(false);
      showToast('노드 신청 처리 내용을 저장했습니다.');
      await load();
    } catch (err) {
      setConfirmOpen(false);
      if (err.code === 'NODE_APPLICATION_STALE') await load();
      setSaveError(err.message);
    } finally {
      setSaving(false);
    }
  };

  return (
    <AdminLayout active="node-applications">
      <PageHeader
        title="노드 신청 상세"
        description={item ? `${item.memberName} · ${item.memberId}` : applicationId}
        actions={<Button variant="secondary" onClick={back}>목록</Button>}
      />
      {loading ? <Loading /> : null}
      {!loading && error ? <EmptyState title={error} /> : null}
      {!loading && item ? (
        <div className="detail-stack">
          <Card title="신청자 정보" actions={<Button size="sm" variant="secondary" onClick={() => navigate(`/members/${item.userId}`)}>회원 상세</Button>}>
            <dl className="node-detail-grid">
              <DetailField label="회원ID" value={item.memberId} copy />
              <DetailField label="회원명" value={item.memberName} />
              <DetailField label="전화번호" value={formatPhoneNumberOrDash(item.phone)} copy={Boolean(item.phone)} />
              <DetailField label="이메일" value={item.email} copy />
            </dl>
          </Card>
          <Card title="신청 정보">
            <dl className="node-detail-grid">
              <DetailField label="GOPAX 메모 ID" value={item.gopaxMemoId} copy />
              <DetailField label="현재 상태"><NodeApplicationStatus status={item.status} /></DetailField>
              <DetailField label="신청일시" value={formatDateTime(item.createdAt)} />
              <DetailField label="최종 수정일시" value={formatDateTime(item.updatedAt)} />
              <DetailField label="최근 관리자 답변" value={item.adminNote} />
            </dl>
          </Card>
          {canManage ? (
            <Card title="관리자 처리">
              <div className="node-response-form">
                <Select label="처리 상태" value={nextStatus} onChange={(e) => setNextStatus(e.target.value)}>
                  {nextOptions.map((status) => <option value={status} key={status}>{NODE_APPLICATION_STATUS[status]?.label || status}</option>)}
                </Select>
                <Textarea label="관리자 답변 (회원 앱에 표시)" rows={5} value={answer} maxLength={1000} onChange={(e) => setAnswer(e.target.value)} placeholder="신청자에게 전달할 답변을 입력하세요. (2~1000자)" />
                {saveError ? <p className="node-form-error" role="alert">{saveError}</p> : null}
                <div className="node-response-actions"><Button disabled={!validAnswer || !nextStatus || saving} onClick={() => setConfirmOpen(true)}>처리 확정</Button></div>
              </div>
            </Card>
          ) : null}
          {!canManage && saveError ? <p className="node-form-error" role="alert">{saveError}</p> : null}
          <Card title="관리자 처리 이력 (최근 30건)">
            {!data.history?.length ? <EmptyState title="처리 이력이 없습니다." /> : (
              <div className="table-wrap"><table>
                <thead><tr><th>처리일시</th><th>처리 관리자</th><th>이전 상태</th><th>변경 상태</th><th>관리자 답변</th></tr></thead>
                <tbody>{data.history.map((history) => (
                  <tr key={history.id}>
                    <td>{formatDateTime(history.createdAt)}</td>
                    <td>{history.actorMemberId || history.actorName || '-'}</td>
                    <td><NodeApplicationStatus status={history.beforeStatus} /></td>
                    <td><NodeApplicationStatus status={history.afterStatus} /></td>
                    <td className="node-answer-cell">{history.answer || '-'}</td>
                  </tr>
                ))}</tbody>
              </table></div>
            )}
          </Card>
        </div>
      ) : null}
      <Modal
        open={confirmOpen}
        title="노드 신청 처리 확인"
        onClose={saving ? undefined : () => setConfirmOpen(false)}
        footer={<>
          <Button variant="secondary" disabled={saving} onClick={() => setConfirmOpen(false)}>취소</Button>
          <Button disabled={saving} onClick={save}>{saving ? '저장 중' : '확인 및 저장'}</Button>
        </>}
      >
        <div className="summary-box">
          <div><span>신청자</span><strong>{item?.memberName} ({item?.memberId})</strong></div>
          <div><span>상태 변경</span><strong>{NODE_APPLICATION_STATUS[item?.status]?.label || item?.status} → {NODE_APPLICATION_STATUS[nextStatus]?.label || nextStatus}</strong></div>
        </div>
        <strong>관리자 답변</strong>
        <p className="node-confirm-answer">{answer.trim()}</p>
      </Modal>
    </AdminLayout>
  );
}

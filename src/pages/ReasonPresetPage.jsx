import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  createReasonPreset,
  deleteReasonPreset,
  listReasonPresets,
  updateReasonPreset,
} from '../api/adminReasonPresetApi.js';
import { useAuth } from '../auth/AuthContext.jsx';
import { AdminLayout } from '../components/AdminLayout.jsx';
import { Button, Card, EmptyState, Input, Loading, Modal, PageHeader, Select, StatusBadge, Textarea } from '../components/Common.jsx';
import { useToast } from '../components/Toast.jsx';
import { formatDateTime } from '../utils/format.js';

const ACTION_LABELS = {
  deposit: '지급',
  withdrawal: '차감',
  airdrop: '에어드랍',
};

const initialForm = {
  id: null,
  action: 'airdrop',
  label: '',
  reasonText: '',
  sortOrder: 0,
  isDefault: false,
  isActive: true,
};

function ReasonPresetFormModal({ open, initialValue, onClose, onSubmit, submitting }) {
  const [form, setForm] = useState(initialForm);
  const editing = Boolean(initialValue?.id);

  useEffect(() => {
    if (!open) return;
    setForm({ ...initialForm, ...(initialValue || {}) });
  }, [open, initialValue]);

  const submit = (event) => {
    event.preventDefault();
    onSubmit?.(form);
  };

  return (
    <Modal
      open={open}
      title={editing ? '처리 사유 수정' : '처리 사유 추가'}
      onClose={submitting ? undefined : onClose}
      footer={<><Button variant="secondary" onClick={onClose} disabled={submitting}>취소</Button><Button onClick={submit} disabled={submitting}>{submitting ? '저장 중' : '저장'}</Button></>}
    >
      <form className="modal-form" onSubmit={submit}>
        <Select label="처리 유형" value={form.action} onChange={(e) => setForm({ ...form, action: e.target.value })}>
          <option value="airdrop">에어드랍</option>
          <option value="withdrawal">차감</option>
          <option value="deposit">지급</option>
        </Select>
        <Input label="표시명" value={form.label} onChange={(e) => setForm({ ...form, label: e.target.value })} maxLength="80" placeholder="드롭다운에 표시될 이름" />
        <Textarea label="처리 사유 문구" rows="4" value={form.reasonText} onChange={(e) => setForm({ ...form, reasonText: e.target.value })} maxLength="300" placeholder="거래 설명과 감사 로그에 저장될 문구" />
        <Input label="정렬 순서" type="number" value={form.sortOrder} onChange={(e) => setForm({ ...form, sortOrder: e.target.value })} />
        <label className="check-field"><input type="checkbox" checked={form.isDefault} onChange={(e) => setForm({ ...form, isDefault: e.target.checked })} /> 기본값으로 사용</label>
        {editing ? <label className="check-field"><input type="checkbox" checked={form.isActive} onChange={(e) => setForm({ ...form, isActive: e.target.checked })} /> 활성 상태</label> : null}
      </form>
    </Modal>
  );
}

export function ReasonPresetPage() {
  const { admin } = useAuth();
  const canManage = Boolean(admin?.permissions?.reasonPresetManage);
  const [actionFilter, setActionFilter] = useState('');
  const [items, setItems] = useState([]);
  const [loading, setLoading] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState('');
  const [modalValue, setModalValue] = useState(null);
  const { showToast } = useToast();

  const load = useCallback(async () => {
    setLoading(true);
    setError('');
    try {
      setItems(await listReasonPresets({ action: actionFilter || null }));
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setLoading(false);
    }
  }, [actionFilter]);

  useEffect(() => { load(); }, [load]);

  const grouped = useMemo(() => items, [items]);

  const save = async (form) => {
    setSubmitting(true);
    setError('');
    try {
      if (form.id) {
        await updateReasonPreset(form);
        showToast('처리 사유를 수정했습니다.');
      } else {
        await createReasonPreset(form);
        showToast('처리 사유를 추가했습니다.');
      }
      setModalValue(null);
      await load();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setSubmitting(false);
    }
  };

  const remove = async (item) => {
    if (!window.confirm(`'${item.label}' 처리 사유를 비활성화할까요?`)) return;
    setSubmitting(true);
    setError('');
    try {
      await deleteReasonPreset(item.id);
      showToast('처리 사유를 비활성화했습니다.');
      await load();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setSubmitting(false);
    }
  };

  if (!canManage) {
    return (
      <AdminLayout active="reason-presets">
        <PageHeader title="처리 사유 관리" description="센터장 이상 관리자만 처리 사유를 추가·수정·삭제할 수 있습니다." />
        <Card><EmptyState title="권한이 없습니다." description="처리 사유 관리는 센터장 이상 등급에서 사용할 수 있습니다." /></Card>
      </AdminLayout>
    );
  }

  return (
    <AdminLayout active="reason-presets">
      <PageHeader
        title="처리 사유 관리"
        description="자산 지급·차감·에어드랍 모달에서 사용할 처리 사유 프리셋을 관리합니다. 삭제는 비활성화로 처리됩니다."
        actions={<Button onClick={() => setModalValue(initialForm)}>처리 사유 추가</Button>}
      />
      <Card>
        <div className="toolbar">
          <Select label="처리 유형" value={actionFilter} onChange={(e) => setActionFilter(e.target.value)}>
            <option value="">전체</option>
            <option value="airdrop">에어드랍</option>
            <option value="withdrawal">차감</option>
            <option value="deposit">지급</option>
          </Select>
          <div className="filter-actions"><Button variant="secondary" onClick={load}>새로고침</Button></div>
        </div>
      </Card>
      <Card className="table-card">
        {loading ? <Loading /> : null}
        {!loading && error ? <EmptyState title={error} /> : null}
        {!loading && !error && !grouped.length ? <EmptyState title="등록된 처리 사유가 없습니다." /> : null}
        {!loading && !error && grouped.length ? (
          <div className="table-wrap">
            <table>
              <thead><tr><th>처리 유형</th><th>표시명</th><th>처리 사유 문구</th><th>정렬</th><th>기본값</th><th>수정일</th><th>관리</th></tr></thead>
              <tbody>{grouped.map((item) => (
                <tr key={item.id}>
                  <td><StatusBadge value={item.action} /><small>{ACTION_LABELS[item.action] || item.action}</small></td>
                  <td><strong>{item.label}</strong></td>
                  <td>{item.reasonText}</td>
                  <td>{item.sortOrder}</td>
                  <td>{item.isDefault ? <StatusBadge value="active" /> : '-'}</td>
                  <td>{formatDateTime(item.updatedAt || item.createdAt)}</td>
                  <td><div className="row-actions"><Button size="sm" variant="secondary" onClick={() => setModalValue(item)}>수정</Button><Button size="sm" variant="danger" onClick={() => remove(item)} disabled={submitting}>삭제</Button></div></td>
                </tr>
              ))}</tbody>
            </table>
          </div>
        ) : null}
      </Card>
      <ReasonPresetFormModal
        open={Boolean(modalValue)}
        initialValue={modalValue}
        onClose={() => setModalValue(null)}
        onSubmit={save}
        submitting={submitting}
      />
    </AdminLayout>
  );
}

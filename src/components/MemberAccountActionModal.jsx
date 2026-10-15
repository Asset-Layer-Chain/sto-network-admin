import React, { useEffect, useState } from 'react';
import { useAuth } from '../auth/AuthContext.jsx';
import { reactivateMember, resetMemberPin } from '../api/adminMemberApi.js';
import { Button, Modal, Textarea } from './Common.jsx';
import { useToast } from './Toast.jsx';

const ACTIONS = {
  reactivate: {
    title: '탈퇴 회원 복구',
    submit: '회원 복구',
    processing: '복구 중',
    success: '탈퇴 회원을 복구했습니다.',
    permission: 'memberReactivate',
    api: reactivateMember,
  },
  resetPin: {
    title: '회원 PIN 초기화',
    submit: 'PIN 초기화',
    processing: '초기화 중',
    success: '회원 PIN을 000000으로 초기화했습니다.',
    permission: 'memberPinReset',
    api: resetMemberPin,
  },
};

export function MemberAccountActionModal({ open, member, action, onClose, onCompleted }) {
  const { admin } = useAuth();
  const { showToast } = useToast();
  const config = ACTIONS[action];
  const [reason, setReason] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!open) return;
    setReason('');
    setError('');
    setSubmitting(false);
  }, [open, action, member?.user_id]);

  if (!config) return null;

  const submit = async () => {
    if (submitting) return;
    if (!member?.user_id || !admin?.permissions?.[config.permission]) {
      setError('이 작업을 수행할 수 있는 권한이 없습니다.');
      return;
    }
    const cleanedReason = reason.trim();
    if (cleanedReason.length < 2 || cleanedReason.length > 500) {
      setError('처리 사유를 2~500자로 입력해주세요.');
      return;
    }
    setSubmitting(true);
    setError('');
    try {
      const result = await config.api({ userId: member.user_id, reason: cleanedReason });
      showToast(config.success);
      onClose?.();
      await onCompleted?.(result);
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal
      open={open}
      title={config.title}
      onClose={submitting ? undefined : onClose}
      footer={(
        <>
          <Button variant="secondary" onClick={onClose} disabled={submitting}>취소</Button>
          <Button variant={action === 'resetPin' ? 'danger' : 'primary'} onClick={submit} disabled={submitting}>
            {submitting ? config.processing : config.submit}
          </Button>
        </>
      )}
    >
      <div className="summary-box">
        <div><span>회원 ID</span><strong>{member?.mb_id || '-'}</strong></div>
        <div><span>회원명</span><strong>{member?.mb_name || '-'}</strong></div>
      </div>
      <Textarea
        label="처리 사유 (필수)"
        rows="3"
        maxLength={500}
        value={reason}
        onChange={(event) => setReason(event.target.value)}
        placeholder="감사 로그에 기록할 사유를 입력해주세요."
        disabled={submitting}
      />
      {error ? <p className="form-error">{error}</p> : null}
    </Modal>
  );
}

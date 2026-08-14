import React, { useEffect, useState } from 'react';
import { updateMemberName } from '../api/adminMemberApi.js';
import { Button, Input, Modal, Textarea } from './Common.jsx';
import { useToast } from './Toast.jsx';

export function MemberNameEditModal({ open, member, onClose, onCompleted }) {
  const [name, setName] = useState('');
  const [reason, setReason] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState('');
  const { showToast } = useToast();

  useEffect(() => {
    if (!open) return;
    setName(member?.mb_name || '');
    setReason('');
    setError('');
    setSubmitting(false);
  }, [open, member?.user_id, member?.mb_name]);

  const submit = async () => {
    const normalizedName = name.trim();
    const normalizedReason = reason.trim();

    if (!normalizedName) {
      setError('변경할 회원 이름을 입력해주세요.');
      return;
    }
    if (normalizedName.length > 100) {
      setError('회원 이름은 100자 이내로 입력해주세요.');
      return;
    }
    if (normalizedName === String(member?.mb_name || '').trim()) {
      setError('현재 회원 이름과 동일합니다.');
      return;
    }
    if (normalizedReason.length < 2) {
      setError('변경 사유를 2자 이상 입력해주세요.');
      return;
    }
    if (normalizedReason.length > 300) {
      setError('변경 사유는 300자 이내로 입력해주세요.');
      return;
    }

    setSubmitting(true);
    setError('');
    try {
      const result = await updateMemberName({
        userId: member.user_id,
        name: normalizedName,
        reason: normalizedReason,
      });
      showToast(`회원 이름을 ${normalizedName}(으)로 변경했습니다.`);
      await onCompleted?.(result);
      onClose?.();
    } catch (requestError) {
      setError(requestError.message);
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Modal
      open={open}
      title="회원 이름 변경"
      onClose={submitting ? undefined : onClose}
      footer={(
        <>
          <Button variant="secondary" onClick={onClose} disabled={submitting}>취소</Button>
          <Button onClick={submit} disabled={submitting}>{submitting ? '변경 중' : '이름 변경'}</Button>
        </>
      )}
    >
      <div className="summary-box">
        <div><span>회원 ID</span><strong>{member?.mb_id || '-'}</strong></div>
        <div><span>현재 이름</span><strong>{member?.mb_name || '-'}</strong></div>
      </div>
      <Input
        label="변경할 회원 이름"
        value={name}
        maxLength="100"
        onChange={(event) => setName(event.target.value)}
        autoComplete="off"
        disabled={submitting}
      />
      <Textarea
        label="변경 사유"
        rows="4"
        maxLength="300"
        value={reason}
        onChange={(event) => setReason(event.target.value)}
        placeholder="회원 이름을 변경하는 사유를 입력해주세요. 감사 로그에 기록됩니다."
        disabled={submitting}
      />
      {error ? <p className="form-error">{error}</p> : null}
    </Modal>
  );
}

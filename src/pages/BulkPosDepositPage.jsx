import React, { useMemo, useState } from 'react';
import { useAuth } from '../auth/AuthContext.jsx';
import { executeBulkPosDeposit, validateBulkPosDeposit } from '../api/adminBulkPayoutApi.js';
import { AdminLayout } from '../components/AdminLayout.jsx';
import { Badge, Button, Card, EmptyState, Input, Loading, Modal, PageHeader } from '../components/Common.jsx';
import { BULK_POS_REQUIRED_HEADERS, parseBulkPosExcel } from '../utils/bulkPosExcel.js';
import { formatNumber } from '../utils/format.js';

const STATUS_LABELS = {
  PAYABLE: '지급 가능',
  PAID: '지급 완료',
  INVALID_ROW: '행 오류',
  INVALID_AMOUNT: '금액 오류',
  NOT_FOUND: '회원/주소 불일치',
  DUPLICATED_IN_EXCEL: '엑셀 중복',
  FILE_ALREADY_COMPLETED: '이미 지급 완료된 파일',
  EXECUTION_BLOCKED: '실행 반려',
  FAILED: '실패',
};

const ERROR_LABELS = {
  INVALID_ROW: '필수값이 비어 있습니다.',
  INVALID_AMOUNT: '지급 수량을 확인해주세요.',
  NOT_FOUND: '회원명·연락처·지갑주소가 모두 일치하는 회원을 찾지 못했습니다.',
  DUPLICATED_IN_EXCEL: '엑셀 안에 동일 행이 중복되어 있습니다.',
  FILE_ALREADY_COMPLETED: '이미 지급 완료된 엑셀 파일입니다.',
  EXECUTION_BLOCKED: '검증 제외 건이 있어 실행할 수 없습니다.',
};

function statusTone(status) {
  if (status === 'PAYABLE') return 'success';
  if (status === 'PAID') return 'purple';
  if (status === 'FILE_ALREADY_COMPLETED' || status === 'DUPLICATED_IN_EXCEL') return 'warning';
  return 'danger';
}

function getItemValue(item, key) {
  return item?.[key] ?? item?.[key.replace(/[A-Z]/g, (letter) => `_${letter.toLowerCase()}`)] ?? '';
}

function ResultSummary({ result }) {
  if (!result) return null;
  const summary = result.summary || {};
  return (
    <div className="bulk-summary-grid">
      <Card><span className="summary-label">전체 행</span><strong className="summary-value">{formatNumber(summary.totalRows ?? summary.total_rows ?? 0)}</strong></Card>
      <Card><span className="summary-label">지급 가능</span><strong className="summary-value">{formatNumber(summary.payableRows ?? summary.payable_rows ?? 0)}</strong></Card>
      <Card><span className="summary-label">제외/오류</span><strong className="summary-value text-danger">{formatNumber(summary.rejectedRows ?? summary.rejected_rows ?? 0)}</strong></Card>
      <Card><span className="summary-label">총 지급 수량</span><strong className="summary-value">{formatNumber(summary.totalAmount ?? summary.total_amount ?? 0)} STOC</strong></Card>
    </div>
  );
}

function ResultTable({ items }) {
  if (!items?.length) return <EmptyState title="검증 결과가 없습니다." />;
  return (
    <div className="table-wrap bulk-table-wrap">
      <table>
        <thead>
          <tr>
            <th>행</th>
            <th>회원명</th>
            <th>연락처</th>
            <th>계약기간</th>
            <th>지갑주소</th>
            <th className="align-right">지급 수량</th>
            <th>상태</th>
            <th>사유</th>
          </tr>
        </thead>
        <tbody>
          {items.map((item, index) => {
            const status = getItemValue(item, 'status');
            const errorCode = getItemValue(item, 'errorCode');
            const walletAddress = getItemValue(item, 'walletAddress');
            return (
              <tr key={getItemValue(item, 'id') || `${getItemValue(item, 'rowNo')}-${index}`}>
                <td>{getItemValue(item, 'rowNo') || '-'}</td>
                <td>{getItemValue(item, 'memberName') || '-'}</td>
                <td>{getItemValue(item, 'phone') || getItemValue(item, 'normalizedPhone') || '-'}</td>
                <td>{getItemValue(item, 'contractPeriod') || '-'}</td>
                <td><code className="bulk-wallet-address">{walletAddress || '-'}</code></td>
                <td className="align-right">{formatNumber(getItemValue(item, 'amount'))}</td>
                <td><Badge tone={statusTone(status)}>{STATUS_LABELS[status] || status || '-'}</Badge></td>
                <td>{ERROR_LABELS[errorCode] || errorCode || '-'}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

export function BulkPosDepositPage() {
  const { admin } = useAuth();
  const [selectedFileName, setSelectedFileName] = useState('');
  const [parsed, setParsed] = useState(null);
  const [result, setResult] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const [confirmStep, setConfirmStep] = useState(null);
  const [confirmText, setConfirmText] = useState('');
  const [executedResult, setExecutedResult] = useState(null);

  const canManage = Boolean(admin?.permissions?.bulkDepositManage);
  const canExecute = canManage && Boolean(result?.canExecute) && !executedResult;
  const expectedConfirmText = result?.confirmText || '';
  const uploadDescription = useMemo(() => `필수 컬럼: ${BULK_POS_REQUIRED_HEADERS.join(', ')}`, []);

  const handleFileChange = async (event) => {
    const file = event.target.files?.[0];
    event.target.value = '';
    setError('');
    setResult(null);
    setExecutedResult(null);
    setParsed(null);
    setSelectedFileName(file?.name || '');
    if (!file) return;
    if (!canManage) {
      setError('본부급 관리자만 POS 일괄 지급을 사용할 수 있습니다.');
      return;
    }

    setLoading(true);
    try {
      const nextParsed = await parseBulkPosExcel(file);
      setParsed(nextParsed);
      const validation = await validateBulkPosDeposit(nextParsed);
      setResult(validation);
    } catch (requestError) {
      setError(requestError.message || '엑셀 검증에 실패했습니다.');
    } finally {
      setLoading(false);
    }
  };

  const openFirstConfirm = () => {
    if (!canExecute) return;
    setConfirmText('');
    setConfirmStep('first');
  };

  const execute = async () => {
    if (!result?.batch?.id || confirmText !== expectedConfirmText) return;
    setLoading(true);
    setError('');
    try {
      const executed = await executeBulkPosDeposit({ batchId: result.batch.id, confirmText });
      setExecutedResult(executed);
      setResult((prev) => ({ ...prev, ...executed, canExecute: false }));
      setConfirmStep(null);
    } catch (requestError) {
      setError(requestError.message || '일괄 지급 실행에 실패했습니다.');
    } finally {
      setLoading(false);
    }
  };

  return (
    <AdminLayout active="bulk-pos-deposit">
      <PageHeader
        title="POS 일괄 지급"
        description="엑셀의 회원명·연락처·지갑주소가 모두 일치하는 회원에게 STOC_INT를 일괄 지급합니다."
      />

      {!canManage ? (
        <div className="notice notice-danger">본부급 관리자만 POS 일괄 지급을 사용할 수 있습니다.</div>
      ) : null}
      {error ? <div className="notice notice-danger">{error}</div> : null}
      {executedResult ? <div className="notice notice-warning">일괄 지급이 완료되었습니다. 같은 엑셀 파일은 다시 사용할 수 없습니다.</div> : null}

      <Card title="엑셀 업로드">
        <div className="bulk-upload-box">
          <div>
            <strong>지급 대상 엑셀 파일</strong>
            <p>{uploadDescription}</p>
            <small>검증 제외 건이 1건이라도 있으면 전체 지급이 반려됩니다. 이미 지급 완료된 동일 엑셀 파일도 재사용할 수 없습니다.</small>
          </div>
          <label className="button button-primary button-md file-upload-button">
            엑셀 선택
            <input type="file" accept=".xlsx" disabled={!canManage || loading} onChange={handleFileChange} />
          </label>
        </div>
        {selectedFileName ? <p className="field-help">선택 파일: {selectedFileName}</p> : null}
        {parsed ? <p className="field-help">파일 해시: <code>{parsed.fileHash}</code></p> : null}
      </Card>

      {loading ? <Loading label="처리 중입니다." /> : null}

      {result ? (
        <>
          <ResultSummary result={result} />
          <Card
            title={`검증 결과 (${result.items.length.toLocaleString('ko-KR')}건)`}
            actions={(
              <Button variant="primary" disabled={!canExecute || loading} onClick={openFirstConfirm}>
                일괄 지급
              </Button>
            )}
            className="table-card"
          >
            {!result.canExecute && !executedResult ? (
              <div className="notice notice-danger bulk-result-notice">
                제외/오류 건이 있거나 이미 지급 완료된 파일이므로 일괄 지급할 수 없습니다.
              </div>
            ) : null}
            <ResultTable items={result.items} />
          </Card>
        </>
      ) : null}

      <Modal
        open={confirmStep === 'first'}
        title="일괄 지급 1차 확인"
        onClose={() => setConfirmStep(null)}
        footer={(
          <>
            <Button variant="secondary" onClick={() => setConfirmStep(null)}>취소</Button>
            <Button variant="danger" onClick={() => setConfirmStep('second')}>계속</Button>
          </>
        )}
      >
        <p className="modal-description">
          총 {formatNumber(result?.summary?.payableRows ?? 0)}건, 총 {formatNumber(result?.summary?.totalAmount ?? 0)} STOC_INT를 지급합니다.
          검증 제외 건이 있으면 실행할 수 없으며, 실행 완료 후 같은 엑셀 파일은 다시 사용할 수 없습니다.
        </p>
        <div className="summary-box">
          <div><span>파일명</span><strong>{parsed?.fileName || result?.batch?.fileName || '-'}</strong></div>
          <div><span>지급 가능 건수</span><strong>{formatNumber(result?.summary?.payableRows ?? 0)}건</strong></div>
          <div><span>총 지급 수량</span><strong>{formatNumber(result?.summary?.totalAmount ?? 0)} STOC</strong></div>
        </div>
      </Modal>

      <Modal
        open={confirmStep === 'second'}
        title="일괄 지급 최종 확인"
        onClose={() => setConfirmStep(null)}
        footer={(
          <>
            <Button variant="secondary" onClick={() => setConfirmStep(null)}>취소</Button>
            <Button variant="danger" disabled={confirmText !== expectedConfirmText || loading} onClick={execute}>최종 지급 실행</Button>
          </>
        )}
      >
        <p className="modal-description">
          이 작업은 각 회원의 STOC_INT 잔액을 증가시키고 거래 내역에 Deposit 기록을 생성합니다.
          아래 확인 문구를 정확히 입력해야 실행됩니다.
        </p>
        <div className="summary-box">
          <div><span>확인 문구</span><strong>{expectedConfirmText || '-'}</strong></div>
        </div>
        <Input label="확인 문구 입력" value={confirmText} onChange={(event) => setConfirmText(event.target.value)} placeholder={expectedConfirmText} />
      </Modal>
    </AdminLayout>
  );
}

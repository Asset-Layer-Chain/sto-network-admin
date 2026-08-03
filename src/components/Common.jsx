import React, { useEffect } from 'react';

export function Button({ children, variant = 'primary', size = 'md', className = '', ...props }) {
  return <button className={`button button-${variant} button-${size} ${className}`.trim()} {...props}>{children}</button>;
}

export function Input({ label, error, className = '', ...props }) {
  return (
    <label className={`field ${className}`.trim()}>
      {label ? <span className="field-label">{label}</span> : null}
      <input className={`input ${error ? 'input-error' : ''}`} {...props} />
      {error ? <span className="field-error">{error}</span> : null}
    </label>
  );
}

export function Select({ label, children, className = '', ...props }) {
  return (
    <label className={`field ${className}`.trim()}>
      {label ? <span className="field-label">{label}</span> : null}
      <select className="select" {...props}>{children}</select>
    </label>
  );
}

export function Textarea({ label, error, className = '', ...props }) {
  return (
    <label className={`field ${className}`.trim()}>
      {label ? <span className="field-label">{label}</span> : null}
      <textarea className={`textarea ${error ? 'input-error' : ''}`} {...props} />
      {error ? <span className="field-error">{error}</span> : null}
    </label>
  );
}

export function Badge({ children, tone = 'neutral' }) {
  return <span className={`badge badge-${tone}`}>{children}</span>;
}

export function StatusBadge({ value }) {
  const key = String(value || '');
  const tone = {
    active: 'success', completed: 'success', admin: 'info', super_admin: 'purple',
    pending: 'warning', processing: 'info', suspended: 'danger', deleted: 'danger',
    failed: 'danger', cancelled: 'neutral', user: 'neutral',
    deposit: 'success', airdrop: 'purple', withdrawal: 'danger',
    team_lead: 'info', center_director: 'purple', headquarters: 'success',
  }[key] || 'neutral';
  const label = {
    team_lead: '팀장급',
    center_director: '센터장',
    headquarters: '본부',
  }[key] || value || '-';
  return <Badge tone={tone}>{label}</Badge>;
}

export function Loading({ label = '불러오는 중입니다.' }) {
  return <div className="loading"><span className="spinner" />{label}</div>;
}

export function EmptyState({ title = '데이터가 없습니다.', description }) {
  return <div className="empty-state"><strong>{title}</strong>{description ? <p>{description}</p> : null}</div>;
}

export function PageHeader({ title, description, actions }) {
  return (
    <header className="page-header">
      <div><h1>{title}</h1>{description ? <p>{description}</p> : null}</div>
      {actions ? <div className="page-actions">{actions}</div> : null}
    </header>
  );
}

export function Card({ title, actions, children, className = '' }) {
  return (
    <section className={`card ${className}`.trim()}>
      {(title || actions) ? <div className="card-header"><h2>{title}</h2><div>{actions}</div></div> : null}
      <div className="card-body">{children}</div>
    </section>
  );
}

export function Modal({ open, title, children, footer, onClose, width = '560px' }) {
  useEffect(() => {
    if (!open) return undefined;
    const handler = (event) => event.key === 'Escape' && onClose?.();
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [open, onClose]);

  if (!open) return null;
  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={(e) => e.target === e.currentTarget && onClose?.()}>
      <div className="modal" style={{ maxWidth: width }} role="dialog" aria-modal="true">
        <div className="modal-header"><h2>{title}</h2><button className="icon-button" onClick={onClose} aria-label="닫기">×</button></div>
        <div className="modal-body">{children}</div>
        {footer ? <div className="modal-footer">{footer}</div> : null}
      </div>
    </div>
  );
}

export function Pagination({ page, pageSize, totalCount, onChange }) {
  const totalPages = Math.max(1, Math.ceil(Number(totalCount || 0) / Number(pageSize || 1)));
  return (
    <div className="pagination">
      <span>총 {Number(totalCount || 0).toLocaleString('ko-KR')}건</span>
      <div>
        <Button variant="secondary" size="sm" disabled={page <= 1} onClick={() => onChange(page - 1)}>이전</Button>
        <span className="page-number">{page} / {totalPages}</span>
        <Button variant="secondary" size="sm" disabled={page >= totalPages} onClick={() => onChange(page + 1)}>다음</Button>
      </div>
    </div>
  );
}

export function CopyButton({ value }) {
  const copy = async () => {
    if (!value) return;
    await navigator.clipboard.writeText(String(value));
  };
  return <button className="copy-button" onClick={copy} title="복사">복사</button>;
}

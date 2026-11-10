import { corsHeaders, parseBody, response, rest, verifyUser } from './_shared.mjs';

const ORDER = [
  'companies','profiles','company_memberships','module_assignments','finance_categories',
  'cash_accounts','import_batches','schedules','bank_transactions','financial_products',
  'monthly_plans','asset_positions','reports','report_versions','approval_steps'
];

export async function handler(event) {
  const cors = corsHeaders(event);
  if (event.httpMethod === 'OPTIONS') return { statusCode: 204, headers: cors, body: '' };
  try {
    await verifyUser(event, { roles: ['admin'] });
    if ((event.headers?.['x-confirm-restore'] || event.headers?.['X-Confirm-Restore']) !== 'RESTORE') {
      return response(400, { error: '복원 확인 헤더 X-Confirm-Restore: RESTORE가 필요합니다.' }, cors);
    }
    const backup = parseBody(event);
    if (backup.format !== 'changjin-finance-backup-v1' || !backup.data) {
      return response(400, { error: '지원하지 않는 백업 형식입니다.' }, cors);
    }
    const result = {};
    const deferredScheduleLinks = [];
    const deferredTransactionLinks = [];

    for (const table of ORDER) {
      const rows = backup.data[table];
      if (!Array.isArray(rows) || rows.length === 0) { result[table] = 0; continue; }
      const cleaned = rows.map(row => {
        const copy = { ...row };
        delete copy.changed_at;
        // schedules ↔ bank_transactions are mutually linked. Restore both tables first,
        // then reconnect the foreign keys to avoid circular FK failures.
        if (table === 'schedules' && copy.matched_transaction_id) {
          deferredScheduleLinks.push({ id: copy.id, matched_transaction_id: copy.matched_transaction_id });
          copy.matched_transaction_id = null;
        }
        if (table === 'bank_transactions' && copy.matched_schedule_id) {
          deferredTransactionLinks.push({ id: copy.id, matched_schedule_id: copy.matched_schedule_id });
          copy.matched_schedule_id = null;
        }
        return copy;
      });
      await rest(table, {
        method: 'POST',
        body: cleaned,
        prefer: 'resolution=merge-duplicates,return=minimal',
      });
      result[table] = cleaned.length;
    }

    for (const link of deferredScheduleLinks) {
      await rest('schedules', {
        method: 'PATCH', body: { matched_transaction_id: link.matched_transaction_id },
        query: `?id=eq.${encodeURIComponent(link.id)}`, prefer: 'return=minimal',
      });
    }
    for (const link of deferredTransactionLinks) {
      await rest('bank_transactions', {
        method: 'PATCH', body: { matched_schedule_id: link.matched_schedule_id },
        query: `?id=eq.${encodeURIComponent(link.id)}`, prefer: 'return=minimal',
      });
    }

    return response(200, {
      ok: true,
      restored: result,
      relinked: { schedules: deferredScheduleLinks.length, transactions: deferredTransactionLinks.length },
      note: '감사로그는 원본 이력 보존을 위해 복원 대상에서 제외됩니다. 복원 작업 자체는 신규 감사이력으로 관리하십시오.'
    }, cors);
  } catch (error) {
    return response(error.statusCode || 500, { error: error.message }, cors);
  }
}

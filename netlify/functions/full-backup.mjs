import { corsHeaders, response, rest, verifyUser } from './_shared.mjs';

const TABLES = [
  'companies','profiles','company_memberships','module_assignments','finance_categories',
  'cash_accounts','import_batches','bank_transactions','schedules','financial_products',
  'monthly_plans','asset_positions','reports','report_versions','approval_steps','audit_logs'
];

export async function handler(event) {
  const cors = corsHeaders(event);
  if (event.httpMethod === 'OPTIONS') return { statusCode: 204, headers: cors, body: '' };
  try {
    const { profile } = await verifyUser(event, { roles: ['admin','finance_manager'] });
    const data = {};
    for (const table of TABLES) {
      data[table] = await rest(table, { query: '?select=*' });
    }
    return response(200, {
      format: 'changjin-finance-backup-v1',
      exported_at: new Date().toISOString(),
      exported_by: { id: profile.id, email: profile.email, name: profile.full_name, role: profile.role },
      data,
      note: 'Supabase Storage 원본 파일은 storage_path 메타데이터만 포함됩니다. 원본 파일은 Supabase Storage 정책에 따라 별도 보관됩니다.'
    }, { ...cors, 'content-disposition': `attachment; filename="changjin-finance-backup-${new Date().toISOString().slice(0,10)}.json"` });
  } catch (error) {
    return response(error.statusCode || 500, { error: error.message }, cors);
  }
}

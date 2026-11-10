import { corsHeaders, env, parseBody, response, rest, serviceHeaders, verifyUser } from './_shared.mjs';

async function authAdmin(path, { method = 'GET', body } = {}) {
  const { supabaseUrl, serviceKey } = env();
  if (!serviceKey) throw new Error('SUPABASE_SERVICE_ROLE_KEY is required.');
  const res = await fetch(`${supabaseUrl}/auth/v1/admin/${path}`, {
    method,
    headers: serviceHeaders(serviceKey),
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let data;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  if (!res.ok) {
    const msg = data?.msg || data?.message || data?.error_description || text || 'Supabase Auth admin error';
    throw Object.assign(new Error(msg), { statusCode: res.status });
  }
  return data;
}

async function listUsers() {
  const auth = await authAdmin('users?page=1&per_page=1000');
  const profiles = await rest('profiles', { query: '?select=*' });
  const memberships = await rest('company_memberships', { query: '?select=*,companies(id,name,code)' });
  const assignments = await rest('module_assignments', { query: '?select=*' });
  const profileMap = new Map(profiles.map(p => [p.id, p]));
  return (auth.users || []).map(u => ({
    id: u.id,
    email: u.email,
    last_sign_in_at: u.last_sign_in_at,
    created_at: u.created_at,
    confirmed_at: u.confirmed_at,
    ...profileMap.get(u.id),
    memberships: memberships.filter(m => m.user_id === u.id),
    module_assignments: assignments.filter(a => a.user_id === u.id),
  }));
}

async function replaceMemberships(userId, memberships = []) {
  await rest('company_memberships', { method: 'DELETE', query: `?user_id=eq.${encodeURIComponent(userId)}` });
  if (memberships.length) {
    await rest('company_memberships', {
      method: 'POST',
      body: memberships.map(m => ({ user_id: userId, company_id: m.company_id, access_level: m.access_level || 'read' })),
      prefer: 'resolution=merge-duplicates,return=representation',
    });
  }
}

async function replaceAssignments(userId, assignments = []) {
  await rest('module_assignments', { method: 'DELETE', query: `?user_id=eq.${encodeURIComponent(userId)}` });
  if (assignments.length) {
    await rest('module_assignments', {
      method: 'POST',
      body: assignments.map(a => ({
        user_id: userId,
        company_id: a.company_id || null,
        module_code: a.module_code,
        can_view: a.can_view !== false,
        can_create: !!a.can_create,
        can_update: !!a.can_update,
        can_delete: !!a.can_delete,
        can_approve: !!a.can_approve,
      })),
      prefer: 'resolution=merge-duplicates,return=representation',
    });
  }
}

export async function handler(event) {
  const cors = corsHeaders(event);
  if (event.httpMethod === 'OPTIONS') return { statusCode: 204, headers: cors, body: '' };
  try {
    await verifyUser(event, { roles: ['admin'] });
    const body = parseBody(event);
    const action = body.action || (event.httpMethod === 'GET' ? 'list' : '');

    if (action === 'list') return response(200, { users: await listUsers() }, cors);

    if (action === 'create') {
      if (!body.email || !body.password || !body.full_name) {
        return response(400, { error: '이메일, 임시비밀번호, 성명은 필수입니다.' }, cors);
      }
      const created = await authAdmin('users', {
        method: 'POST',
        body: {
          email: body.email,
          password: body.password,
          email_confirm: true,
          user_metadata: { full_name: body.full_name },
        },
      });
      const userId = created.user?.id || created.id;
      await rest('profiles', {
        method: 'POST',
        body: {
          id: userId,
          email: body.email,
          full_name: body.full_name,
          department: body.department || null,
          job_title: body.job_title || null,
          role: body.role || 'business_user',
          active: body.active !== false,
          default_company_id: body.default_company_id || null,
        },
        prefer: 'resolution=merge-duplicates,return=representation',
      });
      await replaceMemberships(userId, body.memberships || []);
      await replaceAssignments(userId, body.module_assignments || []);
      return response(201, { ok: true, user_id: userId }, cors);
    }

    if (action === 'update') {
      if (!body.user_id) return response(400, { error: 'user_id가 필요합니다.' }, cors);
      const patch = {};
      for (const key of ['email','full_name','department','job_title','role','active','default_company_id']) {
        if (Object.prototype.hasOwnProperty.call(body, key)) patch[key] = body[key];
      }
      if (Object.keys(patch).length) {
        await rest('profiles', {
          method: 'PATCH',
          body: patch,
          query: `?id=eq.${encodeURIComponent(body.user_id)}`,
          prefer: 'return=representation',
        });
      }
      if (body.email || body.password || body.ban_duration || Object.prototype.hasOwnProperty.call(body, 'active')) {
        await authAdmin(`users/${body.user_id}`, {
          method: 'PUT',
          body: {
            ...(body.email ? { email: body.email } : {}),
            ...(body.password ? { password: body.password } : {}),
            ...(body.ban_duration ? { ban_duration: body.ban_duration } : {}),
            ...(Object.prototype.hasOwnProperty.call(body, 'active') ? { ban_duration: body.active ? 'none' : '876000h' } : {}),
          },
        });
      }
      if (Array.isArray(body.memberships)) await replaceMemberships(body.user_id, body.memberships);
      if (Array.isArray(body.module_assignments)) await replaceAssignments(body.user_id, body.module_assignments);
      return response(200, { ok: true }, cors);
    }

    if (action === 'deactivate') {
      if (!body.user_id) return response(400, { error: 'user_id가 필요합니다.' }, cors);
      await rest('profiles', {
        method: 'PATCH', body: { active: false },
        query: `?id=eq.${encodeURIComponent(body.user_id)}`, prefer: 'return=representation',
      });
      await authAdmin(`users/${body.user_id}`, { method: 'PUT', body: { ban_duration: '876000h' } });
      return response(200, { ok: true }, cors);
    }

    if (action === 'delete') {
      return response(409, { error: '감사·결재 이력 보존을 위해 사용자 삭제는 제공하지 않습니다. 비활성화를 사용하세요.' }, cors);
    }

    return response(400, { error: '지원하지 않는 action입니다.' }, cors);
  } catch (error) {
    return response(error.statusCode || 500, { error: error.message }, cors);
  }
}

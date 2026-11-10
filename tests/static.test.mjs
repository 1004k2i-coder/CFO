import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile, access } from 'node:fs/promises';

const root=new URL('../',import.meta.url);
const text=async p=>readFile(new URL(p,root),'utf8');

test('HTML이 필수 정적 자원을 참조한다',async()=>{
  const html=await text('public/index.html');
  assert.match(html,/assets\/app\.css/);
  assert.match(html,/assets\/js\/app\.js/);
  await access(new URL('public/assets/app.css',root));
  await access(new URL('public/assets/js/app.js',root));
});

test('Netlify Functions와 Supabase 마이그레이션이 존재한다',async()=>{
  for(const p of ['public/config.js','netlify/functions/exchange-rates.mjs','supabase/INSTALL_ALL.sql']) await access(new URL(p,root));
});

test('운영 모드는 localStorage가 아닌 Supabase를 사용하고 데모만 localStorage를 사용한다',async()=>{
  const runtime=await text('public/assets/js/runtime.js');
  const api=await text('public/assets/js/api.js');
  assert.match(runtime,/createClient/);
  assert.match(api,/DEMO_KEY/);
  assert.match(api,/if\(this\.demo\)/);
});

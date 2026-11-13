import test from 'node:test';
import assert from 'node:assert/strict';
import { validateConfig,callFunction } from '../public/assets/js/runtime.js';
const url='https://test-project.supabase.co';
test('공개용 키만 허용하며 비밀키·미설정을 차단한다',()=>{
 assert.equal(validateConfig({supabaseUrl:url,supabaseAnonKey:'sb_publishable_test'}).supabaseUrl,url);
 for(const key of ['YOUR_PUBLISHABLE_KEY','sb_secret_abc',''])assert.throws(()=>validateConfig({supabaseUrl:url,supabaseAnonKey:key}));
 const jwt=role=>'e30.'+btoa(JSON.stringify({role}))+'.sig';
 assert.doesNotThrow(()=>validateConfig({supabaseUrl:url,supabaseAnonKey:jwt('anon')}));
 assert.throws(()=>validateConfig({supabaseUrl:url,supabaseAnonKey:jwt('service_role')}));
 assert.throws(()=>validateConfig({supabaseUrl:'https://YOUR_PROJECT.supabase.co',supabaseAnonKey:'sb_publishable_test'}));
});
test('관리 요청은 로그인 기기의 Supabase RPC로 전달된다',async()=>{
 const calls=[];const runtime={client:{rpc:async(...a)=>{calls.push(a);return {data:{ok:true}}}}};
 await callFunction(runtime,'admin-users',{body:{action:'list'}});
 await callFunction(runtime,'full-backup');
 await callFunction(runtime,'restore-backup',{body:{format:'test'}});
 assert.deepEqual(calls,[['admin_users',{p_payload:{action:'list'}}],['export_finance_backup',{}],['restore_finance_backup',{p_backup:{format:'test'}}]]);
 await assert.rejects(()=>callFunction({client:{rpc:async()=>({error:new Error('접근 차단')})}},'full-backup'),/접근 차단/);
});

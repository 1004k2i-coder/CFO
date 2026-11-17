import test from 'node:test';
import assert from 'node:assert/strict';
import {FinanceAPI} from '../public/assets/js/api.js';
test('수동 잔액에는 과거 연결 증감을 다시 합산하지 않는다',async()=>{
 const api=Object.create(FinanceAPI.prototype);
 const rows=[{id:'manual',current_value:1000,manual_balance:true},{id:'legacy',current_value:1000,manual_balance:false}];
 const q={select:()=>q,eq:()=>q,order:()=>q,then:fn=>Promise.resolve({data:rows}).then(fn)};
 api.client={from:()=>q,rpc:async()=>({data:[{product_id:'manual',adjustment:200},{product_id:'legacy',adjustment:200}]})};
 const result=await api.listProducts('all');assert.equal(result[0].current_value,1000);assert.equal(result[0].transfer_adjustment,0);assert.equal(result[1].current_value,1200);
});

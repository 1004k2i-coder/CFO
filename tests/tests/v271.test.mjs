import test from 'node:test';
import assert from 'node:assert/strict';
import {importExtension} from '../public/assets/js/import-filename.js';
import {parseFinanceFile} from '../public/assets/js/excel.js';
test('복사 번호 위치와 대소문자에 관계없이 지원 형식 판별',()=>{
 for(const name of ['202601_03sb.xlsx','202601_03sb(2).xlsx','202601_03sb.xlsx(2)','202601_03sb.XLSX (3)','자료.xlsx(2)(3)'])assert.equal(importExtension(name),'xlsx');
 assert.equal(importExtension('자료.xls(2)'),'xls');
 assert.equal(importExtension('자료.csv(2)'),'csv');
 assert.equal(importExtension('자료.json(2)'),'json');
 for(const name of ['자료.sb(2)','자료.xlsx.exe','자료.xlsx(abc)',''])assert.equal(importExtension(name),'');
});
test('지원하지 않는 파일은 내용 판독 전에 안내',async()=>{
 await assert.rejects(parseFinanceFile({name:'자료.exe'}),/엑셀/);
});

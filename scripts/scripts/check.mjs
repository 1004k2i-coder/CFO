import { readdir } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import path from 'node:path';

const roots=['public/assets/js','netlify/functions','tests','scripts'];
const files=[];
async function walk(dir){
  for(const e of await readdir(dir,{withFileTypes:true})){
    const p=path.join(dir,e.name);
    if(e.isDirectory())await walk(p);
    else if(/\.(m?js)$/.test(e.name))files.push(p);
  }
}
for(const r of roots)await walk(r);
let failed=false;
for(const f of files){const x=spawnSync(process.execPath,['--check',f],{stdio:'inherit'});if(x.status!==0)failed=true;}
if(failed)process.exit(1);
console.log(`syntax check passed: ${files.length} files`);

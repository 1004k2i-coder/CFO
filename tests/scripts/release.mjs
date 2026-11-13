import fs from 'node:fs';import path from 'node:path';import os from 'node:os';import {createHash} from 'node:crypto';import {execFileSync} from 'node:child_process';import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');const pkg=JSON.parse(fs.readFileSync(path.join(root,'package.json')));const version=pkg.version;const history=JSON.parse(fs.readFileSync(path.join(root,'RELEASE_HISTORY.json')));if(history[0]?.version!==version)throw Error('배포 이력의 최신 버전과 package.json이 다릅니다.');
const hash=file=>createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const config=path.join(root,'public/config.js'),before=fs.existsSync(config)?hash(config):null;
fs.writeFileSync(path.join(root,'public/assets/js/version.js'),`// 배포 스크립트가 package.json의 버전으로 생성합니다.\nexport const APP_VERSION='${version}';\n`);
execFileSync(process.platform==='win32'?'npm.cmd':'npm',['run','ci'],{cwd:root,stdio:'inherit'});
const output=path.resolve(process.argv[2]||path.join(root,'dist'));fs.mkdirSync(output,{recursive:true});
const staging=fs.mkdtempSync(path.join(os.tmpdir(),'finance-release-'));const target=path.join(staging,'changjin-finance-app');
const excluded=new Set(['config.js','.git','node_modules','dist','.netlify']);
fs.cpSync(root,target,{recursive:true,filter:source=>!excluded.has(path.basename(source))&&!path.basename(source).startsWith('.env')&&!path.resolve(source).startsWith(output+path.sep)&&path.resolve(source)!==output});
const files=[];function walk(dir){for(const e of fs.readdirSync(dir,{withFileTypes:true})){const file=path.join(dir,e.name);if(e.isDirectory())walk(file);else files.push({path:path.relative(target,file).replaceAll(path.sep,'/'),sha256:hash(file)});}}walk(target);
if(files.some(f=>path.basename(f.path)==='config.js'))throw Error('연결 설정 파일이 업데이트에 포함되었습니다.');
fs.writeFileSync(path.join(target,'RELEASE_MANIFEST.json'),JSON.stringify({version,previous_version:history[1]?.version||null,package_type:'update',config_included:false,sql_required:history[0].sql_required,files},null,2));
const stamp=new Intl.DateTimeFormat('sv-SE',{timeZone:'Asia/Seoul',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false}).format(new Date()).replace(/[^0-9]/g,'').slice(2);
const archive=path.join(output,`${stamp}_finance_update_v${version.replaceAll('.','')}.zip`);
if(fs.existsSync(archive))throw Error('같은 이름의 배포 파일이 이미 있습니다. 덮어쓰지 않습니다.');
try{execFileSync('zip',['-qr',archive,'changjin-finance-app'],{cwd:staging});const names=execFileSync('unzip',['-Z1',archive],{encoding:'utf8'}).split('\n');if(names.some(n=>n.endsWith('/config.js')))throw Error('압축파일에 config.js가 있습니다.');if(before!==null&&hash(config)!==before)throw Error('기존 config.js가 변경되었습니다.');console.log('업데이트 생성 완료: '+archive);}finally{fs.rmSync(staging,{recursive:true,force:true});}

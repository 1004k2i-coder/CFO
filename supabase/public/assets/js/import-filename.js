// 다운로드 과정에서 확장자 뒤에 붙은 복사 번호를 제거하여 형식을 판별합니다.
export function importExtension(name){
  const normalized=String(name||'').trim().replace(/(?:\s*\(\d+\))+$/,'').trim();
  return normalized.match(/\.(xlsx|xls|csv|json)$/i)?.[1].toLowerCase()||'';
}

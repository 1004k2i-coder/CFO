# 창진에스씨 재무관리 버전 2.0

프로젝트 URL과 공개 API 키만 `public/config.js`에 입력하는 Supabase + Netlify 프로그램입니다.

## 설치 순서

1. 동봉한 설치 설명서 PDF를 먼저 읽습니다.
2. 기존 소스를 보관하고 새 소스로 교체합니다. 옛 Netlify 관리자 함수는 삭제합니다.
3. Supabase Authentication에서 관리자 이메일 계정을 먼저 생성합니다.
4. `supabase/INSTALL_ALL.sql` 위쪽 이메일 한 곳을 바꾸고 전체 파일을 한 번 실행합니다.
5. `public/config.js`의 URL과 Publishable key 또는 anon key를 입력합니다. 비밀키는 넣지 않습니다.
6. GitHub Desktop에서 Commit과 Push를 하고 Netlify 성공 배포를 확인합니다.
7. 관리자 로그인 후 기기 등록을 신청합니다.
8. 최초 기기만 Supabase Table Editor의 `registered_devices`에서 id와 user_id를 대조하고 status를 approved로 저장합니다.
9. 이후 직원 계정은 Authentication에서 생성하고, 프로그램에서 역할·법인 권한·기기 승인을 설정합니다.

## 기존 배포에서 제거할 파일

- `netlify/functions/_shared.mjs`
- `netlify/functions/admin-users.mjs`
- `netlify/functions/full-backup.mjs`
- `netlify/functions/restore-backup.mjs`
- `netlify/functions/runtime-config.mjs`
- `supabase/migrations/`, `supabase/seed.sql`, `supabase/bootstrap_admin.sql.example`
- `.env.example`

단순 덮어쓰기만 하면 옛 파일이 남습니다. `.git` 폴더는 유지하고 위 파일의 삭제도 GitHub에 반영하세요.

## 중요한 운영 범위

- 등록 기기는 계정·사이트 주소·브라우저 프로필 기준입니다. 물리적 PC 고정 인증이 아닙니다.
- 로그인 화면은 공개됩니다. 재무자료 접근은 로그인·활성 계정·승인 기기·법인 권한을 확인합니다.
- URL과 API 키는 공개 정보입니다. 비밀번호나 기기 인증값을 코드에 넣지 않습니다.
- 기기 인증값과 로그인 세션은 브라우저에 저장됩니다. 저장정보가 함께 복제되는 위험을 완전히 방지하는 방식은 아닙니다.
- 신규 계정과 비밀번호는 Supabase Authentication에서 관리합니다. 프로그램은 업무 권한을 관리합니다.
- 업무 백업은 Auth 계정·Storage 원본 파일·기기 인증을 포함하지 않습니다.
- 전체 업무 백업·복원은 관리자만 수행합니다. 복원은 동일 ID 병합 방식이며 백업에 없는 행을 삭제하지 않습니다.
- 모든 은행 양식을 자동 인식하는 버전은 아닙니다. 기존 은행 헤더 형식이 필요합니다.
- 기존 자료가 있는 타 프로그램 DB로의 자동 마이그레이션은 제공하지 않습니다.
- 실행 SQL 전체와 상세 순서는 설치 설명서의 마지막 페이지와 `INSTALL_ALL.sql`을 참조하세요.

## 개발 검증

Node.js 20 이상에서 `npm install`, `npm run ci`, `npm run test:db`를 실행합니다.
DB 시험은 임시 PGlite PostgreSQL 환경에서 실행되며 실제 Supabase에 접속하지 않습니다.
실제 서비스 배포·메일 수신·Storage API·CDN·환율·실제 은행파일은 회사 환경에서 인수시험이 필요합니다.

## Netlify 설정

루트의 netlify.toml을 사용합니다. 배포 폴더는 `public`, 함수 폴더는 `netlify/functions`입니다.
별도 Supabase 환경변수나 service_role 키 없이 운영합니다.
공개 환율 조회 함수만 Netlify에 남겨 두었습니다.

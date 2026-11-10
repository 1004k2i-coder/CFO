# ㈜창진에스씨 통합 재무관리 웹앱

현업 담당자별 입력, 재무팀 수합·검토, 결재자 선택과 순차 승인·반려, 대표·임원 대시보드, 수정 이력, Excel 입출력, 전체 백업을 하나로 통합한 반응형 웹앱입니다.

## 1. 구현 범위

- **현업 담당자:** 본인 담당 거래·입금·지급 예정 등록 및 수정
- **재무 담당자:** 은행 파일 업로드, 거래 분류, 예정과 실적 연결, 계좌·대출·예금·외화환율 관리
- **재무 관리자:** 법인별 자료 수합, 보고서 스냅샷 작성, 결재선 지정, 승인 보고서 보관
- **결재자:** 순차 승인·반려 및 의견 기록
- **대표·임원:** 현재 가용자금, 30일 최저잔고, 부족액, 즉시 유동화금액, 외화 원화환산, 결재 대기, 법인별 현황 조회
- **관리자:** 사용자 등록, 역할·법인권한·결재자 지정, 분류 키워드, 백업·복원
- **감사:** 수정·삭제·승인·반려·보관 이력 조회

## 2. 기술 구성

- **화면:** 표준 HTML/CSS/JavaScript, 반응형 PWA
- **인증·DB·파일:** Supabase Auth + PostgreSQL + Storage
- **호스팅:** Netlify 정적 배포 + Netlify Functions
- **형상관리:** GitHub + GitHub Actions 정적 검사
- **Excel:** SheetJS를 이용한 업로드·다운로드
- **차트:** Chart.js

Netlify에는 실행 화면과 보안용 서버리스 함수만 배포되며, 실제 업무 데이터는 Supabase PostgreSQL에 저장됩니다. 브라우저 `localStorage`에 회사 원본 데이터를 보관하지 않습니다.

## 3. 가장 빠른 설치 순서

### STEP 1. Supabase 프로젝트 생성

1. Supabase에서 새 프로젝트를 생성합니다.
2. `SQL Editor`에서 다음 파일을 순서대로 실행합니다.
   - `supabase/migrations/20261018_001_finance_app.sql`
   - `supabase/seed.sql` (삼코·삼천산업·창진에스씨 및 기본 분류를 사용할 때)
3. `Project Settings → API`에서 다음 값을 확인합니다.
   - Project URL
   - anon/public key
   - service_role key

> `service_role` 키는 절대로 브라우저 코드나 GitHub에 넣지 않습니다. Netlify 환경변수에만 저장합니다.

### STEP 2. 최초 관리자 계정 생성

1. Supabase `Authentication → Users`에서 최초 사용자를 생성합니다.
2. 해당 사용자 UUID를 확인합니다.
3. `supabase/bootstrap_admin.sql.example`을 복사하여 사용자 UUID를 교체한 뒤 SQL Editor에서 실행합니다.

또는 다음 SQL을 직접 실행합니다.

```sql
update public.profiles
set role='admin', full_name='시스템 관리자', active=true
where id='여기에_사용자_UUID';

insert into public.company_memberships(company_id,user_id,access_level)
select id,'여기에_사용자_UUID','manage'
from public.companies
on conflict(company_id,user_id) do update set access_level='manage';
```

### STEP 3. GitHub 저장소 생성

```bash
git init
git add .
git commit -m "Initial finance management app"
git branch -M main
git remote add origin https://github.com/회사계정/저장소명.git
git push -u origin main
```

### STEP 4. Netlify 배포

1. Netlify에서 `Add new site → Import an existing project`를 선택합니다.
2. GitHub 저장소를 연결합니다.
3. 이 저장소의 `netlify.toml`이 다음을 자동 적용합니다.
   - Publish directory: `public`
   - Functions directory: `netlify/functions`
4. Netlify `Site configuration → Environment variables`에 아래 값을 등록합니다.

| 환경변수 | 내용 |
|---|---|
| `APP_NAME` | 창진에스씨 재무관리 |
| `SUPABASE_URL` | Supabase Project URL |
| `SUPABASE_ANON_KEY` | Supabase anon/public key |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase service_role key |
| `ALLOWED_ORIGINS` | Netlify 주소와 회사 도메인을 쉼표로 구분 |

5. 재배포 후 Netlify 주소로 접속하여 로그인합니다.

### STEP 5. 사용자와 업무권한 설정

1. 최초 관리자로 로그인합니다.
2. `관리자 설정 → 사용자 등록`에서 이름·이메일·임시비밀번호·역할을 등록합니다.
3. 법인별 접근수준을 선택합니다.
   - `조회`: 대표·임원·감사
   - `현업 입력`: 담당업무 등록·수정
   - `재무 관리`: 거래 분류·수합·보고서 작성
   - `전체 관리`: 법인 단위 전체 권한
4. 결재자는 역할을 `결재자` 또는 `대표·임원`으로 지정합니다.

## 4. 업무 흐름

```text
현업 담당자 입력·은행파일 업로드
        ↓
재무 담당자 거래분류·예정/실적 연결·오류 확인
        ↓
재무 관리자 법인별 수합·보고서 스냅샷 생성
        ↓
결재자 선택 및 순차 결재 요청
        ↓
승인 또는 반려(의견 필수 기록)
        ↓
승인 보고서 보관·대표 대시보드 반영·이력 유지
```

## 5. 지원 파일

### 은행 거래내역
다음 열을 자동 인식합니다.

`거래일시 / 적요 / 입금액 / 출금액 / 내용 / 잔액 / 거래점명 / 입금인코드 / 메모`

- 파일 원본은 Supabase Storage의 비공개 `finance-files` 버킷에 보관합니다.
- 거래일시·금액·잔액·거래내용을 조합한 해시로 중복을 방지합니다.
- 분류 키워드로 추천 분류를 표시하고 담당자가 최종 확정합니다.

### 기존 재무현황 입력양식
`자료구분 / 법인명`으로 시작하는 기존 34개 열 양식을 인식합니다.

- 현금잔고·필수보유현금
- 월별 수입·급여·외상대금·이자·기타비용
- 입금·지급·계좌이체 예정
- 자산배분
- 단기투자
- 외화예금

### 과거 자금계획서
제목이 `YYYY년 MM월 조달 및 지출 계획` 형식인 파일을 인식하여 수입·지출 일정을 변환합니다.

### 기존 HTML JSON 백업
기존 HTML의 `데이터 백업 저장` 기능으로 내려받은 JSON을 업로드하면 법인별 잔고·월별 계획·일정·자산·단기투자·외화예금을 신규 DB 구조로 변환합니다. 외화예금은 수동환율도 함께 이관합니다.

### 외화환율
`계좌·대출·예금 → 실시간 환율 반영`에서 USD·EUR·JPY·CNY·THB의 원화 환율을 불러와 외화상품에 적용합니다. 외부 환율 서버 장애 시 금융상품 수정 화면에서 수동환율을 입력할 수 있습니다.

## 6. 결재·이력 원칙

- 결재선은 보고서 제출 시 사용자가 선택하며 순번대로 진행됩니다.
- 앞 순번이 승인되어야 다음 결재자가 처리할 수 있습니다.
- 반려 시 뒤 결재단계는 자동 취소됩니다.
- 승인된 보고서만 보관할 수 있습니다.
- 보고서 제출 시 스냅샷과 버전이 저장됩니다.
- 주요 업무 테이블은 PostgreSQL Trigger로 INSERT/UPDATE/DELETE 이력을 남깁니다.

## 7. 전체 백업·복원

- 관리자 또는 재무 관리자는 `전체 백업`으로 JSON 파일을 내려받을 수 있습니다.
- 복원은 관리자만 수행할 수 있으며 별도 확인 헤더가 있어야 실행됩니다.
- 원본 은행파일은 DB 백업에 바이너리로 포함하지 않고 Storage 경로를 보관합니다.
- 운영 전 Supabase의 자동 백업 정책과 보존기간을 별도로 확인하십시오.

## 8. 데모 화면

Supabase 설정 전 화면을 확인하려면 정적 서버에서 다음 주소를 엽니다.

```text
http://localhost:8888/?demo=1
```

데모 데이터는 브라우저 localStorage에만 저장되며 실제 운영 데이터로 사용하면 안 됩니다.

## 9. 로컬 개발

```bash
npm install
cp .env.example .env
npm run dev
```

Netlify CLI가 `/api/*` 함수와 정적 파일을 함께 실행합니다.

## 10. 운영 필수 점검

- Supabase RLS 활성화 여부
- service_role 키가 브라우저에 노출되지 않는지
- 사용자 퇴사·부서이동 시 계정 비활성 처리
- 월 1회 전체 백업 다운로드 및 복원 시험
- 대표·임원 계정은 조회 중심으로 설정
- 실제 계좌번호는 전체 저장하지 않고 마스킹 값만 저장
- 재무자료 다운로드 파일의 보관·폐기 규칙 적용

비전문가 운영 절차는 `docs/OPERATIONS_MANUAL.md`, 구현 범위와 운영 전 확인은 `docs/IMPLEMENTATION_STATUS.md`를 참고하십시오.

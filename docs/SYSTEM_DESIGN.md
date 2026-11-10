# 시스템 설계

## 1. 구조

```text
사용자 브라우저/PWA
  ├─ Supabase Auth: 로그인·세션
  ├─ Supabase Data API: RLS 기반 업무데이터 CRUD
  ├─ Supabase Storage: 은행 원본파일 비공개 보관
  └─ Netlify Functions
       ├─ runtime-config: 공개 설정 전달
       ├─ admin-users: 사용자 생성·수정·비활성화
       ├─ full-backup: 전체 DB JSON 백업
       └─ restore-backup: 관리자 전용 복원

GitHub → Netlify 자동배포
Supabase PostgreSQL → 영구 데이터·결재·감사기록
```

## 2. 주요 테이블

- `companies`: 법인
- `profiles`: 사용자 프로필과 역할
- `company_memberships`: 법인별 접근수준
- `module_assignments`: 메뉴별 세부 권한
- `cash_accounts`: 계좌 잔고와 필수보유현금
- `import_batches`: 업로드 이력과 원본파일 경로
- `bank_transactions`: 은행 거래내역
- `finance_categories`: 거래 분류와 추천 키워드
- `schedules`: 입금·지급·계좌이체 예정
- `financial_products`: 예금·대출·MMT·외화예금
- `monthly_plans`: 월별 수입·지출 계획
- `asset_positions`: 자산배분
- `reports`: 보고서 스냅샷
- `report_versions`: 보고서 버전
- `approval_steps`: 결재 순서와 처리결과
- `audit_logs`: 변경 전·후 이력

## 3. 권한 설계

권한은 두 겹으로 적용합니다.

1. 애플리케이션 메뉴 권한
2. PostgreSQL Row Level Security

화면에서 메뉴가 숨겨져도 DB RLS가 허용하지 않으면 조회·수정할 수 없습니다.

## 4. 데이터 보존

- Netlify 파일시스템에는 업무데이터를 저장하지 않습니다.
- 브라우저 localStorage는 데모모드에만 사용합니다.
- 실제 운영 데이터는 Supabase PostgreSQL에 저장합니다.
- 원본 은행파일은 private Storage bucket에 저장합니다.
- 보고서 제출 시 계산결과를 JSON 스냅샷과 버전으로 고정합니다.

## 5. 중복방지

은행거래는 다음 항목을 조합한 SHA-256 해시를 생성합니다.

`거래일시 | 적요 | 입금액 | 출금액 | 내용 | 잔액 | 거래점`

회사별 `company_id + source_hash`가 고유하도록 DB 제약조건을 적용합니다.

## 6. 결재 흐름

- 보고서 제출 시 선택된 결재자 배열을 순서대로 `approval_steps`에 저장합니다.
- 앞 단계가 승인되지 않으면 다음 단계는 처리할 수 없습니다.
- 반려 시 보고서 상태를 `rejected`, 나머지 대기단계를 `cancelled`로 변경합니다.
- 전원 승인 후 `approved`, 재무 관리자가 `archived`로 보관합니다.

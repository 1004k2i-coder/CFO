# 창진에스씨 재무관리 2.2

은행별 엑셀 업로드, 거래 확정 분류 자동 선택, 과거 자금계획서 일정 생성, 경영 대시보드 금액 표시를 수정한 버전입니다.

- 적용 방법과 사용법: [UPDATE_GUIDE.md](UPDATE_GUIDE.md)
- 기존 사용자·기기 승인 안내: [docs/APPROVAL_V21.md](docs/APPROVAL_V21.md)
- 신규 설치 SQL: supabase/INSTALL_ALL.sql
- 2.0에서 승인 기능을 갱신할 때만 사용하는 SQL: supabase/UPDATE_2_1.sql
- 2.1에서 이번 2.2로 변경할 때는 추가 SQL 실행이 없습니다.

기존 public/config.js의 URL과 공개 API 키를 유지한 상태에서 GitHub에 반영하고 Netlify 배포를 완료하세요.

개발 검증 명령: npm run ci

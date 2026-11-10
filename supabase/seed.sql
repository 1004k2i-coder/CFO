-- Optional seed data. Run after the main migration.
insert into public.companies(code,name) values
  ('SAMCO','삼코'),
  ('SAMCHEON','삼천산업'),
  ('CHANGJIN','창진에스씨')
on conflict (code) do update set name=excluded.name, active=true;

insert into public.finance_categories(company_id,name,direction,keywords,sort_order) values
  (null,'거래처 수금','receipt',array['매출','수금','입금','외상대금'],10),
  (null,'차입금 수령','receipt',array['대출금','차입금','융자'],20),
  (null,'이자수익','receipt',array['이자수','이자수익'],30),
  (null,'매입대금','payment',array['외상대','매입','업체대금','협력회사'],40),
  (null,'급여·인건비','payment',array['급여','용역대금','외주급여','퇴직금'],50),
  (null,'세금·공과금','payment',array['세금','부가세','원천세','재산세','인지대','사업소세'],60),
  (null,'4대보험','payment',array['국민연금','건강','의보','고용보험','산재보험','보험료'],70),
  (null,'카드대금','payment',array['카드','신한카드','법인카드'],80),
  (null,'대출이자','payment',array['대출이자','이자비용'],90),
  (null,'통신·공공요금','payment',array['통신','오피스넷','수도','전기요금'],100),
  (null,'임차료·렌탈','payment',array['임차료','렌탈','기숙사'],110),
  (null,'내부이체','transfer',array['자사 계좌','MMT이체','MMT출금','타계좌','계좌이체'],120),
  (null,'기타','mixed',array[]::text[],999)
on conflict do nothing;

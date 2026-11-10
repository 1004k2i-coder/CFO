const response=(statusCode,body)=>({statusCode,headers:{'content-type':'application/json','cache-control':'public, max-age=3600'},body:JSON.stringify(body)});
const corsHeaders=()=>({});

export async function handler(event) {
  const cors=corsHeaders(event);
  if(event.httpMethod==='OPTIONS')return {statusCode:204,headers:cors,body:''};
  try{
    const res=await fetch('https://open.er-api.com/v6/latest/USD',{headers:{accept:'application/json'}});
    if(!res.ok)throw new Error(`환율 제공 서버 응답 오류 ${res.status}`);
    const data=await res.json();
    const krw=Number(data?.rates?.KRW||0);
    if(!krw)throw new Error('KRW 환율을 확인할 수 없습니다.');
    const per=currency=>{const r=Number(data?.rates?.[currency]||0);return r>0?krw/r:0};
    return response(200,{
      base:'KRW',source:'open.er-api.com',updated_at:data.time_last_update_utc||new Date().toISOString(),
      rates:{USD:krw,EUR:per('EUR'),JPY:per('JPY'),CNY:per('CNY'),THB:per('THB')}
    },cors);
  }catch(error){return response(error.statusCode||502,{error:error.message},cors)}
}

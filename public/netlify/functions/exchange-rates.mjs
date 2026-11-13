const response=(statusCode,body)=>({statusCode,headers:{'content-type':'application/json','cache-control':'no-store, max-age=0'},body:JSON.stringify(body)});
export function convertRates(data){
 if(data.result!=='success'||data.base_code!=='USD')throw new Error('환율 제공 응답 형식을 확인할 수 없습니다.');
 const krw=Number(data.rates?.KRW);if(!Number.isFinite(krw)||krw<=0)throw new Error('원화 환율이 없습니다.');
 const rates={};for(const code of ['USD','JPY','THB','EUR','CNY']){const value=Number(data.rates?.[code]);if(!Number.isFinite(value)||value<=0)throw new Error(code+' 환율이 없습니다.');rates[code]=krw/value;}
 const updated=new Date(Number(data.time_last_update_unix)*1000);if(!Number.isFinite(updated.getTime())||!Number(data.time_last_update_unix))throw new Error('환율 기준시각이 없습니다.');
 return {base:'KRW',source:'ExchangeRate-API',source_url:'https://www.exchangerate-api.com',updated_at:updated.toISOString(),fetched_at:new Date().toISOString(),frequency:'daily',rates};
}
export async function handler(event){
 if(event.httpMethod!=='GET')return response(405,{error:'GET 요청만 지원합니다.'});
 try{const res=await fetch('https://open.er-api.com/v6/latest/USD',{headers:{accept:'application/json'},cache:'no-store',signal:AbortSignal.timeout(12000)});if(!res.ok)throw new Error('환율 제공 서버 응답 오류 '+res.status);return response(200,convertRates(await res.json()));}catch(e){return response(502,{error:e.message});}
}

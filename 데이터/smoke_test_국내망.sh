#!/usr/bin/env bash
###############################################################################
# 외교부·산하기관 공공데이터 API 스모크 테스트 (국내망 실행용)  v1.0 2026-07-04
#
# 목적 (F3 임무):
#  (a) KOICA 조달 API 기관코드 확정: B260003 vs B260004 (+ 데이터셋 3039908 vs 15158380)
#  (b) 한아프리카재단 스타트업 API(15099203) 레코드 최신성 확인 (2022 정체가 API에도 해당하는지)
#  (c) 여행경보 15076237 vs 15095500 대륙코드 값·행수 diff 및 ISO 조인 영향
#  (d) TLS·쿼터·응답 스키마 실측치 표(TSV) 생성
#
# 사용법:
#   1) data.go.kr 로그인 → 아래 8개 데이터셋 각각 [활용신청] (개발계정 자동승인, 일 10,000건)
#      15076237, 15095500, 15076239, 15075354, 15158399, 3039908(+15158380 페이지도 확인), 15076252, 15099203
#   2) 마이페이지에서 "일반 인증키(Encoding)"을 복사 (Decoding 키 아님!)
#   3) SERVICE_KEY='발급키(Encoding)' bash smoke_test_국내망.sh
#      * 키가 미반영이면 30분~수시간 후 재시도 (SERVICE_KEY_IS_NOT_REGISTERED_ERROR)
#   4) 산출물: ./smoke_out/ 아래 원시응답 + summary.tsv + diff 리포트
#
# 요구사항: bash, curl, python3 (jq 불필요). Windows는 WSL/Git Bash 사용.
#
# 수동 체크리스트 (스크립트가 못 하는 것 — 반드시 브라우저로):
#  [ ] data.go.kr/data/3039908/openapi.do  의 "요청주소"에서 기관코드(B26000X)와 서비스명 캡처
#  [ ] data.go.kr/data/15158380/openapi.do 의 "요청주소" 캡처 → 3039908과 동일 API인지 판정
#  [ ] 15099203 페이지의 등록일/수정일 캡처 (파일판 15099247은 _20220228)
#  [ ] 15076239 페이지의 서비스 버전 (CountrySafetyService3 vs 6) 및 참고문서 PDF 다운로드
#  [ ] 각 API 상세페이지의 "활용신청 트래픽"(개발 10,000 여부)과 운영계정 승인방식(자동/심의) 캡처
###############################################################################
set -u
KEY="${SERVICE_KEY:-}"
if [ -z "$KEY" ]; then echo "SERVICE_KEY 환경변수를 지정하세요 (Encoding 키)"; exit 1; fi
OUT="smoke_out"; mkdir -p "$OUT"
SUM="$OUT/summary.tsv"
echo -e "dataset_id\tname\tendpoint\thttp_code\ttls_mode\tresult_code\ttotal_count\tlatest_date\tnote" > "$SUM"

# ---- TLS 3단 폴백: 정상 https → legacy renegotiation 허용 → http 다운그레이드 ----
# 실측 근거: apis.data.go.kr 는 legacy TLS renegotiation 을 요구하여 OpenSSL3(Node18+/최신 curl)
# 기본설정에서 EPROTO 로 실패하는 사례가 보고됨. (SECLEVEL=1 + UnsafeLegacyRenegotiation 로 해소)
LEGACY_CONF="$OUT/openssl_legacy.cnf"
cat > "$LEGACY_CONF" <<'EOF'
openssl_conf = openssl_init
[openssl_init]
ssl_conf = ssl_sect
[ssl_sect]
system_default = system_default_sect
[system_default_sect]
Options = UnsafeLegacyRenegotiation
CipherString = DEFAULT@SECLEVEL=1
EOF

fetch () { # $1=url  $2=outfile   → echo "http_code|tls_mode"
  local url="$1" f="$2" code
  code=$(curl -sS -o "$f" -w "%{http_code}" --max-time 40 "$url" 2>"$f.err") \
    && { echo "$code|tls_normal"; return; }
  code=$(OPENSSL_CONF="$LEGACY_CONF" curl -sS -o "$f" -w "%{http_code}" --max-time 40 --ciphers 'DEFAULT@SECLEVEL=1' "$url" 2>>"$f.err") \
    && { echo "$code|tls_legacy_renego"; return; }
  code=$(curl -sS -o "$f" -w "%{http_code}" --max-time 40 "${url/https:/http:}" 2>>"$f.err") \
    && { echo "$code|http_downgrade"; return; }
  echo "000|fail"
}

parse () { # $1=file → "result_code|total_count|latest_date|first_item_keys"
  python3 - "$1" <<'PY'
import json,sys,re,datetime
raw=open(sys.argv[1],'rb').read().decode('utf-8','replace').strip()
rc=tc=latest='?'; keys=''
def dates(s):
    return re.findall(r'20\d{2}[-./]?[01]\d[-./]?[0-3]\d', s)
try:
    j=json.loads(raw)
    def dig(d,*ks):
        for k in ks:
            if isinstance(d,dict) and k in d: d=d[k]
            else: return None
        return d
    rc = dig(j,'response','header','resultCode') or dig(j,'HEADER','RESULT_CODE') or dig(j,'currentCount') is not None and '0' or '?'
    tc = dig(j,'response','body','totalCount') or dig(j,'totalCount') or dig(j,'BODY','totalCount') or '?'
    items = dig(j,'response','body','items','item') or dig(j,'response','body','items') or dig(j,'BODY','ITEMS','ITEM') or dig(j,'data') or []
    if isinstance(items,dict): items=[items]
    if items and isinstance(items,list) and isinstance(items[0],dict):
        keys=','.join(list(items[0].keys())[:18])
    ds=dates(raw); latest=max(ds) if ds else '-'
except Exception:
    m=re.search(r'<(?:resultCode|RESULT_CODE)>([^<]*)<',raw,re.I); rc=m.group(1) if m else '?'
    m=re.search(r'<totalCount>([^<]*)<',raw,re.I); tc=m.group(1) if m else '?'
    m=re.search(r'returnAuthMsg>([^<]*)<',raw,re.I)
    if m: rc=(rc if rc!='?' else '')+':'+m.group(1)
    ds=dates(raw); latest=max(ds) if ds else '-'
    tags=re.findall(r'<([A-Za-z_][A-Za-z0-9_]{1,30})>',raw)[:18]; keys=','.join(dict.fromkeys(tags))
print(f"{rc}|{tc}|{latest}|{keys}")
PY
}

row () { # $1 id  $2 name  $3 url  $4 outfile
  local r p
  r=$(fetch "$3" "$4"); p=$(parse "$4")
  echo -e "$1\t$2\t${3%%\?*}\t${r%%|*}\t${r##*|}\t$(echo "$p"|cut -d'|' -f1)\t$(echo "$p"|cut -d'|' -f2)\t$(echo "$p"|cut -d'|' -f3)\tkeys=$(echo "$p"|cut -d'|' -f4)" >> "$SUM"
  echo "[$1] $2 → http=${r%%|*} tls=${r##*|} result=$(echo "$p"|cut -d'|' -f1) total=$(echo "$p"|cut -d'|' -f2) latest=$(echo "$p"|cut -d'|' -f3)"
}

B="https://apis.data.go.kr"

# 1) 15076237 여행경보 (TravelAlarmService2) — 전량 JSON
row 15076237 "MOFA_여행경보_v2" \
  "$B/1262000/TravelAlarmService2/getTravelAlarmList2?serviceKey=$KEY&returnType=JSON&numOfRows=300&pageNo=1" \
  "$OUT/15076237_alarm_v2.json"

# 2) 15095500 여행경보(0404 대륙정보) — 전량 JSON
row 15095500 "MOFA_여행경보_0404" \
  "$B/1262000/TravelAlarmService0404/getTravelAlarm0404List?serviceKey=$KEY&returnType=JSON&numOfRows=300&pageNo=1" \
  "$OUT/15095500_alarm_0404.json"

# 3) 15076239 안전공지 (버전 3과 6 모두 시도 → 버전 분기 확정)
row 15076239 "MOFA_안전공지_v3" \
  "$B/1262000/CountrySafetyService3/getCountrySafetyList3?serviceKey=$KEY&returnType=JSON&numOfRows=20&pageNo=1&cond%5Bcountry_nm%3A%3AEQ%5D=ALL" \
  "$OUT/15076239_safety_v3.json"
row 15076239 "MOFA_안전공지_v6(대조)" \
  "$B/1262000/CountrySafetyService6/getCountrySafetyList6?serviceKey=$KEY&returnType=JSON&numOfRows=20&pageNo=1" \
  "$OUT/15076239_safety_v6.json"

# 4) 15075354 재외공관 정보
row 15075354 "MOFA_재외공관" \
  "$B/1262000/EmbassyService2/getEmbassyList2?serviceKey=$KEY&returnType=JSON&numOfRows=300&pageNo=1" \
  "$OUT/15075354_embassy.json"

# 5) 15158399 KOICA 사업정보(분야,국가) — XML 전용, 필수 파라미터 있음 (스웨거로 확정됨)
row 15158399 "KOICA_사업정보_분야" \
  "$B/B260003/BsnsAddService/getBsnsInfoRealmList?serviceKey=$KEY&pageNo=1&numOfRows=20&P_YEAR=2024&P_BSNS_TY_CD=&P_SPORT_REALM_CD=" \
  "$OUT/15158399_bsns_realm.xml"
row 15158399 "KOICA_사업정보_국가" \
  "$B/B260003/BsnsAddService/getBsnsInfoNationList?serviceKey=$KEY&pageNo=1&numOfRows=20&P_YEAR=2024&P_BSNS_TY_CD=&P_NATION_CD=" \
  "$OUT/15158399_bsns_nation.xml"

# 6) (a) KOICA 조달 — 기관코드 이중 시도로 확정. 90일 범위.
FROM=$(date -d '-90 days' +%Y%m%d 2>/dev/null || date -v-90d +%Y%m%d)
TO=$(date +%Y%m%d)
row 3039908 "KOICA_조달_B260004시도" \
  "$B/B260004/KoicaProcurementInfoService/getBidNoticeList?serviceKey=$KEY&pageNo=1&numOfRows=50&fromDate=$FROM&toDate=$TO&type=json" \
  "$OUT/3039908_bid_B260004.json"
row 3039908 "KOICA_조달_B260003시도" \
  "$B/B260003/KoicaProcurementInfoService/getBidNoticeList?serviceKey=$KEY&pageNo=1&numOfRows=50&fromDate=$FROM&toDate=$TO&type=json" \
  "$OUT/3039908_bid_B260003.json"
# 판정: 한쪽만 result 정상(00/0)이고 다른쪽이 SERVICE ERROR/ROUTE ERROR 면 그 코드가 정답.
# 참고: 같은 API가 신규 등록 15158380 로도 노출됨 (jmconnected-kr 사이트의 신청 링크 실측).
#       나라장터 차세대 이관 공지 有 → 계약/발주계획 오퍼레이션명은 상세페이지 스웨거에서 캡처할 것.

# 7) 15076252 KF 분야별 한류현황
row 15076252 "KF_분야별한류현황" \
  "$B/B260004/FieldKoreanwaveService2/getFieldKoreanwaveList2?serviceKey=$KEY&returnType=JSON&numOfRows=50&pageNo=1" \
  "$OUT/15076252_koreanwave.json"

# 8) (b) 15099203 한아프리카재단 스타트업 디렉터리 — 최신성 판정 핵심
row 15099203 "KAF_아프리카스타트업" \
  "$B/B554031/AfricaStartupCompanyService/getAfricaStartupCompanyList?serviceKey=$KEY&returnType=JSON&numOfRows=100&pageNo=1" \
  "$OUT/15099203_africastartup.json"
# 판정: latest_date 가 2022-0X 에 머물면 "API도 2022 정체" 확정.
#       totalCount 도 파일판(15099247, _20220228)과 비교해 증분 여부 기록.

# ---- (c) 여행경보 두 API diff: 대륙코드 값·행수·ISO 조인 영향 ----
python3 - "$OUT/15076237_alarm_v2.json" "$OUT/15095500_alarm_0404.json" > "$OUT/diff_15076237_vs_15095500.txt" <<'PY'
import json,sys
def load(p):
    try: j=json.load(open(p,encoding='utf-8'))
    except Exception as e: print(f"{p}: 파싱실패 {e}"); return {}
    it=j.get('response',{}).get('body',{}).get('items',{})
    it=it.get('item',it) if isinstance(it,dict) else it
    if isinstance(it,dict): it=[it]
    return {r.get('country_iso_alp2') or r.get('country_nm'): r for r in it or []}
a,b=load(sys.argv[1]),load(sys.argv[2])
print(f"15076237 행수={len(a)}  15095500 행수={len(b)}")
print("15076237에만:",sorted(set(a)-set(b)))
print("15095500에만:",sorted(set(b)-set(a)))
print("\n[대륙코드 매핑표] iso | v2:cd/nm | 0404:cd/nm | alarm_lvl(v2/0404)")
mis=0
for k in sorted(set(a)&set(b)):
    ca,cb=a[k],b[k]
    if (ca.get('continent_cd'),ca.get('continent_nm'))!=(cb.get('continent_cd'),cb.get('continent_nm')) \
       or ca.get('alarm_lvl')!=cb.get('alarm_lvl'):
        mis+=1
        print(f"{k} | {ca.get('continent_cd')}/{ca.get('continent_nm')} | {cb.get('continent_cd')}/{cb.get('continent_nm')} | {ca.get('alarm_lvl')}/{cb.get('alarm_lvl')}")
print(f"\n대륙/경보 불일치 국가수: {mis}")
from collections import Counter
print("v2  :",Counter((r.get('continent_cd'),r.get('continent_nm')) for r in a.values()))
print("0404:",Counter((r.get('continent_cd'),r.get('continent_nm')) for r in b.values()))
iso_missing_a=[k for k,r in a.items() if not r.get('country_iso_alp2')]
iso_missing_b=[k for k,r in b.items() if not r.get('country_iso_alp2')]
print("ISO 누락(v2):",iso_missing_a,"  ISO 누락(0404):",iso_missing_b)
PY
echo "---- diff 결과: $OUT/diff_15076237_vs_15095500.txt ----"
cat "$OUT/diff_15076237_vs_15095500.txt" || true

echo
echo "==== 완료. 제출용 실측표: $SUM ===="
echo "에러코드 참고: 22=일쿼터초과, 30=미등록키(반영대기 포함), 31=기간만료, 20=서비스거부, SERVICE ERROR/ROUTE ERROR=엔드포인트(기관코드) 오류"

#!/bin/bash
# weather.sh — ZIP -> Temp / Condition / Humidity / Pressure / Precip / Wind
# Updated by Mike Webb WG5EEK and Paul Aidukas KN2R

set -u
DEBUG="${DEBUG:-0}"   # DEBUG=1 ./weather.sh 72762

# -------------------- Switchboard --------------------
# Temperature display (on-screen). API/temp file unit is controlled by Temperature_mode.
SHOW_FAHRENHEIT="YES"     # show temperature in °F
SHOW_CELSIUS="NO"        # show temperature in °C

# Show/hide sections
SHOW_CONDITION="YES"      # e.g., Partly Cloudy
SHOW_HUMIDITY="YES"       # e.g., Humidity 52%
SHOW_PRESSURE="YES"       # pressure section
SHOW_PRECIP="YES"         # precipitation section
SHOW_WIND="YES"           # wind section

# Pressure output units (choose one or both)
SHOW_PRESSURE_INHG="YES"
SHOW_PRESSURE_HPA="NO"   # (aka mbar)

# Precip output units (choose one or both)
SHOW_PRECIP_INCH="YES"
SHOW_PRECIP_MM="NO"

# Wind output units (choose one or both)
SHOW_WIND_MPH="YES"
SHOW_WIND_KMH="NO"
# If you also want knots, flip this on:
SHOW_WIND_KN="NO"

# Core behavior
process_condition="YES"   # YES|NO -> build /tmp/condition.gsm
Temperature_mode="F"      # F or C (controls API unit & /tmp/temperature)

# API units (chosen for best conversion fan-out)
if [ "$Temperature_mode" = "F" ]; then
  temperature_unit="fahrenheit"
else
  temperature_unit="celsius"
fi
wind_speed_unit_api="ms"   # request m/s so we can render mph, kmh, kn
precipitation_unit_api="mm" # request mm so we can render inch/mm
timezone="auto"           # auto or explicit TZ (e.g., America/Chicago)
destdir="/tmp"

# -------------------- Usage --------------------
if [ $# -lt 1 ]; then
  echo
  echo "USAGE: $0 <US ZIP> [v]"
  echo "  Example: $0 72762"
  echo "           $0 72762 v   # text-only"
  echo
  exit 0
fi

ZIP="$1"
TEXT_ONLY="${2:-}"

# Clean previous outputs
rm -f "$destdir/temperature" "$destdir/condition.gsm"

# -------------------- Helpers --------------------
round(){ awk 'BEGIN{v='"$1"'; printf("%d",(v>=0)?int(v+0.5):int(v-0.5))}'; }
c_to_f(){ awk 'BEGIN{c='"$1"'; printf("%.0f", (c*9/5)+32)}'; }
f_to_c(){ awk 'BEGIN{f='"$1"'; printf("%.0f", (5/9)*(f-32))}'; }
hpa_to_inhg(){ awk 'BEGIN{h='"$1"'; printf("%.2f", h*0.02953)}'; }
ms_to_mph(){ awk 'BEGIN{m='"$1"'; printf("%d", (m*2.23694)+0.5)}'; }
ms_to_kmh(){ awk 'BEGIN{k='"$1"'; printf("%d", (k*3.6)+0.5)}'; }
ms_to_kn(){  awk 'BEGIN{m='"$1"'; printf("%d", (m*1.94384)+0.5)}'; }
mm_to_in(){  awk 'BEGIN{m='"$1"'; printf("%.2f", m/25.4)}'; }

# WMO → words (lowercase; we Title Case later)
wmo_to_words(){
  case "$1" in
    0) echo "clear" ;;
    1|2|3) echo "partly cloudy" ;;
    45|48) echo "fog" ;;
    51|53|55|56|57) echo "drizzle" ;;
    61|63|65|66|67) echo "rain" ;;
    71|73|75|77) echo "snow" ;;
    80|81|82) echo "showers" ;;
    85|86) echo "snow showers" ;;
    95|96|99) echo "thunderstorms" ;;
    *) echo "" ;;
  esac
}

# Title Case (capitalize each word)
title_case(){
  awk '{
    for(i=1;i<=NF;i++){ $i=toupper(substr($i,1,1)) tolower(substr($i,2)) }
    print
  }'
}

# 16-wind compass (N, NNE, NE, ...)
to_cardinal(){
  awk 'BEGIN{
    d='"${1:-0}"';
    while(d<0)d+=360; while(d>=360)d-=360;
    split("N NNE NE ENE E ESE SE SSE S SSW SW WSW W WNW NW NNW",a," ");
    idx=int((d+11.25)/22.5); if(idx==16)idx=0;
    print a[idx+1]
  }'
}

# Extract a single numeric "current" value from JSON
get_json_num(){ local key="$1"; printf "%s" "$2" | sed -n 's/.*"'"$key"'":[ ]*\([-0-9.]\+\).*/\1/p' | head -n1; }

# Robust join with " / "
join_with_slash(){
  local out=""; local first=1; local s
  for s in "$@"; do
    [ -z "$s" ] && continue
    if [ $first -eq 1 ]; then out="$s"; first=0; else out="$out / $s"; fi
  done
  printf "%s" "$out"
}

# Dual-stack curl helper. In DEBUG, no -f so we can capture error bodies.
curl_try() {
  local url="$1"
  if [ "${DEBUG:-0}" = "1" ]; then
    curl -sSL4 --retry 2 --connect-timeout 10 "$url" || \
    curl -sSL6 --retry 2 --connect-timeout 10 "$url" || \
    curl -sSL  --insecure --retry 2 --connect-timeout 10 "$url"
  else
    curl -fsSL4 --retry 2 --connect-timeout 10 "$url" 2>/dev/null || \
    curl -fsSL6 --retry 2 --connect-timeout 10 "$url" 2>/dev/null || \
    curl -fsSL  --insecure --retry 2 --connect-timeout 10 "$url" 2>/dev/null || true
  fi
}

# -------------------- 1) ZIP -> LAT/LON (ZIP-first, with sanity) --------------------
LAT=""; LON=""

in_us_bbox(){
  # Rough U.S. (incl. AK/HI) bounds: lat 18..72, lon -170..-60
  awk 'BEGIN{
    lat='"${1:-999}"'; lon='"${2:-999}"';
    ok=(lat>=18 && lat<=72 && lon<=-60 && lon>=-170)?1:0;
    print ok
  }'
}

# A) Try Zippopotam.us (authoritative ZIP → lat/lon)
ZIPPO_RAW="$(curl_try "http://api.zippopotam.us/us/${ZIP}")"
if [ -n "$ZIPPO_RAW" ]; then
  ZIPPO=$(printf "%s" "$ZIPPO_RAW" | tr -d '\n' | tr -d '\r')
  LAT=$(printf "%s" "$ZIPPO" | sed -n 's/.*"latitude":[ ]*"\([-0-9.]\+\)".*/\1/p'   | head -n1)
  LON=$(printf "%s" "$ZIPPO" | sed -n 's/.*"longitude":[ ]*"\([-0-9.]\+\)".*/\1/p' | head -n1)
fi

# If A failed or looks fishy, B) use Open-Meteo geocoder as fallback
ok="$(in_us_bbox "$LAT" "$LON")"
if [ -z "$LAT" ] || [ -z "$LON" ] || [ "$ok" != "1" ]; then
  LAT=""; LON=""
  GEO_RAW="$(curl_try "https://geocoding-api.open-meteo.com/v1/search?name=${ZIP}&count=1&language=en&format=json&country=US")"
  if [ -n "$GEO_RAW" ]; then
    GEO=$(printf "%s" "$GEO_RAW" | tr -d '\n' | tr -d '\r')
    echo "$GEO" | grep -q '"results"' && {
      LAT=$(printf "%s" "$GEO" | sed -n 's/.*"latitude":[ ]*\([-0-9.]\+\).*/\1/p'   | head -n1)
      LON=$(printf "%s" "$GEO" | sed -n 's/.*"longitude":[ ]*\([-0-9.]\+\).*/\1/p' | head -n1)
    }
    ok="$(in_us_bbox "$LAT" "$LON")"
    [ "$ok" != "1" ] && { LAT=""; LON=""; }
  fi
fi

if [ -z "$LAT" ] || [ -z "$LON" ]; then
  echo "No Report"
  exit 1
fi

# -------------------- 2) Build minimal URL --------------------
CUR_KEYS="temperature_2m,weather_code,relative_humidity_2m,pressure_msl,wind_speed_10m,wind_direction_10m,precipitation"

BASE="https://api.open-meteo.com/v1/forecast"
URL="${BASE}?latitude=${LAT}&longitude=${LON}&current=${CUR_KEYS}&temperature_unit=${temperature_unit}&wind_speed_unit=${wind_speed_unit_api}&precipitation_unit=${precipitation_unit_api}&timezone=${timezone}"

[ "$DEBUG" = "1" ] && echo "URL: ${URL}" >&2

# -------------------- 3) Fetch --------------------
RAW="$(curl_try "$URL")"
[ "$DEBUG" = "1" ] && echo "Reply (first 400 bytes): $(printf '%s' "$RAW" | cut -c1-400)" >&2
[ -z "$RAW" ] && { echo "No Report"; exit 1; }
RAW_JSON=$(printf "%s" "$RAW" | tr -d '\n' | tr -d '\r')

# -------------------- 4) Parse --------------------
T_NOW=$(get_json_num "temperature_2m" "$RAW_JSON"); [ -z "$T_NOW" ] && { echo "No Report"; exit 1; }

# Compute both display temps & choose which to show
if [ "$Temperature_mode" = "F" ]; then
  TF=$(round "$T_NOW"); TC=$(f_to_c "$TF"); TOUT="$TF"
else
  TC=$(round "$T_NOW"); TF=$(c_to_f "$TC"); TOUT="$TC"
fi

WCODE=$(get_json_num "weather_code" "$RAW_JSON")
COND_RAW="$(wmo_to_words "$WCODE")"
COND_TITLE="$(printf "%s" "$COND_RAW" | title_case)"

RH=$(get_json_num "relative_humidity_2m" "$RAW_JSON")
PMSL=$(get_json_num "pressure_msl" "$RAW_JSON")
WS_MS=$(get_json_num "wind_speed_10m" "$RAW_JSON")      # m/s from API
WD=$(get_json_num "wind_direction_10m" "$RAW_JSON")
PR_MM=$(get_json_num "precipitation" "$RAW_JSON")       # mm from API

# -------------------- 5) Build sections (respect unit toggles) --------------------
SECTIONS=()

# Temperatures
[ "$SHOW_FAHRENHEIT" = "YES" ] && SECTIONS+=("${TF}F")
[ "$SHOW_CELSIUS"   = "YES" ] && SECTIONS+=("${TC}C")

# Condition
if [ "$SHOW_CONDITION" = "YES" ] && [ -n "$COND_TITLE" ]; then
  SECTIONS+=("$COND_TITLE")
fi

# Humidity
if [ "$SHOW_HUMIDITY" = "YES" ] && [ -n "$RH" ]; then
  SECTIONS+=("Humidity $(round "$RH")%")
fi

# Pressure
if [ "$SHOW_PRESSURE" = "YES" ] && [ -n "$PMSL" ]; then
  P_LINE=""
  if [ "$SHOW_PRESSURE_INHG" = "YES" ]; then
    P_LINE="$(hpa_to_inhg "$PMSL") inHG"
  fi
  if [ "$SHOW_PRESSURE_HPA" = "YES" ]; then
    if [ -n "$P_LINE" ]; then
      P_LINE="$P_LINE ($(awk 'BEGIN{h='"$PMSL"'; printf("%d", h+0.5)}') hPa)"
    else
      P_LINE="$(awk 'BEGIN{h='"$PMSL"'; printf("%d", h+0.5)}') hPa"
    fi
  fi
  [ -n "$P_LINE" ] && SECTIONS+=("$P_LINE")
fi

# Wind
if [ "$SHOW_WIND" = "YES" ] && [ -n "$WS_MS" ]; then
  local_wind=""
  if [ "$SHOW_WIND_MPH" = "YES" ]; then
    local_wind="$(ms_to_mph "$WS_MS") mph"
  fi
  if [ "$SHOW_WIND_KMH" = "YES" ]; then
    kmh="$(ms_to_kmh "$WS_MS") kmh"
    if [ -n "$local_wind" ]; then local_wind="$local_wind ($kmh)"; else local_wind="$kmh"; fi
  fi
  if [ "$SHOW_WIND_KN" = "YES" ]; then
    kn="$(ms_to_kn "$WS_MS") kn"
    if [ -n "$local_wind" ]; then local_wind="$local_wind ($kn)"; else local_wind="$kn"; fi
  fi
  if [ -n "$WD" ]; then
    CARD="$(to_cardinal "$WD")"
    SECTIONS+=("Wind $local_wind $CARD")
  else
    SECTIONS+=("Wind $local_wind")
  fi
fi

# Precip
if [ "$SHOW_PRECIP" = "YES" ] && [ -n "$PR_MM" ]; then
  P_OUT=""
  if [ "$SHOW_PRECIP_INCH" = "YES" ]; then
    P_OUT="$(mm_to_in "$PR_MM") inch"
  fi
  if [ "$SHOW_PRECIP_MM" = "YES" ]; then
    mm_fmt="$(awk 'BEGIN{m='"$PR_MM"'; printf("%.2f", m)}') mm"
    if [ -n "$P_OUT" ]; then P_OUT="$P_OUT ($mm_fmt)"; else P_OUT="$mm_fmt"; fi
  fi
  [ -n "$P_OUT" ] && SECTIONS+=("Precip $P_OUT")
fi

# Join with " / "
OUTLINE="$(join_with_slash "${SECTIONS[@]}")"
echo "$OUTLINE"

# text-only mode
[ "$TEXT_ONLY" = "v" ] && exit 0

# -------------------- 6) Write /tmp/temperature --------------------
# (Store number only in the Temperature_mode unit)
if [ "$Temperature_mode" = "C" ]; then tmin=-60; tmax=60; else tmin=-100; tmax=150; fi
if [ -n "$TOUT" ] && [ "$TOUT" -ge "$tmin" ] 2>/dev/null && [ "$TOUT" -le "$tmax" ] 2>/dev/null; then
  echo "$TOUT" > "$destdir/temperature"
fi

# -------------------- 7) Optional /tmp/condition.gsm --------------------
if [ "$process_condition" = "YES" ] && [ -n "$COND_TITLE" ]; then
  C1=$(echo "$COND_TITLE" | awk '{print tolower($1)}')
  C2=$(echo "$COND_TITLE" | awk '{print tolower($2)}')
  C3=$(echo "$COND_TITLE" | awk '{print tolower($3)}')
  if command -v locate >/dev/null 2>&1; then
    CF1=$([ -n "$C1" ] && locate /"$C1".gsm 2>/dev/null | head -n1 || echo "")
    CF2=$([ -n "$C2" ] && locate /"$C2".gsm 2>/dev/null | head -n1 || echo "")
    CF3=$([ -n "$C3" ] && locate /"$C3".gsm 2>/dev/null | head -n1 || echo "")
    if [ -n "$CF1" ] || [ -n "$CF2" ] || [ -n "$CF3" ]; then
      cat $CF1 $CF2 $CF3 > "$destdir/condition.gsm" 2>/dev/null || true
    fi
  fi
fi

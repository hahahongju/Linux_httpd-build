#!/usr/bin/env bash
set -euo pipefail

if [ -z "${APP_HOME:-}" ]; then
  APP_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  APP_HOME="$(cd "${APP_BIN_DIR}/.." && pwd)"
fi

# Fallback for non-standard invocation (e.g. sourced script or wrapped shell).
if [ ! -x "${APP_HOME}/bin/httpd" ] || [ ! -f "${APP_HOME}/conf/httpd.conf" ]; then
  case "${BASH_SOURCE[0]:-$0}" in
    /*)
      CAND_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
      CAND_HOME="$(cd "${CAND_BIN_DIR}/.." && pwd)"
      if [ -x "${CAND_HOME}/bin/httpd" ] && [ -f "${CAND_HOME}/conf/httpd.conf" ]; then
        APP_HOME="${CAND_HOME}"
      fi
      ;;
  esac
fi

if [ ! -x "${APP_HOME}/bin/httpd" ] || [ ! -f "${APP_HOME}/conf/httpd.conf" ]; then
  if [ -x "./httpd" ] && [ -f "../conf/httpd.conf" ]; then
    APP_HOME="$(cd .. && pwd)"
  elif [ -x "./bin/httpd" ] && [ -f "./conf/httpd.conf" ]; then
    APP_HOME="$(pwd)"
  fi
fi
COMPILE_HOME="/Product/httpd-2.4.66-build/package/apache"
CONF_FILE="${APP_HOME}/conf/httpd.conf"
RUN_DIR="${APP_HOME}/run"
LOG_DIR="${APP_HOME}/logs"
MARKER_FILE="${RUN_DIR}/.relocate_apache_paths.done"
STATE_FILE="${RUN_DIR}/.relocate_apache_paths.home"
FORCE_RELOCATE="${FORCE_RELOCATE:-0}"

# 텍스트 스캔 대상 (conf/, modules/ 포함)
TARGET_DIRS=(
  "${APP_HOME}/bin"
  "${APP_HOME}/bins"
  "${APP_HOME}/conf"
  "${APP_HOME}/modules"
)

# httpd 실행권한 자동 보정
if [ -f "${APP_HOME}/bin/httpd" ] && [ ! -x "${APP_HOME}/bin/httpd" ]; then
  chmod 755 "${APP_HOME}/bin/httpd" 2>/dev/null || true
fi

[ -x "${APP_HOME}/bin/httpd" ] \
  || { echo "ERROR: httpd 없음: ${APP_HOME}/bin/httpd (PWD=$(pwd), argv0=${BASH_SOURCE[0]:-$0})" >&2; exit 1; }
[ -f "${CONF_FILE}" ] \
  || { echo "ERROR: httpd.conf 없음: ${CONF_FILE}" >&2; exit 1; }

mkdir -p "${LOG_DIR}" "${RUN_DIR}"

PREV_HOME=""
[ -f "${STATE_FILE}" ] && PREV_HOME="$(cat "${STATE_FILE}" 2>/dev/null || true)"

if [ "${FORCE_RELOCATE}" != "1" ] && [ -f "${MARKER_FILE}" ]; then
  if [ -z "${PREV_HOME}" ] || [ "${PREV_HOME}" = "${APP_HOME}" ]; then
    echo "INFO: relocate 완료됨. 강제 재실행: FORCE_RELOCATE=1"
    exit 0
  fi
fi

# ── 텍스트 파일 수집 ─────────────────────────────────────────────────────────
TEXT_FILES=()
for dir in "${TARGET_DIRS[@]}"; do
  [ -d "${dir}" ] || continue
  while IFS= read -r fpath; do
    [ -n "${fpath}" ] && TEXT_FILES+=("${fpath}")
  done < <(
    grep -IlR . "${dir}" \
      --exclude='*.so' --exclude='*.so.*' --exclude='*.a'  \
      --exclude='*.o'  --exclude='*.la'   --exclude='*.pyc'\
      --exclude='*.pem' --exclude='*.crt' --exclude='*.key'\
      --exclude='*.der' --exclude='*.p12' --exclude='*.gz' \
      --exclude='*.xz'  --exclude='*.zip' \
      2>/dev/null || true
  )
done

# ── 경로 치환 (빈 배열 안전 처리) ────────────────────────────────────────────
replace_path() {
  local old_path="$1" new_path="$2" fpath
  [ -n "${old_path}" ]               || return 0
  [ "${old_path}" != "${new_path}" ] || return 0
  [ "${#TEXT_FILES[@]}" -gt 0 ]     || return 0

  echo "  치환: '${old_path}' → '${new_path}'"
  for fpath in "${TEXT_FILES[@]+${TEXT_FILES[@]}}"; do
    OLD_PATH="${old_path}" NEW_PATH="${new_path}" \
      perl -0pi -e \
        'BEGIN{$old=$ENV{OLD_PATH};$new=$ENV{NEW_PATH}} s/\Q$old\E/$new/g' \
        "${fpath}" 2>/dev/null || true
  done
}

echo "INFO: relocate 시작 → ${APP_HOME}"
replace_path "${COMPILE_HOME}" "${APP_HOME}"
[ -n "${PREV_HOME}" ] && [ "${PREV_HOME}" != "${APP_HOME}" ] \
  && replace_path "${PREV_HOME}" "${APP_HOME}"

# ── apachectl: HTTPD_ROOT 주입 + -d 옵션 추가 ────────────────────────────────
# replace_path 후 HTTPD= 경로는 교정됐지만 httpd 호출에 -d 옵션이 없어
# 컴파일 내장 HTTPD_ROOT를 사용함 → 배포 경로로 강제 지정
_fix_apachectl() {
  local ctl="${APP_HOME}/bin/apachectl"
  [ -f "${ctl}" ] || return 0
  if grep -qF "HTTPD_ROOT=\"${APP_HOME}\"" "${ctl}" && grep -qF '-d "$HTTPD_ROOT"' "${ctl}"; then
    echo "INFO: apachectl 이미 수정됨 (skip)"
    return 0
  fi

  APP_HOME_VAR="${APP_HOME}" perl -i -e '
    my $root = $ENV{APP_HOME_VAR};
    while (<>) {
      print;
      if (/^HTTPD=/) { print "HTTPD_ROOT=\"$root\"\n"; }
    }
  ' "${ctl}"

  perl -i -e '
    my $opt = q{-d "$HTTPD_ROOT" };
    while (<>) {
      s/(\$HTTPD) (-k \$ARGV)/$1 ${opt}$2/;
      s/(\$HTTPD) (-t)\b/$1 ${opt}$2/;
      s/(\$HTTPD) ("\$\@")/$1 ${opt}$2/;
      print;
    }
  ' "${ctl}"

  echo "INFO: apachectl -d \$HTTPD_ROOT 주입 완료"
}
_fix_apachectl

# ── httpd.conf 핵심 지시어 업데이트 ─────────────────────────────────────────
update_directive() {
  local key="$1" val="$2"
  if grep -qE "^[#[:space:]]*${key}[[:space:]]" "${CONF_FILE}"; then
    sed -i "s|^[#[:space:]]*${key}[[:space:]].*|${key} ${val}|g" "${CONF_FILE}"
  else
    printf '%s %s\n' "${key}" "${val}" >> "${CONF_FILE}"
  fi
}

update_directive "ServerRoot"        "\"${APP_HOME}\""
update_directive "DefaultRuntimeDir" "\"${APP_HOME}/run\""
update_directive "PidFile"           "\"${APP_HOME}/logs/httpd.pid\""
update_directive "ErrorLog"          "\"${APP_HOME}/logs/error_log\""

# ServerName: 주석 처리된 첫 항목 활성화
if grep -qE '^[#[:space:]]*ServerName[[:space:]]' "${CONF_FILE}"; then
  sed -i '0,/^[#[:space:]]*ServerName[[:space:]].*/s//ServerName localhost/' "${CONF_FILE}"
else
  printf 'ServerName localhost\n' >> "${CONF_FILE}"
fi

# ── 모듈 의존성 수정 ──────────────────────────────────────────────────────────
# mod_session_cookie / mod_session_crypto / mod_session_dbd 는
# mod_session 이 먼저 로드돼야 함 (ap_hook_session_save 심볼 제공)
if grep -qE '^LoadModule session_(cookie|crypto|dbd)_module' "${CONF_FILE}"; then
  if grep -qE '^#LoadModule session_module' "${CONF_FILE}"; then
    sed -i 's|^#\(LoadModule session_module\)|\1|' "${CONF_FILE}"
    echo "INFO: mod_session 활성화 (session_cookie/crypto/dbd 의존성 해결)"
  fi
fi

# ── 상태 저장 및 설정 검증 ───────────────────────────────────────────────────
printf '%s\n' "${APP_HOME}" > "${STATE_FILE}"
echo "INFO: httpd 설정 검증..."
export LD_LIBRARY_PATH="${APP_HOME}/bins/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export PATH="${APP_HOME}/bin:${APP_HOME}/bins/bin${PATH:+:${PATH}}"
"${APP_HOME}/bin/httpd" -d "${APP_HOME}" -f "${CONF_FILE}" -t \
  && {
    touch "${MARKER_FILE}"
    echo "INFO: 설정 OK"
  } \
  || { echo "ERROR: httpd -t 실패. ${APP_HOME}/logs/error_log 확인" >&2; exit 1; }

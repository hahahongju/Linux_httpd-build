#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Apache HTTP Server 2.4.66 - Native Build Script (No Container)
# 컨테이너(Docker/Podman) 없이 호스트 OS에서 직접 빌드
#
# 지원 OS : RHEL 8 / Rocky Linux 8 (권장, glibc 2.28)
#           RHEL 9 / Rocky Linux 9 (glibc 2.34, RHEL 9+ 배포용)
# 비지원  : RHEL 7 (APR/expat 등이 GLIBC_2.25 심볼 사용 → 실행 불가)
#           RHEL 10+ (glibc 2.39, mod_jk 등 GLIBC_2.38 요구 가능)
#
# [실행 방법]
#   # root 또는 sudo 권한 필요
#   bash httpd_build_native.sh
#
# [환경변수로 경로 커스터마이즈]
#   BUILD_BASE=/data/httpd-build bash httpd_build_native.sh
# =============================================================================
# [변경 이력]
# v1.0 (2026-04-08): httpd_build_final_v4.sh 기반, 컨테이너 없이 직접 빌드 지원
#                    - 경로 환경변수 커스터마이즈
#                    - OS/glibc 버전 자동 감지 및 호환성 경고
#                    - dnf/yum 자동 선택
#                    - 비root 사용자: sudo 자동 사용
# v1.1 (2026-04-09): 런타임 스크립트 이식성 보강
#                    - env/start/stop/restart/status 스크립트 sh 호환화
#                    - relocate_apache_paths.sh 의 bash 전용 구문 제거
#                    - DocumentRoot/htdocs 리로케이션 보강
#                    - sed -i 의존 제거(Perl 치환)
# v2.0 (2026-04-10): OpenSSL 3.5.6 업그레이드
#                    - OpenSSL 3.0.17 → 3.5.6 (LTS)
#                    - GLIBC 호환성 유지: RHEL 8(glibc 2.28) 빌드 시 RHEL 8+ 배포 가능
# =============================================================================

HTTPD_VERSION="2.4.66"
APR_VERSION="1.7.6"
APR_UTIL_VERSION="1.6.3"
PCRE2_VERSION="10.45"
ZLIB_VERSION="1.3.1"
EXPAT_VERSION="2.7.1"
OPENSSL_VERSION="3.5.6"
NGHTTP2_VERSION="1.65.0"
MOD_JK_VERSION="1.2.50"

# ── 경로 설정 (환경변수로 오버라이드 가능) ───────────────────────────────────
BUILD_BASE="${BUILD_BASE:-/opt/httpd-${HTTPD_VERSION}-build}"
SRC="${BUILD_BASE}/sources"
WORK="${BUILD_BASE}/work"
PKG="${BUILD_BASE}/package"
LOGS="${BUILD_BASE}/logs"
APACHE_PREFIX="${PKG}/apache"
DEPS_PREFIX="${APACHE_PREFIX}/bins"
OUT_TAR="${BUILD_BASE}/httpd-${HTTPD_VERSION}-compiled.tar.gz"

# ── 빌드 옵션 ──────────────────────────────────────────────────────────────
THREADS="$(nproc)"
CLEAN_WORK_AFTER_BUILD="${CLEAN_WORK_AFTER_BUILD:-1}"
VERIFY_CHECKSUM="${VERIFY_CHECKSUM:-1}"

DOWNLOAD_RETRY=3
DOWNLOAD_CONNECT_TIMEOUT=20
DOWNLOAD_MAX_TIME=1800

# =============================================================================
# 소스 파일 목록
# =============================================================================
SOURCE_FILES=(
  "httpd-${HTTPD_VERSION}.tar.gz\
|https://downloads.apache.org/httpd/httpd-${HTTPD_VERSION}.tar.gz\
|https://downloads.apache.org/httpd/httpd-${HTTPD_VERSION}.tar.gz.sha256"

  "apr-${APR_VERSION}.tar.gz\
|https://downloads.apache.org/apr/apr-${APR_VERSION}.tar.gz\
|https://downloads.apache.org/apr/apr-${APR_VERSION}.tar.gz.sha256"

  "apr-util-${APR_UTIL_VERSION}.tar.gz\
|https://downloads.apache.org/apr/apr-util-${APR_UTIL_VERSION}.tar.gz\
|https://downloads.apache.org/apr/apr-util-${APR_UTIL_VERSION}.tar.gz.sha256"

  "pcre2-${PCRE2_VERSION}.tar.gz\
|https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz\
|-"

  "zlib-${ZLIB_VERSION}.tar.gz\
|https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz\
|-"

  "expat-${EXPAT_VERSION}.tar.xz\
|https://github.com/libexpat/libexpat/releases/download/R_${EXPAT_VERSION//./_}/expat-${EXPAT_VERSION}.tar.xz\
|-"

  "openssl-${OPENSSL_VERSION}.tar.gz\
|https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz\
|https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz.sha256"

  "nghttp2-${NGHTTP2_VERSION}.tar.xz\
|https://github.com/nghttp2/nghttp2/releases/download/v${NGHTTP2_VERSION}/nghttp2-${NGHTTP2_VERSION}.tar.xz\
|-"

  "tomcat-connectors-${MOD_JK_VERSION}-src.tar.gz\
|https://downloads.apache.org/tomcat/tomcat-connectors/jk/tomcat-connectors-${MOD_JK_VERSION}-src.tar.gz\
|-"
)

# =============================================================================
# 유틸리티 함수
# =============================================================================
log()         { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die()         { echo "ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "필수 명령어 없음: $1"; }

# root 여부에 따라 sudo 사용 결정
_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

# =============================================================================
# OS / glibc 버전 감지 및 호환성 경고
# =============================================================================
check_os_compat() {
  log "=============================="
  log "OS / glibc 호환성 검사"

  # OS 정보
  local os_name os_version
  if [ -f /etc/os-release ]; then
    os_name="$(. /etc/os-release && echo "${NAME:-unknown}")"
    os_version="$(. /etc/os-release && echo "${VERSION_ID:-0}")"
  else
    os_name="$(uname -s)"
    os_version="unknown"
  fi

  # glibc 버전
  local glibc_ver
  glibc_ver="$(ldd --version 2>/dev/null | awk 'NR==1{print $NF}' || echo "unknown")"

  log "  OS     : ${os_name} ${os_version}"
  log "  glibc  : ${glibc_ver}"

  # 버전 비교 (major.minor)
  local major minor
  major="$(echo "${glibc_ver}" | cut -d. -f1)"
  minor="$(echo "${glibc_ver}" | cut -d. -f2)"

  if [ "${major:-0}" -lt 2 ] || { [ "${major:-0}" -eq 2 ] && [ "${minor:-0}" -lt 28 ]; }; then
    log "=============================="
    log "WARNING: glibc ${glibc_ver} 감지 - 빌드 결과가 이 시스템에서 실행되지 않을 수 있음"
    log "  APR, APR-util, expat 는 GLIBC_2.25 심볼을 사용합니다."
    log "  RHEL 7 (glibc 2.17) 은 지원하지 않습니다."
    log "=============================="
    read -r -p "계속 진행하시겠습니까? [y/N] " ans
    [[ "${ans}" =~ ^[Yy]$ ]] || exit 0
  elif [ "${major:-0}" -eq 2 ] && [ "${minor:-0}" -ge 36 ]; then
    log "=============================="
    log "WARNING: glibc ${glibc_ver} 감지 (RHEL 9+/10 환경)"
    log "  이 시스템에서 빌드하면 결과 바이너리가 GLIBC_2.3x 심볼을 요구할 수 있습니다."
    log "  RHEL 8 (glibc 2.28) 에 배포하려면 Rocky 8 컨테이너에서 빌드를 권장합니다."
    log "  현재 시스템(RHEL 9+)에만 배포한다면 그대로 진행 가능합니다."
    log "=============================="
    read -r -p "계속 진행하시겠습니까? [y/N] " ans
    [[ "${ans}" =~ ^[Yy]$ ]] || exit 0
  else
    log "  glibc ${glibc_ver} → RHEL 8+ 배포 호환 빌드 가능"
  fi

  log "=============================="
}

# =============================================================================
# 패키지 매니저 감지 및 빌드 도구 설치
# =============================================================================
prepare_build_tools() {
  log "빌드 툴체인 설치"

  # dnf 우선, 없으면 yum
  local PKG_MGR
  if command -v dnf >/dev/null 2>&1; then
    PKG_MGR="dnf"
  elif command -v yum >/dev/null 2>&1; then
    PKG_MGR="yum"
  else
    die "패키지 매니저(dnf/yum)를 찾을 수 없습니다."
  fi
  log "  패키지 매니저: ${PKG_MGR}"

  _sudo ${PKG_MGR} groupinstall -y "Development Tools" \
    || _sudo ${PKG_MGR} install -y gcc gcc-c++ make autoconf automake libtool
  _sudo ${PKG_MGR} install -y \
    wget curl tar gzip xz bzip2 \
    perl make which file diffutils findutils \
    grep sed gawk

  # patchelf 설치
  if ! command -v patchelf >/dev/null 2>&1; then
    log "patchelf 설치 시도 (EPEL)"
    _sudo ${PKG_MGR} install -y epel-release 2>/dev/null || true
    _sudo ${PKG_MGR} install -y patchelf 2>/dev/null || {
      log "EPEL 실패 → patchelf 소스 빌드 (v0.18.0)"
      local _pe_ver="0.18.0"
      local _pe_url="https://github.com/NixOS/patchelf/releases/download/${_pe_ver}/patchelf-${_pe_ver}.tar.bz2"
      curl -fSL --retry 3 "${_pe_url}" -o /tmp/patchelf.tar.bz2
      tar -xjf /tmp/patchelf.tar.bz2 -C /tmp
      (
        cd "/tmp/patchelf-${_pe_ver}"
        ./configure --prefix=/usr/local
        make -j"$(nproc)"
        _sudo make install
      )
    }
  fi

  for cmd in curl tar make gcc patchelf perl; do
    require_cmd "$cmd"
  done
  log "빌드 툴체인 준비 완료"
}

# =============================================================================
# 디렉터리 생성
# =============================================================================
prepare_dirs() {
  log "디렉터리 구조 생성: ${BUILD_BASE}"
  mkdir -p "$SRC" "$WORK" "$PKG" "$LOGS" "$APACHE_PREFIX" "$DEPS_PREFIX"
}

# =============================================================================
# 다운로드 헬퍼
# =============================================================================
download_file() {
  local url="$1" out="$2"
  curl -fL \
    --retry "$DOWNLOAD_RETRY" \
    --retry-delay 2 \
    --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" \
    --max-time "$DOWNLOAD_MAX_TIME" \
    -o "$out" "$url"
}

# =============================================================================
# SHA256 검증
# =============================================================================
verify_checksum() {
  local file="$1" sha256_url="$2"
  if [ "$VERIFY_CHECKSUM" != "1" ] || [ "$sha256_url" = "-" ]; then
    return 0
  fi
  local sha256_file="${file}.sha256"
  log "  SHA256 검증: $(basename "$file")"
  download_file "$sha256_url" "$sha256_file" \
    || { log "  WARN: .sha256 다운로드 실패 - 검증 스킵"; return 0; }
  local expected actual
  expected="$(awk '{print $1}' "$sha256_file")"
  actual="$(sha256sum "$file" | awk '{print $1}')"
  [ "$actual" = "$expected" ] \
    || die "SHA256 불일치: $(basename "$file")\n  기대: $expected\n  실제: $actual"
  log "  SHA256 OK"
}

# =============================================================================
# 소스 다운로드
# =============================================================================
download_sources() {
  log "소스 아카이브 다운로드"
  cd "$SRC"
  local entry file url sha256_url tmpfile
  local -a missing_files=()

  for entry in "${SOURCE_FILES[@]}"; do
    IFS='|' read -r file url sha256_url <<< "$entry"
    if [ -s "$file" ]; then
      log "SKIP (기존 파일): $file"
      verify_checksum "$file" "$sha256_url"
      continue
    fi
    tmpfile="${file}.part"
    rm -f "$tmpfile"
    log "DOWNLOAD: $file"
    if download_file "$url" "$tmpfile" && [ -s "$tmpfile" ]; then
      mv -f "$tmpfile" "$file"
      verify_checksum "$file" "$sha256_url"
      log "DOWNLOAD OK: $file"
    else
      rm -f "$tmpfile"
      log "DOWNLOAD FAILED: $file"
    fi
  done

  for entry in "${SOURCE_FILES[@]}"; do
    IFS='|' read -r file url sha256_url <<< "$entry"
    [ -s "$file" ] || missing_files+=("$file")
  done

  if [ "${#missing_files[@]}" -gt 0 ]; then
    printf '\n누락 파일:\n' >&2
    printf '  - %s\n' "${missing_files[@]}" >&2
    die "다운로드 오류로 빌드 중단"
  fi
  log "모든 소스 준비 완료"
}

# =============================================================================
# 빌드 환경 변수
# =============================================================================
prepare_env() {
  export CPPFLAGS="-I${DEPS_PREFIX}/include"
  export LDFLAGS="-L${DEPS_PREFIX}/lib \
-Wl,-rpath,\$ORIGIN/../bins/lib \
-Wl,-rpath,\$ORIGIN/../bins/lib64 \
-Wl,-rpath,\$ORIGIN/../../bins/lib \
-Wl,-rpath,\$ORIGIN/../../bins/lib64 \
-Wl,--disable-new-dtags"
  export PKG_CONFIG_PATH="${DEPS_PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
}

# =============================================================================
# 공통 압축 해제
# =============================================================================
clean_extract() {
  local archive="$1" dir="$2"
  cd "$WORK"
  rm -rf "$dir"
  tar xf "$SRC/$archive"
}

# =============================================================================
# 의존 라이브러리 빌드
# =============================================================================
build_zlib() {
  log "Building zlib-${ZLIB_VERSION}"
  clean_extract "zlib-${ZLIB_VERSION}.tar.gz" "zlib-${ZLIB_VERSION}"
  cd "$WORK/zlib-${ZLIB_VERSION}"
  ./configure --prefix="$DEPS_PREFIX" --shared >"$LOGS/zlib-configure.log" 2>&1
  make -j"$THREADS" >"$LOGS/zlib-make.log" 2>&1
  make install >"$LOGS/zlib-install.log" 2>&1
  rm -f "${DEPS_PREFIX}/lib/libz.a"
}

build_expat() {
  log "Building expat-${EXPAT_VERSION}"
  clean_extract "expat-${EXPAT_VERSION}.tar.xz" "expat-${EXPAT_VERSION}"
  cd "$WORK/expat-${EXPAT_VERSION}"
  ./configure \
    --prefix="$DEPS_PREFIX" \
    --enable-shared --disable-static \
    >"$LOGS/expat-configure.log" 2>&1
  make -j"$THREADS" >"$LOGS/expat-make.log" 2>&1
  make install >"$LOGS/expat-install.log" 2>&1
}

build_pcre2() {
  log "Building pcre2-${PCRE2_VERSION}"
  clean_extract "pcre2-${PCRE2_VERSION}.tar.gz" "pcre2-${PCRE2_VERSION}"
  cd "$WORK/pcre2-${PCRE2_VERSION}"
  ./configure \
    --prefix="$DEPS_PREFIX" \
    --enable-shared --disable-static --enable-jit \
    >"$LOGS/pcre2-configure.log" 2>&1
  make -j"$THREADS" >"$LOGS/pcre2-make.log" 2>&1
  make install >"$LOGS/pcre2-install.log" 2>&1
}

build_openssl() {
  log "Building openssl-${OPENSSL_VERSION}"
  clean_extract "openssl-${OPENSSL_VERSION}.tar.gz" "openssl-${OPENSSL_VERSION}"
  cd "$WORK/openssl-${OPENSSL_VERSION}"
  ./Configure \
    --prefix="$DEPS_PREFIX" \
    --openssldir="${DEPS_PREFIX}/ssl" \
    --libdir=lib \
    shared linux-x86_64 -O1 \
    >"$LOGS/openssl-configure.log" 2>&1
  make -j"$THREADS" >"$LOGS/openssl-make.log" 2>&1
  make install_sw >"$LOGS/openssl-install.log" 2>&1
}

build_nghttp2() {
  log "Building nghttp2-${NGHTTP2_VERSION}"
  clean_extract "nghttp2-${NGHTTP2_VERSION}.tar.xz" "nghttp2-${NGHTTP2_VERSION}"
  cd "$WORK/nghttp2-${NGHTTP2_VERSION}"
  ./configure \
    --prefix="$DEPS_PREFIX" \
    --enable-shared --disable-static --enable-lib-only \
    >"$LOGS/nghttp2-configure.log" 2>&1
  make -j"$THREADS" >"$LOGS/nghttp2-make.log" 2>&1
  make install >"$LOGS/nghttp2-install.log" 2>&1
}

build_apr() {
  log "Building apr-${APR_VERSION}"
  clean_extract "apr-${APR_VERSION}.tar.gz" "apr-${APR_VERSION}"
  cd "$WORK/apr-${APR_VERSION}"
  ./configure \
    --prefix="$DEPS_PREFIX" \
    --enable-shared --disable-static \
    >"$LOGS/apr-configure.log" 2>&1
  make -j"$THREADS" >"$LOGS/apr-make.log" 2>&1
  make install >"$LOGS/apr-install.log" 2>&1
}

build_apr_util() {
  log "Building apr-util-${APR_UTIL_VERSION}"
  clean_extract "apr-util-${APR_UTIL_VERSION}.tar.gz" "apr-util-${APR_UTIL_VERSION}"
  cd "$WORK/apr-util-${APR_UTIL_VERSION}"
  ./configure \
    --prefix="$DEPS_PREFIX" \
    --enable-shared --disable-static \
    --with-apr="${DEPS_PREFIX}" \
    --with-expat="${DEPS_PREFIX}" \
    --with-openssl="${DEPS_PREFIX}" \
    --with-crypto \
    >"$LOGS/apr-util-configure.log" 2>&1
  make -j"$THREADS" >"$LOGS/apr-util-make.log" 2>&1
  make install >"$LOGS/apr-util-install.log" 2>&1
}

build_httpd_with_mod_jk() {
  # ────────────────────────────────────────────────────────────────────────
  # Phase 1: Apache HTTP Server 빌드
  # ────────────────────────────────────────────────────────────────────────
  log "Building httpd-${HTTPD_VERSION}"
  clean_extract "httpd-${HTTPD_VERSION}.tar.gz" "httpd-${HTTPD_VERSION}"
  cd "$WORK/httpd-${HTTPD_VERSION}"
  ./configure \
    --prefix="$APACHE_PREFIX" \
    --enable-so \
    --enable-ssl \
    --enable-rewrite \
    --enable-deflate \
    --enable-headers \
    --enable-expires \
    --enable-proxy \
    --enable-proxy-http \
    --enable-proxy-balancer \
    --enable-proxy-connect \
    --enable-proxy-wstunnel \
    --enable-cache \
    --enable-cache-disk \
    --enable-remoteip \
    --enable-http2 \
    --enable-auth-digest \
    --enable-alias \
    --enable-dir \
    --enable-autoindex \
    --enable-status \
    --enable-info \
    --enable-log-config \
    --enable-logio \
    --enable-negotiation \
    --enable-filter \
    --enable-charset-lite \
    --enable-include \
    --enable-env \
    --enable-setenvif \
    --enable-vhost-alias \
    --enable-unique-id \
    --enable-request \
    --enable-session \
    --enable-slotmem-shm \
    --with-mpm=event \
    --with-apr="${DEPS_PREFIX}/bin/apr-1-config" \
    --with-apr-util="${DEPS_PREFIX}/bin/apu-1-config" \
    --with-pcre="${DEPS_PREFIX}/bin/pcre2-config" \
    --with-ssl="${DEPS_PREFIX}" \
    --with-z="${DEPS_PREFIX}" \
    --with-nghttp2="${DEPS_PREFIX}" \
    >"$LOGS/httpd-configure.log" 2>&1
  make -j"$THREADS" >"$LOGS/httpd-make.log" 2>&1
  make install >"$LOGS/httpd-install.log" 2>&1

  # ────────────────────────────────────────────────────────────────────────
  # Phase 2: mod_jk (Tomcat AJP Connector) 빌드 - 메인 빌드 흐름 통합
  # httpd 설치 완료 후 apxs 사용 가능 상태이므로 즉시 빌드
  # ────────────────────────────────────────────────────────────────────────
  log "Building mod_jk-${MOD_JK_VERSION}"
  clean_extract "tomcat-connectors-${MOD_JK_VERSION}-src.tar.gz" \
    "tomcat-connectors-${MOD_JK_VERSION}-src"
  cd "$WORK/tomcat-connectors-${MOD_JK_VERSION}-src/native"
  ./configure \
    --with-apxs="${APACHE_PREFIX}/bin/apxs" \
    >"$LOGS/mod_jk-configure.log" 2>&1
  make -j"$THREADS" >"$LOGS/mod_jk-make.log" 2>&1
  # make install 은 apxs -i -a 를 실행해 httpd.conf 에 LoadModule 을 활성 상태로 추가함
  # → post_layout() 에서 주석 처리로 제어하므로 직접 복사만 수행
  local jk_so
  jk_so="$(find "$WORK/tomcat-connectors-${MOD_JK_VERSION}-src" -name 'mod_jk.so' | head -1)"
  [ -n "${jk_so}" ] || die "mod_jk.so 빌드 결과를 찾을 수 없음"
  cp "${jk_so}" "${APACHE_PREFIX}/modules/mod_jk.so"
  log "mod_jk.so 설치 완료: ${APACHE_PREFIX}/modules/mod_jk.so"
}

# [v3.0에서 제거됨] build_httpd_with_mod_jk()에 통합됨
# build_mod_jk() {
#   log "Building mod_jk-${MOD_JK_VERSION}"
#   ...
# }

# =============================================================================
# patchelf: RPATH 재작성
# =============================================================================
fix_rpath_so_files() {
  log "patchelf: RPATH 재작성"
  local so_file bin_file

  while IFS= read -r -d '' so_file; do
    patchelf --force-rpath --set-rpath '$ORIGIN/../bins/lib:$ORIGIN/../bins/lib64' "$so_file" \
      && log "  patched: $(basename "$so_file")" \
      || log "  WARN: patchelf 실패: $so_file"
  done < <(find "${APACHE_PREFIX}/modules" -name '*.so' -print0 2>/dev/null)

  while IFS= read -r -d '' so_file; do
    patchelf --force-rpath --set-rpath '$ORIGIN:$ORIGIN/../lib64' "$so_file" \
      && log "  patched: $(basename "$so_file")" \
      || log "  WARN: patchelf 실패: $so_file"
  done < <(find "${DEPS_PREFIX}/lib" -maxdepth 1 -name '*.so*' ! -type d -print0 2>/dev/null)

  while IFS= read -r -d '' bin_file; do
    file "$bin_file" | grep -q 'ELF' || continue
    patchelf --force-rpath --set-rpath '$ORIGIN/../bins/lib:$ORIGIN/../bins/lib64' "$bin_file" \
      && log "  patched: $(basename "$bin_file")" \
      || log "  WARN: patchelf 실패: $bin_file"
  done < <(find "${APACHE_PREFIX}/bin" -maxdepth 1 -type f -print0 2>/dev/null)
}

# =============================================================================
# 시스템 라이브러리 번들
# =============================================================================
bundle_system_libs() {
  log "시스템 라이브러리 번들"
  local GLIBC_EXCLUDE="^(libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libutil\.so|libnsl\.so|libresolv\.so|libgcc_s\.so|ld-linux|ld-)"

  local libcrypt_src
  libcrypt_src="$(ldconfig -p | awk '/libcrypt\.so\.1[[:space:]]/{print $NF}' | head -1)"
  if [ -n "$libcrypt_src" ] && [ -f "$libcrypt_src" ]; then
    cp -fL "$libcrypt_src" "${DEPS_PREFIX}/lib/libcrypt.so.1"
    log "  번들: libcrypt.so.1 ← $libcrypt_src"
  else
    log "  WARN: libcrypt.so.1 시스템에서 찾을 수 없음"
  fi

  local missing_lib found_path
  while IFS= read -r missing_lib; do
    if [[ "$(basename "$missing_lib")" =~ $GLIBC_EXCLUDE ]]; then
      log "  SKIP (glibc 계열): $missing_lib"
      continue
    fi
    found_path="$(ldconfig -p | awk -v lib="$missing_lib" 'index($0,lib) && /=>/{print $NF}' | head -1)"
    if [ -n "$found_path" ] && [ -f "$found_path" ]; then
      cp -fL "$found_path" "${DEPS_PREFIX}/lib/$(basename "$found_path")"
      log "  번들: $missing_lib ← $found_path"
    else
      log "  WARN: 번들 불가 (시스템에도 없음): $missing_lib"
    fi
  done < <(
    LD_LIBRARY_PATH="${DEPS_PREFIX}/lib" \
    find "$APACHE_PREFIX" -type f | \
    xargs -r ldd 2>/dev/null | \
    awk '/[[:space:]]not found/{print $1}' | \
    sort -u
  )
}

# =============================================================================
# 패키지 레이아웃 및 관리 스크립트 생성
# =============================================================================
post_layout() {
  log "패키지 레이아웃 정리"
  mkdir -p "$APACHE_PREFIX/run" "$APACHE_PREFIX/logs"

  local conf="$APACHE_PREFIX/conf/httpd.conf"
  if [ -f "$conf" ]; then
    if grep -qE '^LoadModule session_(cookie|crypto|dbd)_module' "$conf"; then
      sed -i 's|^#\(LoadModule session_module\)|\1|' "$conf"
    fi
  fi

  # mod_jk httpd.conf 블록 추가 (주석 처리)
  if [ -f "$APACHE_PREFIX/modules/mod_jk.so" ]; then
    if ! grep -q 'mod_jk' "$conf"; then
      cat >> "$conf" <<'MODJK'

# ── mod_jk (Tomcat AJP Connector) ────────────────────────────────────────────
#LoadModule jk_module modules/mod_jk.so
#JkWorkersFile conf/workers.properties
#JkLogFile logs/mod_jk.log
#JkLogLevel info
#JkMount /app/* worker1
#JkMount /manager/* worker1
MODJK
      log "  httpd.conf: mod_jk 설정 블록 추가 (주석 처리)"
    fi

    cat > "$APACHE_PREFIX/conf/workers.properties.minimal" <<'WORKERS'
worker.list=worker1
worker.worker1.type=ajp13
worker.worker1.host=127.0.0.1
worker.worker1.port=8009
worker.worker1.connection_pool_size=10
worker.worker1.connect_timeout=5000
worker.worker1.reply_timeout=300000
WORKERS
    log "  conf/workers.properties.minimal 생성"
  fi

  [ -d "$DEPS_PREFIX/lib64" ] && [ ! -e "$DEPS_PREFIX/lib"   ] && ln -s lib64 "$DEPS_PREFIX/lib"
  [ -d "$DEPS_PREFIX/lib"   ] && [ ! -e "$DEPS_PREFIX/lib64" ] && ln -s lib   "$DEPS_PREFIX/lib64"

  # env.sh
  cat > "$APACHE_PREFIX/bin/env.sh" <<'EOS'
#!/usr/bin/env sh
set -eu

APP_BIN_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_HOME="$(CDPATH= cd -- "${APP_BIN_DIR}/.." && pwd)"

export APP_HOME
export LD_LIBRARY_PATH="${APP_HOME}/bins/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export PATH="${APP_HOME}/bin:${APP_HOME}/bins/bin${PATH:+:${PATH}}"
EOS
  chmod 755 "$APACHE_PREFIX/bin/env.sh"

  # relocate_apache_paths.sh
  local compile_home="${APACHE_PREFIX}"
  cat > "$APACHE_PREFIX/bin/relocate_apache_paths.sh" <<EOS
#!/usr/bin/env sh
set -eu

APP_BIN_DIR="\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)"
APP_HOME="\$(CDPATH= cd -- "\${APP_BIN_DIR}/.." && pwd)"
APP_BASE="\$(dirname "\${APP_HOME}")"
COMPILE_HOME="${compile_home}"
COMPILE_BASE="\$(dirname "\${COMPILE_HOME}")"
CONF_FILE="\${APP_HOME}/conf/httpd.conf"
RUN_DIR="\${APP_HOME}/run"
LOG_DIR="\${APP_HOME}/logs"
HTDOCS_DIR="\${APP_HOME}/htdocs"
MARKER_FILE="\${RUN_DIR}/.relocate_apache_paths.done"
STATE_FILE="\${RUN_DIR}/.relocate_apache_paths.home"
FORCE_RELOCATE="\${FORCE_RELOCATE:-0}"

TARGET_DIRS="\${APP_HOME}/bin \${APP_HOME}/bins \${APP_HOME}/conf \${APP_HOME}/modules"

[ -x "\${APP_HOME}/bin/httpd" ] || { echo "ERROR: httpd 없음: \${APP_HOME}/bin/httpd" >&2; exit 1; }
[ -f "\${CONF_FILE}" ] || { echo "ERROR: httpd.conf 없음: \${CONF_FILE}" >&2; exit 1; }
mkdir -p "\${LOG_DIR}" "\${RUN_DIR}"

PREV_HOME=""
[ -f "\${STATE_FILE}" ] && PREV_HOME="\$(cat "\${STATE_FILE}" 2>/dev/null || true)"

if [ "\${FORCE_RELOCATE}" != "1" ] && [ -f "\${MARKER_FILE}" ]; then
  if [ -z "\${PREV_HOME}" ] || [ "\${PREV_HOME}" = "\${APP_HOME}" ]; then
    echo "INFO: relocate 완료됨. 강제 재실행: FORCE_RELOCATE=1"
    exit 0
  fi
fi

TMP_TEXT_LIST="\$(mktemp "\${RUN_DIR}/.relocate_textfiles.XXXXXX")"
trap 'rm -f "\${TMP_TEXT_LIST}"' EXIT INT TERM
: > "\${TMP_TEXT_LIST}"

for dir in \${TARGET_DIRS}; do
  [ -d "\${dir}" ] || continue
  grep -IlR . "\${dir}" \
    --exclude='*.so' --exclude='*.so.*' --exclude='*.a' \
    --exclude='*.o' --exclude='*.la' --exclude='*.pyc' \
    --exclude='*.pem' --exclude='*.crt' --exclude='*.key' \
    --exclude='*.der' --exclude='*.p12' --exclude='*.gz' \
    --exclude='*.xz' --exclude='*.zip' \
    >> "\${TMP_TEXT_LIST}" 2>/dev/null || true
done

sort -u "\${TMP_TEXT_LIST}" -o "\${TMP_TEXT_LIST}" 2>/dev/null || true

replace_path() {
  old_path="\$1"
  new_path="\$2"
  [ -n "\${old_path}" ] || return 0
  [ "\${old_path}" != "\${new_path}" ] || return 0
  [ -s "\${TMP_TEXT_LIST}" ] || return 0

  echo "  치환: '\${old_path}' → '\${new_path}'"
  while IFS= read -r fpath; do
    [ -n "\${fpath}" ] || continue
    OLD_PATH="\${old_path}" NEW_PATH="\${new_path}" \
      perl -0pi -e 'BEGIN{\$old=\$ENV{OLD_PATH};\$new=\$ENV{NEW_PATH}} s/\Q\$old\E/\$new/g' \
      "\${fpath}" 2>/dev/null || true
  done < "\${TMP_TEXT_LIST}"
}

replace_conf_path() {
  old_path="\$1"
  new_path="\$2"
  [ -n "\${old_path}" ] || return 0
  [ "\${old_path}" != "\${new_path}" ] || return 0

  OLD_PATH="\${old_path}" NEW_PATH="\${new_path}" \
    perl -0pi -e 'BEGIN{\$old=\$ENV{OLD_PATH};\$new=\$ENV{NEW_PATH}} s/\Q\$old\E/\$new/g' \
    "\${CONF_FILE}" 2>/dev/null || true
}

update_directive() {
  key="\$1"
  val="\$2"
  KEY="\${key}" VAL="\${val}" \
    perl -0pi -e '
      BEGIN { \$k=\$ENV{KEY}; \$v=\$ENV{VAL}; }
      if (s/^[#\s]*\Q\$k\E\s+.*\$/\$k \$v/m) { }
      else { \$_ .= "\n\$k \$v\n"; }
    ' "\${CONF_FILE}"
}

echo "INFO: relocate 시작 → \${APP_HOME}"
replace_path "\${COMPILE_HOME}" "\${APP_HOME}"
replace_path "\${COMPILE_BASE}" "\${APP_BASE}"
if [ -n "\${PREV_HOME}" ] && [ "\${PREV_HOME}" != "\${APP_HOME}" ]; then
  replace_path "\${PREV_HOME}" "\${APP_HOME}"
  PREV_BASE="\$(dirname "\${PREV_HOME}")"
  replace_path "\${PREV_BASE}" "\${APP_BASE}"
fi

update_directive "ServerRoot" "\"\${APP_HOME}\""
update_directive "DefaultRuntimeDir" "\"\${APP_HOME}/run\""
update_directive "PidFile" "\"\${APP_HOME}/logs/httpd.pid\""
update_directive "ErrorLog" "\"\${APP_HOME}/logs/error_log\""
update_directive "DocumentRoot" "\"\${HTDOCS_DIR}\""

replace_conf_path "\${COMPILE_HOME}/htdocs" "\${HTDOCS_DIR}"
replace_conf_path "\${COMPILE_BASE}/htdocs" "\${HTDOCS_DIR}"
if [ -n "\${PREV_HOME}" ] && [ "\${PREV_HOME}" != "\${APP_HOME}" ]; then
  replace_conf_path "\${PREV_HOME}/htdocs" "\${HTDOCS_DIR}"
  PREV_BASE="\$(dirname "\${PREV_HOME}")"
  replace_conf_path "\${PREV_BASE}/htdocs" "\${HTDOCS_DIR}"
fi

if grep -qE '^[#[:space:]]*ServerName[[:space:]]' "\${CONF_FILE}"; then
  perl -0pi -e 's/^[#\s]*ServerName\s+.*\$/ServerName localhost/m' "\${CONF_FILE}"
else
  printf 'ServerName localhost\n' >> "\${CONF_FILE}"
fi

if grep -qE '^LoadModule session_(cookie|crypto|dbd)_module' "\${CONF_FILE}"; then
  if grep -qE '^#LoadModule session_module' "\${CONF_FILE}"; then
    perl -0pi -e 's/^#(LoadModule session_module)/\$1/m' "\${CONF_FILE}"
    echo "INFO: mod_session 활성화 (session_cookie/crypto/dbd 의존성 해결)"
  fi
fi

printf '%s\n' "\${APP_HOME}" > "\${STATE_FILE}"
touch "\${MARKER_FILE}"

echo "INFO: httpd 설정 검증..."
"\${APP_HOME}/bin/httpd" -d "\${APP_HOME}" -f "\${CONF_FILE}" -t \
  && echo "INFO: 설정 OK" \
  || { echo "ERROR: httpd -t 실패. \${APP_HOME}/logs/error_log 확인" >&2; exit 1; }
EOS
  chmod 755 "$APACHE_PREFIX/bin/relocate_apache_paths.sh"

  # start.sh
  cat > "$APACHE_PREFIX/bin/start.sh" <<'EOS'
#!/usr/bin/env sh
set -eu

APP_BIN_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_HOME="$(CDPATH= cd -- "${APP_BIN_DIR}/.." && pwd)"

. "${APP_HOME}/bin/env.sh"
"${APP_HOME}/bin/relocate_apache_paths.sh"
cd "${APP_HOME}"
exec "${APP_HOME}/bin/httpd" -d "${APP_HOME}" -f "${APP_HOME}/conf/httpd.conf" -k start "$@"
EOS
  chmod 755 "$APACHE_PREFIX/bin/start.sh"

  # stop.sh
  cat > "$APACHE_PREFIX/bin/stop.sh" <<'EOS'
#!/usr/bin/env sh
set -eu

APP_BIN_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_HOME="$(CDPATH= cd -- "${APP_BIN_DIR}/.." && pwd)"

. "${APP_HOME}/bin/env.sh"
exec "${APP_HOME}/bin/httpd" -d "${APP_HOME}" -f "${APP_HOME}/conf/httpd.conf" -k stop "$@"
EOS
  chmod 755 "$APACHE_PREFIX/bin/stop.sh"

  # restart.sh
  cat > "$APACHE_PREFIX/bin/restart.sh" <<'EOS'
#!/usr/bin/env sh
set -eu

APP_BIN_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_HOME="$(CDPATH= cd -- "${APP_BIN_DIR}/.." && pwd)"

. "${APP_HOME}/bin/env.sh"
exec "${APP_HOME}/bin/httpd" -d "${APP_HOME}" -f "${APP_HOME}/conf/httpd.conf" -k graceful "$@"
EOS
  chmod 755 "$APACHE_PREFIX/bin/restart.sh"

  # status.sh
  cat > "$APACHE_PREFIX/bin/status.sh" <<'EOS'
#!/usr/bin/env sh
set -eu

APP_BIN_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_HOME="$(CDPATH= cd -- "${APP_BIN_DIR}/.." && pwd)"
PID_FILE="${APP_HOME}/logs/httpd.pid"

if [ -f "${PID_FILE}" ]; then
  PID="$(cat "${PID_FILE}")"
  if ps -p "${PID}" >/dev/null 2>&1; then
    echo "Apache 실행 중 (PID: ${PID})"
    exit 0
  fi
fi
echo "Apache 중지됨"
exit 1
EOS
  chmod 755 "$APACHE_PREFIX/bin/status.sh"

  # README.txt
  cat > "$APACHE_PREFIX/README.txt" <<EOS
Apache HTTP Server ${HTTPD_VERSION} - Portable Build
=====================================================
빌드일시  : $(date '+%F %T')
컴파일경로: ${APACHE_PREFIX}
빌드방식  : Native (컨테이너 없이 직접 빌드)

[포함 구성요소]
  httpd    ${HTTPD_VERSION}   APR      ${APR_VERSION}
  APR-util ${APR_UTIL_VERSION}  OpenSSL  ${OPENSSL_VERSION}
  PCRE2    ${PCRE2_VERSION}    zlib     ${ZLIB_VERSION}
  expat    ${EXPAT_VERSION}  nghttp2  ${NGHTTP2_VERSION}
  mod_jk   ${MOD_JK_VERSION}  (Tomcat AJP Connector, 기본 비활성)

[사용법]
  bin/start.sh       Apache 시작
  bin/stop.sh        Apache 중지
  bin/restart.sh     Apache 재시작 (graceful)
  bin/status.sh      실행 상태 확인
EOS
}

# =============================================================================
# 검증
# =============================================================================
verify() {
  log "빌드 결과 검증"
  export LD_LIBRARY_PATH="${DEPS_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

  "$APACHE_PREFIX/bin/httpd" -v 2>&1 | tee "$LOGS/verify-httpd-version.log"
  "$APACHE_PREFIX/bin/httpd" -V 2>&1 | tee "$LOGS/verify-httpd-build.log"
  "$APACHE_PREFIX/bin/httpd" -M 2>&1 | tee "$LOGS/verify-httpd-modules.log" || true
  ldd "$APACHE_PREFIX/bin/httpd" 2>&1 | tee "$LOGS/verify-ldd-httpd.log"   || true

  [ -f "$APACHE_PREFIX/modules/mod_ssl.so" ] \
    && ldd "$APACHE_PREFIX/modules/mod_ssl.so" 2>&1 | tee "$LOGS/verify-ldd-mod_ssl.log" || true

  if grep -q 'not found' "$LOGS/verify-ldd-httpd.log" 2>/dev/null; then
    log "ERROR: 누락된 공유 라이브러리 존재:"
    grep 'not found' "$LOGS/verify-ldd-httpd.log" >&2
    die "번들되지 않은 라이브러리가 남아 있습니다."
  else
    log "의존 라이브러리 확인 OK"
  fi
}

# =============================================================================
# 작업 디렉터리 정리
# =============================================================================
cleanup_work() {
  if [ "${CLEAN_WORK_AFTER_BUILD:-1}" = "1" ]; then
    log "작업 디렉터리 삭제: $WORK"
    rm -rf "$WORK"
  fi
}

# =============================================================================
# 최종 아카이브
# =============================================================================
package_output() {
  log "최종 아카이브 생성"
  cd "$PKG"
  rm -f "$OUT_TAR"
  tar czf "$OUT_TAR" apache
  local size
  size="$(du -sh "$OUT_TAR" | awk '{print $1}')"
  log "아카이브 완료: $OUT_TAR (${size})"
}

# =============================================================================
# 빌드 환경 정보 출력
# =============================================================================
print_build_info() {
  log "=============================="
  log "빌드 환경"
  log "  OS     : $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME}" || uname -r)"
  log "  ARCH   : $(uname -m)"
  log "  glibc  : $(ldd --version 2>/dev/null | awk 'NR==1{print $NF}')"
  log "  GCC    : $(gcc --version | head -1)"
  log "  Threads: ${THREADS}"
  log "  httpd  : ${HTTPD_VERSION}"
  log "  OpenSSL: ${OPENSSL_VERSION}"
  log "  APR    : ${APR_VERSION} / APR-util: ${APR_UTIL_VERSION}"
  log "  mod_jk : ${MOD_JK_VERSION}"
  log "  BUILD  : ${BUILD_BASE}"
  log "  OUTPUT : ${OUT_TAR}"
  log "=============================="
}

# =============================================================================
# main
# =============================================================================
main() {
  require_cmd curl
  require_cmd tar

  check_os_compat
  prepare_build_tools
  prepare_dirs
  print_build_info
  download_sources
  prepare_env
  build_zlib
  build_expat
  build_pcre2
  build_openssl
  build_nghttp2
  build_apr
  build_apr_util
  build_httpd_with_mod_jk
  # build_mod_jk (통합됨)
  post_layout
  fix_rpath_so_files
  bundle_system_libs
  verify
  cleanup_work
  package_output

  log "=============================="
  log "빌드 완료: ${OUT_TAR}"
  log "=============================="
}

main "$@"

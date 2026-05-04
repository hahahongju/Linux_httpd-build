#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Apache HTTP Server 2.4.66 Portable Build Script
# Target OS : Rocky Linux 8/9 (x86_64)
# Release   : 2026-04-10 (v6)
# =============================================================================
# [변경 이력]
# v2.0 (2024)  : 최초 보완판 - patchelf, SHA256, 빈배열 버그 수정 등
# v2.1         : 2.4.66 GA 반영
#                - HTTPD 2.4.66 / OpenSSL 3.0.17 버전 확정
#                - SHA256 체크섬을 원격 .sha256 파일로 동적 검증
#                - COMPILE_HOME 경로 수정
# v3.0         : 이식성 버그 수정
#                - DT_RUNPATH → DT_RPATH 변경 (--disable-new-dtags + --force-rpath)
#                  LD_LIBRARY_PATH 환경변수가 번들 라이브러리를 덮어쓰는 문제 해결
#                  (undefined symbol: apr_crypto_shutdown 오류 원인)
#                - libcrypt.so.1 번들 추가 및 ldd 기반 누락 라이브러리 자동 감지/번들
#                  (libcrypt.so.1: cannot open shared object file 오류 원인)
#                - 빌드 후 ldd not found 시 오류로 중단 (경고→오류 격상)
# v3.1         : mod_jk 1.2.50 추가
#                - Tomcat AJP 연동 대비 mod_jk.so 번들 (LoadModule 주석 처리 기본)
#                - conf/workers.properties.minimal 샘플 포함
# v4.0 (2026-04-09): 런타임 스크립트 이식성 개선 (AWX sh 실행 이슈 대응)
#                - relocate_apache_paths.sh: sh 실행 시 Bash 전용 문법 충돌(45행 syntax) 원인 제거
#                  → bash 배열/프로세스 치환 → mktemp 파일 기반으로 교체
#                - env/start/stop/restart/status 스크립트 #!/usr/bin/env sh 전환
#                - AWX 역할 호출부 sh→bash 통일 대응
#                - DocumentRoot/htdocs 리로케이션 보강
#                  (COMPILE_BASE/PREV_BASE/PREV_HOME 경로까지 처리)
#                - sed -i 의존 제거 → Perl 치환(GNU/BSD sed 차이 회피)
#                - 검증 결과물: compiled-local-improved-20260409.tar.gz
# v5.0 (2026-04-10): OpenSSL 3.5.6 업그레이드
#                - OpenSSL 3.0.17 → 3.5.6 (LTS, 2025-04 릴리즈)
#                - GLIBC 호환성 유지: Rocky 8 컨테이너(glibc 2.28) 빌드 → RHEL 8+ 배포 가능
#                - 빌드 플래그 동일: ./Configure linux-x86_64 shared -O1
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

# ── 경로 설정 ──────────────────────────────────────────────────────────────
BASE="/Product/httpd-${HTTPD_VERSION}-build"
SRC="${BASE}/sources"
WORK="${BASE}/work"
PKG="${BASE}/package"
LOGS="${BASE}/logs"
APACHE_PREFIX="${PKG}/apache"
DEPS_PREFIX="${APACHE_PREFIX}/bins"
OUT_TAR="${BASE}/httpd-${HTTPD_VERSION}-glibc2.25-compiled-v6.tar.gz"

# ── 빌드 옵션 ──────────────────────────────────────────────────────────────
THREADS="$(nproc)"
CLEAN_WORK_AFTER_BUILD="${CLEAN_WORK_AFTER_BUILD:-1}"
# 1=원격 .sha256 파일로 검증 / 0=스킵
VERIFY_CHECKSUM="${VERIFY_CHECKSUM:-1}"

# =============================================================================
# 소스 파일 목록
# 형식: "파일명|다운로드URL|SHA256파일URL(없으면-)"
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

DOWNLOAD_RETRY=3
DOWNLOAD_CONNECT_TIMEOUT=20
DOWNLOAD_MAX_TIME=1800

# =============================================================================
# 유틸리티 함수
# =============================================================================
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "필수 명령어 없음: $1"; }

# =============================================================================
# 빌드 도구 설치
# =============================================================================
prepare_build_tools() {
  log "빌드 툴체인 설치"
  sudo dnf groupinstall -y "Development Tools"
  sudo dnf install -y \
    wget curl tar gzip xz bzip2 \
    perl make which file diffutils findutils \
    grep sed gawk

  # patchelf: Rocky 8 기본 repo에 없으므로 EPEL에서 설치
  if ! command -v patchelf >/dev/null 2>&1; then
    log "patchelf EPEL 설치 시도"
    sudo dnf install -y epel-release 2>/dev/null || true
    sudo dnf install -y patchelf 2>/dev/null || {
      log "EPEL 실패 → patchelf 소스 빌드"
      local _pe_ver="0.18.0"
      local _pe_url="https://github.com/NixOS/patchelf/releases/download/${_pe_ver}/patchelf-${_pe_ver}.tar.bz2"
      curl -fSL "$_pe_url" -o /tmp/patchelf.tar.bz2
      tar -xjf /tmp/patchelf.tar.bz2 -C /tmp
      ( cd /tmp/patchelf-${_pe_ver} && ./configure --prefix=/usr/local && make -j"$(nproc)" && sudo make install )
    }
  fi

  for cmd in curl tar make gcc patchelf perl; do
    require_cmd "$cmd"
  done
}

# =============================================================================
# 디렉터리 생성
# =============================================================================
prepare_dirs() {
  log "디렉터리 구조 생성"
  mkdir -p "$SRC" "$WORK" "$PKG" "$LOGS" "$APACHE_PREFIX" "$DEPS_PREFIX"
}

# =============================================================================
# 다운로드 헬퍼 (재시도 포함)
# =============================================================================
download_file() {
  local url="$1"
  local out="$2"
  curl -fL \
    --retry "$DOWNLOAD_RETRY" \
    --retry-delay 2 \
    --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" \
    --max-time "$DOWNLOAD_MAX_TIME" \
    -o "$out" "$url"
}

# =============================================================================
# SHA256 검증
# sha256 파일 URL이 '-' 이면 스킵 (GitHub 소스는 공식 .sha256 미제공)
# =============================================================================
verify_checksum() {
  local file="$1"
  local sha256_url="$2"

  if [ "$VERIFY_CHECKSUM" != "1" ] || [ "$sha256_url" = "-" ]; then
    return 0
  fi

  local sha256_file="${file}.sha256"
  log "  SHA256 파일 다운로드: ${sha256_url}"
  download_file "$sha256_url" "$sha256_file" \
    || { log "  WARN: .sha256 다운로드 실패 - 검증 스킵: $file"; return 0; }

  # sha256 파일 첫 번째 토큰(해시값) 추출
  local expected
  expected="$(awk '{print $1}' "$sha256_file")"

  local actual
  actual="$(sha256sum "$file" | awk '{print $1}')"

  if [ "$actual" = "$expected" ]; then
    log "  SHA256 OK: $file"
  else
    die "SHA256 불일치: $file\n  기대: $expected\n  실제: $actual"
  fi
}

# =============================================================================
# 소스 다운로드
# =============================================================================
download_sources() {
  log "소스 아카이브 다운로드"
  cd "$SRC"

  local entry file url sha256_url tmpfile
  local -a failed_downloads=()
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
      failed_downloads+=("$file")
      log "DOWNLOAD FAILED: $file"
    fi
  done

  for entry in "${SOURCE_FILES[@]}"; do
    IFS='|' read -r file url sha256_url <<< "$entry"
    [ -s "$file" ] || missing_files+=("$file")
  done

  if [ "${#failed_downloads[@]}" -gt 0 ]; then
    printf '\n다운로드 실패:\n' >&2
    printf '  - %s\n' "${failed_downloads[@]}" >&2
  fi

  if [ "${#missing_files[@]}" -gt 0 ]; then
    printf '\n누락 파일:\n' >&2
    printf '  - %s\n' "${missing_files[@]}" >&2
    die "다운로드 오류로 빌드 중단"
  fi

  log "모든 소스 준비 완료"
}

# =============================================================================
# 빌드 환경 변수
# ※ LD_LIBRARY_PATH 는 빌드 중 설정하지 않음
#   → 설정 시 시스템 도구(pkg-config, rpm 등)가 우리 OpenSSL을 로드해
#     "version OPENSSL_3.x not found" 충돌 발생
#   → 런타임에만 필요하므로 verify() 및 관리 스크립트에서만 설정
# =============================================================================
prepare_env() {
  export CPPFLAGS="-I${DEPS_PREFIX}/include"
  export LDFLAGS="-L${DEPS_PREFIX}/lib \
-Wl,-rpath,\$ORIGIN/../bins/lib \
-Wl,-rpath,\$ORIGIN/../bins/lib64 \
-Wl,-rpath,\$ORIGIN/../../bins/lib \
-Wl,-rpath,\$ORIGIN/../../bins/lib64 \
-Wl,--disable-new-dtags"
  # PKG_CONFIG_PATH: 우리가 빌드한 라이브러리 우선 탐색
  export PKG_CONFIG_PATH="${DEPS_PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
  # LD_LIBRARY_PATH 는 의도적으로 미설정 (시스템 OpenSSL 충돌 방지)
}

# =============================================================================
# 공통 압축 해제
# =============================================================================
clean_extract() {
  local archive="$1"
  local dir="$2"
  cd "$WORK"
  rm -rf "$dir"
  tar xf "$SRC/$archive"
}

# =============================================================================
# 의존 라이브러리 빌드
# autoconf 계열: --disable-static / OpenSSL: shared 만 사용 (no-static 없음)
# =============================================================================
build_zlib() {
  log "Building zlib-${ZLIB_VERSION}"
  clean_extract "zlib-${ZLIB_VERSION}.tar.gz" "zlib-${ZLIB_VERSION}"
  cd "$WORK/zlib-${ZLIB_VERSION}"
  ./configure \
    --prefix="$DEPS_PREFIX" \
    --shared \
    >"$LOGS/zlib-configure.log" 2>&1
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
    --enable-shared \
    --disable-static \
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
    --enable-shared \
    --disable-static \
    --enable-jit \
    >"$LOGS/pcre2-configure.log" 2>&1
  make -j"$THREADS" >"$LOGS/pcre2-make.log" 2>&1
  make install >"$LOGS/pcre2-install.log" 2>&1
}

build_openssl() {
  log "Building openssl-${OPENSSL_VERSION}"
  clean_extract "openssl-${OPENSSL_VERSION}.tar.gz" "openssl-${OPENSSL_VERSION}"
  cd "$WORK/openssl-${OPENSSL_VERSION}"
  # OpenSSL Configure 는 autoconf 미사용
  # 'shared' 만으로 공유 라이브러리 빌드 활성화 (no-static 옵션 없음)
  # install_sw: 소프트웨어 바이너리/라이브러리/헤더만 설치 (man 페이지 제외)
  ./Configure \
    --prefix="$DEPS_PREFIX" \
    --openssldir="${DEPS_PREFIX}/ssl" \
    --libdir=lib \
    shared \
    linux-x86_64 \
    -O1 \
    >"$LOGS/openssl-configure.log" 2>&1
  make -j"$THREADS" >"$LOGS/openssl-make.log" 2>&1
  make install_sw >"$LOGS/openssl-install.log" 2>&1
}

build_nghttp2() {
  log "Building nghttp2-${NGHTTP2_VERSION}"
  clean_extract "nghttp2-${NGHTTP2_VERSION}.tar.xz" "nghttp2-${NGHTTP2_VERSION}"
  cd "$WORK/nghttp2-${NGHTTP2_VERSION}"
  # --enable-lib-only: 라이브러리만 빌드 (nghttpd/nghttpx 등 바이너리 제외)
  # pkg-config 는 PKG_CONFIG_PATH 를 통해 우리 OpenSSL/zlib을 찾음
  ./configure \
    --prefix="$DEPS_PREFIX" \
    --enable-shared \
    --disable-static \
    --enable-lib-only \
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
    --enable-shared \
    --disable-static \
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
    --enable-shared \
    --disable-static \
    --with-apr="${DEPS_PREFIX}" \
    --with-expat="${DEPS_PREFIX}" \
    --with-openssl="${DEPS_PREFIX}" \
    --with-crypto \
    >"$LOGS/apr-util-configure.log" 2>&1
  make -j"$THREADS" >"$LOGS/apr-util-make.log" 2>&1
  make install >"$LOGS/apr-util-install.log" 2>&1
}

build_httpd() {
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
}

build_mod_jk() {
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

# =============================================================================
# patchelf: RPATH 절대경로 → $ORIGIN 상대경로
# =============================================================================
fix_rpath_so_files() {
  log "patchelf: RPATH 재작성"

  local so_file bin_file

  # modules/*.so
  while IFS= read -r -d '' so_file; do
    patchelf --force-rpath --set-rpath '$ORIGIN/../bins/lib:$ORIGIN/../bins/lib64' "$so_file" \
      && log "  patched: $(basename "$so_file")" \
      || log "  WARN: patchelf 실패: $so_file"
  done < <(find "${APACHE_PREFIX}/modules" -name '*.so' -print0 2>/dev/null)

  # bins/lib/*.so
  while IFS= read -r -d '' so_file; do
    patchelf --force-rpath --set-rpath '$ORIGIN:$ORIGIN/../lib64' "$so_file" \
      && log "  patched: $(basename "$so_file")" \
      || log "  WARN: patchelf 실패: $so_file"
  done < <(find "${DEPS_PREFIX}/lib" -maxdepth 1 -name '*.so*' ! -type d -print0 2>/dev/null)

  # bin/ 실행 파일
  while IFS= read -r -d '' bin_file; do
    file "$bin_file" | grep -q 'ELF' || continue
    patchelf --force-rpath --set-rpath '$ORIGIN/../bins/lib:$ORIGIN/../bins/lib64' "$bin_file" \
      && log "  patched: $(basename "$bin_file")" \
      || log "  WARN: patchelf 실패: $bin_file"
  done < <(find "${APACHE_PREFIX}/bin" -maxdepth 1 -type f -print0 2>/dev/null)
}

# =============================================================================
# 시스템 라이브러리 번들
# - libcrypt.so.1: APR/APR-util 의존성. Rocky 8은 libxcrypt 패키지 제공.
#   RHEL 7 이상 glibc 2.17+ 환경에서 안전하게 번들 가능.
# - ldd 기반 자동 탐지: 번들 후에도 not found 남은 라이브러리를 시스템에서 복사.
#   단, glibc 내장 라이브러리(libc/libm/libdl 등)는 타겟 시스템 버전과
#   반드시 일치해야 하므로 번들 제외.
# =============================================================================
bundle_system_libs() {
  log "시스템 라이브러리 번들"

  # glibc 내장 라이브러리 - 번들 불가 (타겟 시스템 버전 의존)
  # 주의: libc 는 prefix 매칭이 아닌 정확한 소나임 매칭 필요 (libcrypto 등과 구분)
  local GLIBC_EXCLUDE="^(libc\.so|libm\.so|libdl\.so|libpthread\.so|librt\.so|libutil\.so|libnsl\.so|libresolv\.so|libgcc_s\.so|ld-linux|ld-)"

  # libcrypt.so.1 명시적 번들 (가장 흔한 누락 라이브러리)
  local libcrypt_src
  libcrypt_src="$(ldconfig -p | awk '/libcrypt\.so\.1[[:space:]]/{print $NF}' | head -1)"
  if [ -n "$libcrypt_src" ] && [ -f "$libcrypt_src" ]; then
    cp -fL "$libcrypt_src" "${DEPS_PREFIX}/lib/libcrypt.so.1"
    log "  번들: libcrypt.so.1 ← $libcrypt_src"
  else
    log "  WARN: libcrypt.so.1 시스템에서 찾을 수 없음"
  fi

  # ldd 전수 검사 → not found 라이브러리 자동 번들
  # LD_LIBRARY_PATH=bins/lib 를 설정해 이미 번들된 라이브러리(libssl, libcrypto 등)를
  # "not found"로 오탐하지 않도록 함
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

  # ── httpd.conf 모듈 의존성 수정 ───────────────────────────────────────────
  # mod_session_cookie/crypto/dbd 는 mod_session 이 먼저 로드되어야 함.
  # make install 후 기본 conf 에서 mod_session 이 주석 처리되는 경우를 수정.
  local conf="$APACHE_PREFIX/conf/httpd.conf"
  if [ -f "$conf" ]; then
    # mod_session_cookie/crypto/dbd 중 하나라도 활성화돼 있으면 mod_session 활성화
    if grep -qE '^LoadModule session_(cookie|crypto|dbd)_module' "$conf"; then
      sed -i 's|^#\(LoadModule session_module\)|\1|' "$conf"
      log "  httpd.conf: mod_session 활성화 (session_cookie/crypto/dbd 의존성)"
    fi
  fi

  # ── mod_jk: LoadModule 주석 추가 및 workers.properties 샘플 생성 ────────────
  if [ -f "$APACHE_PREFIX/modules/mod_jk.so" ]; then
    # 이미 LoadModule jk 항목이 없으면 주석으로 추가
    if ! grep -q 'mod_jk' "$conf"; then
      cat >> "$conf" <<'MODJK'

# ── mod_jk (Tomcat AJP Connector) ────────────────────────────────────────────
# 사용 시 아래 주석을 해제하고 conf/workers.properties 를 환경에 맞게 수정하세요.
#LoadModule jk_module modules/mod_jk.so
#JkWorkersFile conf/workers.properties
#JkLogFile logs/mod_jk.log
#JkLogLevel info
#JkMount /app/* worker1
#JkMount /manager/* worker1
MODJK
      log "  httpd.conf: mod_jk 설정 블록 추가 (주석 처리)"
    fi

    # workers.properties 샘플
    cat > "$APACHE_PREFIX/conf/workers.properties.minimal" <<'WORKERS'
# workers.properties - mod_jk Tomcat 연결 설정 샘플
# 실제 사용 시 이 파일을 workers.properties 로 복사하여 수정하세요.
#
# worker 목록
worker.list=worker1

# worker1: AJP 연결 대상 Tomcat
worker.worker1.type=ajp13
worker.worker1.host=127.0.0.1
worker.worker1.port=8009
worker.worker1.connection_pool_size=10
worker.worker1.connect_timeout=5000
worker.worker1.reply_timeout=300000
WORKERS
    log "  conf/workers.properties.minimal 생성"
  fi

  # lib64 ↔ lib 심볼릭 링크
  [ -d "$DEPS_PREFIX/lib64" ] && [ ! -e "$DEPS_PREFIX/lib"   ] && ln -s lib64 "$DEPS_PREFIX/lib"
  [ -d "$DEPS_PREFIX/lib"   ] && [ ! -e "$DEPS_PREFIX/lib64" ] && ln -s lib   "$DEPS_PREFIX/lib64"

  # ── env.sh ─────────────────────────────────────────────────────────────────
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

  # ── relocate_apache_paths.sh ───────────────────────────────────────────────
  cat > "$APACHE_PREFIX/bin/relocate_apache_paths.sh" <<'EOS'
#!/usr/bin/env sh
set -eu

APP_BIN_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_HOME="$(CDPATH= cd -- "${APP_BIN_DIR}/.." && pwd)"
APP_BASE="$(dirname "${APP_HOME}")"
COMPILE_HOME="/Product/httpd-2.4.66-build/package/apache"
COMPILE_BASE="$(dirname "${COMPILE_HOME}")"
CONF_FILE="${APP_HOME}/conf/httpd.conf"
RUN_DIR="${APP_HOME}/run"
LOG_DIR="${APP_HOME}/logs"
HTDOCS_DIR="${APP_HOME}/htdocs"
MARKER_FILE="${RUN_DIR}/.relocate_apache_paths.done"
STATE_FILE="${RUN_DIR}/.relocate_apache_paths.home"
FORCE_RELOCATE="${FORCE_RELOCATE:-0}"

TARGET_DIRS="${APP_HOME}/bin ${APP_HOME}/bins ${APP_HOME}/conf ${APP_HOME}/modules"

[ -x "${APP_HOME}/bin/httpd" ] || { echo "ERROR: httpd 없음: ${APP_HOME}/bin/httpd" >&2; exit 1; }
[ -f "${CONF_FILE}" ] || { echo "ERROR: httpd.conf 없음: ${CONF_FILE}" >&2; exit 1; }

mkdir -p "${LOG_DIR}" "${RUN_DIR}"

PREV_HOME=""
[ -f "${STATE_FILE}" ] && PREV_HOME="$(cat "${STATE_FILE}" 2>/dev/null || true)"

if [ "${FORCE_RELOCATE}" != "1" ] && [ -f "${MARKER_FILE}" ]; then
  if [ -z "${PREV_HOME}" ] || [ "${PREV_HOME}" = "${APP_HOME}" ]; then
    echo "INFO: relocate 완료됨. 강제 재실행: FORCE_RELOCATE=1"
    exit 0
  fi
fi

TMP_TEXT_LIST="$(mktemp "${RUN_DIR}/.relocate_textfiles.XXXXXX")"
trap 'rm -f "${TMP_TEXT_LIST}"' EXIT INT TERM
: > "${TMP_TEXT_LIST}"

for dir in ${TARGET_DIRS}; do
  [ -d "${dir}" ] || continue
  grep -IlR . "${dir}" \
    --exclude='*.so' --exclude='*.so.*' --exclude='*.a' \
    --exclude='*.o' --exclude='*.la' --exclude='*.pyc' \
    --exclude='*.pem' --exclude='*.crt' --exclude='*.key' \
    --exclude='*.der' --exclude='*.p12' --exclude='*.gz' \
    --exclude='*.xz' --exclude='*.zip' \
    >> "${TMP_TEXT_LIST}" 2>/dev/null || true
done

sort -u "${TMP_TEXT_LIST}" -o "${TMP_TEXT_LIST}" 2>/dev/null || true

replace_path() {
  old_path="$1"
  new_path="$2"

  [ -n "${old_path}" ] || return 0
  [ "${old_path}" != "${new_path}" ] || return 0
  [ -s "${TMP_TEXT_LIST}" ] || return 0

  echo "  치환: '${old_path}' → '${new_path}'"
  while IFS= read -r fpath; do
    [ -n "${fpath}" ] || continue
    OLD_PATH="${old_path}" NEW_PATH="${new_path}" \
      perl -0pi -e 'BEGIN{$old=$ENV{OLD_PATH};$new=$ENV{NEW_PATH}} s/\Q$old\E/$new/g' \
      "${fpath}" 2>/dev/null || true
  done < "${TMP_TEXT_LIST}"
}

replace_conf_path() {
  old_path="$1"
  new_path="$2"

  [ -n "${old_path}" ] || return 0
  [ "${old_path}" != "${new_path}" ] || return 0

  OLD_PATH="${old_path}" NEW_PATH="${new_path}" \
    perl -0pi -e 'BEGIN{$old=$ENV{OLD_PATH};$new=$ENV{NEW_PATH}} s/\Q$old\E/$new/g' \
    "${CONF_FILE}" 2>/dev/null || true
}

update_directive() {
  key="$1"
  val="$2"

  KEY="${key}" VAL="${val}" \
    perl -0pi -e '
      BEGIN { $k=$ENV{KEY}; $v=$ENV{VAL}; }
      if (s/^[#\s]*\Q$k\E\s+.*$/$k $v/m) { }
      else { $_ .= "\n$k $v\n"; }
    ' "${CONF_FILE}"
}

echo "INFO: relocate 시작 → ${APP_HOME}"
replace_path "${COMPILE_HOME}" "${APP_HOME}"
replace_path "${COMPILE_BASE}" "${APP_BASE}"

if [ -n "${PREV_HOME}" ] && [ "${PREV_HOME}" != "${APP_HOME}" ]; then
  replace_path "${PREV_HOME}" "${APP_HOME}"
  PREV_BASE="$(dirname "${PREV_HOME}")"
  replace_path "${PREV_BASE}" "${APP_BASE}"
fi

update_directive "ServerRoot" "\"${APP_HOME}\""
update_directive "DefaultRuntimeDir" "\"${APP_HOME}/run\""
update_directive "PidFile" "\"${APP_HOME}/logs/httpd.pid\""
update_directive "ErrorLog" "\"${APP_HOME}/logs/error_log\""
update_directive "DocumentRoot" "\"${HTDOCS_DIR}\""

replace_conf_path "${COMPILE_HOME}/htdocs" "${HTDOCS_DIR}"
replace_conf_path "${COMPILE_BASE}/htdocs" "${HTDOCS_DIR}"

if [ -n "${PREV_HOME}" ] && [ "${PREV_HOME}" != "${APP_HOME}" ]; then
  replace_conf_path "${PREV_HOME}/htdocs" "${HTDOCS_DIR}"
  PREV_BASE="$(dirname "${PREV_HOME}")"
  replace_conf_path "${PREV_BASE}/htdocs" "${HTDOCS_DIR}"
fi

if grep -qE '^[#[:space:]]*ServerName[[:space:]]' "${CONF_FILE}"; then
  perl -0pi -e 's/^[#\s]*ServerName\s+.*$/ServerName localhost/m' "${CONF_FILE}"
else
  printf 'ServerName localhost\n' >> "${CONF_FILE}"
fi

if grep -qE '^LoadModule session_(cookie|crypto|dbd)_module' "${CONF_FILE}"; then
  if grep -qE '^#LoadModule session_module' "${CONF_FILE}"; then
    perl -0pi -e 's/^#(LoadModule session_module)/$1/m' "${CONF_FILE}"
    echo "INFO: mod_session 활성화 (session_cookie/crypto/dbd 의존성 해결)"
  fi
fi

printf '%s\n' "${APP_HOME}" > "${STATE_FILE}"
touch "${MARKER_FILE}"

echo "INFO: httpd 설정 검증..."
"${APP_HOME}/bin/httpd" -d "${APP_HOME}" -f "${CONF_FILE}" -t \
  && echo "INFO: 설정 OK" \
  || { echo "ERROR: httpd -t 실패. ${APP_HOME}/logs/error_log 확인" >&2; exit 1; }
EOS
  chmod 755 "$APACHE_PREFIX/bin/relocate_apache_paths.sh"

  # ── start.sh ───────────────────────────────────────────────────────────────
  cat > "$APACHE_PREFIX/bin/start.sh" <<'EOS'
#!/usr/bin/env sh
set -eu

APP_BIN_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_HOME="$(CDPATH= cd -- "${APP_BIN_DIR}/.." && pwd)"

. "${APP_HOME}/bin/env.sh"
cd "${APP_HOME}"
exec "${APP_HOME}/bin/httpd" -d "${APP_HOME}" -f "${APP_HOME}/conf/httpd.conf" -k start "$@"
EOS
  chmod 755 "$APACHE_PREFIX/bin/start.sh"

  # ── stop.sh ────────────────────────────────────────────────────────────────
  cat > "$APACHE_PREFIX/bin/stop.sh" <<'EOS'
#!/usr/bin/env sh
set -eu

APP_BIN_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_HOME="$(CDPATH= cd -- "${APP_BIN_DIR}/.." && pwd)"

. "${APP_HOME}/bin/env.sh"
cd "${APP_HOME}"
exec "${APP_HOME}/bin/httpd" -d "${APP_HOME}" -f "${APP_HOME}/conf/httpd.conf" -k stop "$@"
EOS
  chmod 755 "$APACHE_PREFIX/bin/stop.sh"

  # ── restart.sh (graceful) ──────────────────────────────────────────────────
  cat > "$APACHE_PREFIX/bin/restart.sh" <<'EOS'
#!/usr/bin/env sh
set -eu

APP_BIN_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP_HOME="$(CDPATH= cd -- "${APP_BIN_DIR}/.." && pwd)"

. "${APP_HOME}/bin/env.sh"
cd "${APP_HOME}"
exec "${APP_HOME}/bin/httpd" -d "${APP_HOME}" -f "${APP_HOME}/conf/httpd.conf" -k graceful "$@"
EOS
  chmod 755 "$APACHE_PREFIX/bin/restart.sh"

  # ── status.sh ──────────────────────────────────────────────────────────────
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

  # ── README.txt ─────────────────────────────────────────────────────────────
  cat > "$APACHE_PREFIX/README.txt" <<EOS
Apache HTTP Server ${HTTPD_VERSION} - Portable Build
=====================================================
빌드일시  : $(date '+%F %T')
컴파일경로: /Product/httpd-${HTTPD_VERSION}-build/package/apache

[포함 구성요소]
  httpd    ${HTTPD_VERSION}      APR      ${APR_VERSION}
  APR-util ${APR_UTIL_VERSION}   OpenSSL  ${OPENSSL_VERSION}
  PCRE2    ${PCRE2_VERSION}       zlib     ${ZLIB_VERSION}
  expat    ${EXPAT_VERSION}    nghttp2  ${NGHTTP2_VERSION}
  mod_jk   ${MOD_JK_VERSION}    (Tomcat AJP Connector, 기본 비활성)

[사용법]
  bin/start.sh       Apache 시작 (첫 실행 시 경로 자동 재설정)
  bin/stop.sh        Apache 중지
  bin/restart.sh     Apache 재시작 (graceful)
  bin/status.sh      실행 상태 확인

[경로 재배치]
  다른 경로 설치 시 start.sh 가 자동으로 경로를 재설정합니다.
  수동 강제 재설정: FORCE_RELOCATE=1 bin/start.sh

[의존 라이브러리]
  bins/ 하위에 모두 포함되어 있습니다. 시스템에 별도 설치 불필요.
EOS
}

# =============================================================================
# 검증
# =============================================================================
verify() {
  log "빌드 결과 검증"
  export LD_LIBRARY_PATH="${DEPS_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

  "$APACHE_PREFIX/bin/httpd" -v  2>&1 | tee "$LOGS/verify-httpd-version.log"
  "$APACHE_PREFIX/bin/httpd" -V  2>&1 | tee "$LOGS/verify-httpd-build.log"
  "$APACHE_PREFIX/bin/httpd" -M  2>&1 | tee "$LOGS/verify-httpd-modules.log" || true
  ldd "$APACHE_PREFIX/bin/httpd" 2>&1 | tee "$LOGS/verify-ldd-httpd.log"     || true

  [ -f "$APACHE_PREFIX/modules/mod_ssl.so" ] \
    && ldd "$APACHE_PREFIX/modules/mod_ssl.so" 2>&1 | tee "$LOGS/verify-ldd-mod_ssl.log" || true

  if grep -q 'not found' "$LOGS/verify-ldd-httpd.log" 2>/dev/null; then
    log "ERROR: 누락된 공유 라이브러리 존재 - ldd 결과:"
    grep 'not found' "$LOGS/verify-ldd-httpd.log" >&2
    die "번들되지 않은 라이브러리가 남아 있습니다. bundle_system_libs() 확인 필요"
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
  log "  GCC    : $(gcc --version | head -1)"
  log "  Threads: ${THREADS}"
  log "  httpd  : ${HTTPD_VERSION}"
  log "  OpenSSL: ${OPENSSL_VERSION}"
  log "  APR    : ${APR_VERSION} / APR-util: ${APR_UTIL_VERSION}"
  log "  PCRE2  : ${PCRE2_VERSION}"
  log "  nghttp2: ${NGHTTP2_VERSION}"
  log "  OUTPUT : ${OUT_TAR}"
  log "=============================="
}

# =============================================================================
# main
# =============================================================================
main() {
  require_cmd sudo
  require_cmd curl
  require_cmd tar

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
  build_httpd
  build_mod_jk
  post_layout
  fix_rpath_so_files
  bundle_system_libs
  verify
  cleanup_work
  package_output

  log "============================="
  log "빌드 완료: ${OUT_TAR}"
  log "배포 후 첫 실행: bin/start.sh"
  log "============================="
}

main "$@"

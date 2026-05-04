#!/usr/bin/env bash
set -euo pipefail

# Apache HTTP Server 2.4.66 portable build script for Rocky Linux
# Goal:
# - Build Apache 2.4.66 from source
# - Bundle dependency libraries under bins/
# - Minimize runtime dependency on OS component packages
# - Package compiled output as httpd-2.4.66-compiled.tar.gz
# - Ensure extracted top-level directory is named apache/
# - Support relocation to paths like /Product/apache, /Product/WEB/apache, /Product/Apache
# - Rewrite embedded text-paths on first execution only

HTTPD_VERSION="2.4.66"
APR_VERSION="1.7.6"
APR_UTIL_VERSION="1.6.3"
PCRE2_VERSION="10.45"
ZLIB_VERSION="1.3.1"
EXPAT_VERSION="2.7.1"
OPENSSL_VERSION="3.0.17"

BASE="/Product/httpd-${HTTPD_VERSION}-build"
SRC="${BASE}/sources"
WORK="${BASE}/work"
PKG="${BASE}/package"
LOGS="${BASE}/logs"
APACHE_PREFIX="${PKG}/apache"
DEPS_PREFIX="${APACHE_PREFIX}/bins"
OUT_TAR="${BASE}/httpd-${HTTPD_VERSION}-compiled.tar.gz"

THREADS="$(nproc)"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}

prepare_build_tools() {
  log "Installing build toolchain"
  sudo dnf groupinstall -y "Development Tools"
  sudo dnf install -y wget curl tar gzip xz bzip2 perl make which file diffutils findutils grep sed gawk
}

prepare_dirs() {
  log "Preparing directory layout"
  mkdir -p "$SRC" "$WORK" "$PKG" "$LOGS" "$APACHE_PREFIX" "$DEPS_PREFIX"
}

DOWNLOAD_RETRY=3
DOWNLOAD_CONNECT_TIMEOUT=20
DOWNLOAD_MAX_TIME=1800

SOURCE_FILES=(
  "httpd-${HTTPD_VERSION}.tar.gz|https://downloads.apache.org/httpd/httpd-${HTTPD_VERSION}.tar.gz"
  "apr-${APR_VERSION}.tar.gz|https://downloads.apache.org/apr/apr-${APR_VERSION}.tar.gz"
  "apr-util-${APR_UTIL_VERSION}.tar.gz|https://downloads.apache.org/apr/apr-util-${APR_UTIL_VERSION}.tar.gz"
  "pcre2-${PCRE2_VERSION}.tar.gz|https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE2_VERSION}/pcre2-${PCRE2_VERSION}.tar.gz"
  "zlib-${ZLIB_VERSION}.tar.gz|https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz"
  "expat-${EXPAT_VERSION}.tar.xz|https://github.com/libexpat/libexpat/releases/download/R_${EXPAT_VERSION//./_}/expat-${EXPAT_VERSION}.tar.xz"
  "openssl-${OPENSSL_VERSION}.tar.gz|https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
)

download_sources() {
  log "Downloading source archives"
  cd "$SRC"

  local entry file url tmpfile
  local -a failed_downloads=()
  local -a missing_files=()

  for entry in "${SOURCE_FILES[@]}"; do
    file="${entry%%|*}"
    url="${entry#*|}"

    if [ -s "$file" ]; then
      log "SKIP already downloaded: $file"
      continue
    fi

    tmpfile="${file}.part"
    rm -f "$tmpfile"

    log "DOWNLOAD start: $file"
    if curl -fL \
      --retry "$DOWNLOAD_RETRY" \
      --retry-delay 2 \
      --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" \
      --max-time "$DOWNLOAD_MAX_TIME" \
      -o "$tmpfile" "$url"; then

      if [ -s "$tmpfile" ]; then
        mv -f "$tmpfile" "$file"
        log "DOWNLOAD ok: $file"
      else
        rm -f "$tmpfile"
        failed_downloads+=("$file")
        log "DOWNLOAD failed(empty file): $file"
      fi
    else
      rm -f "$tmpfile"
      failed_downloads+=("$file")
      log "DOWNLOAD failed: $file"
    fi
  done

  log "Final source file check"
  for entry in "${SOURCE_FILES[@]}"; do
    file="${entry%%|*}"
    if [ ! -s "$file" ]; then
      missing_files+=("$file")
      log "MISSING: $file"
    else
      log "READY: $file"
    fi
  done

  if [ "${#failed_downloads[@]}" -gt 0 ]; then
    echo >&2
    echo "다운로드 실패 파일 목록:" >&2
    printf ' - %s\n' "${failed_downloads[@]}" >&2
  fi

  if [ "${#missing_files[@]}" -gt 0 ]; then
    echo >&2
    echo "최종 점검 후 누락 파일 목록:" >&2
    printf ' - %s\n' "${missing_files[@]}" >&2
    echo "다운로드 오류가 있어 빌드를 중지합니다." >&2
    exit 1
  fi

  log "All source archives are ready"
}

prepare_env() {
  export CPPFLAGS="-I${DEPS_PREFIX}/include"
  export LDFLAGS="-L${DEPS_PREFIX}/lib -Wl,-rpath,\$ORIGIN/../bins/lib -Wl,-rpath,\$ORIGIN/../../bins/lib"
  export LD_LIBRARY_PATH="${DEPS_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  export PKG_CONFIG_PATH="${DEPS_PREFIX}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
}

clean_extract() {
  local archive="$1"
  local dir="$2"
  cd "$WORK"
  rm -rf "$dir"
  tar xf "$SRC/$archive"
}

build_zlib() {
  log "Building zlib-${ZLIB_VERSION}"
  clean_extract "zlib-${ZLIB_VERSION}.tar.gz" "zlib-${ZLIB_VERSION}"
  cd "$WORK/zlib-${ZLIB_VERSION}"
  ./configure --prefix="$DEPS_PREFIX" >"$LOGS/zlib-configure.log" 2>&1
  make -j"$THREADS" >"$LOGS/zlib-make.log" 2>&1
  make install >"$LOGS/zlib-install.log" 2>&1
}

build_expat() {
  log "Building expat-${EXPAT_VERSION}"
  clean_extract "expat-${EXPAT_VERSION}.tar.xz" "expat-${EXPAT_VERSION}"
  cd "$WORK/expat-${EXPAT_VERSION}"
  ./configure --prefix="$DEPS_PREFIX" >"$LOGS/expat-configure.log" 2>&1
  make -j"$THREADS" >"$LOGS/expat-make.log" 2>&1
  make install >"$LOGS/expat-install.log" 2>&1
}

build_pcre2() {
  log "Building pcre2-${PCRE2_VERSION}"
  clean_extract "pcre2-${PCRE2_VERSION}.tar.gz" "pcre2-${PCRE2_VERSION}"
  cd "$WORK/pcre2-${PCRE2_VERSION}"
  ./configure --prefix="$DEPS_PREFIX" >"$LOGS/pcre2-configure.log" 2>&1
  make -j"$THREADS" >"$LOGS/pcre2-make.log" 2>&1
  make install >"$LOGS/pcre2-install.log" 2>&1
}

build_openssl() {
  log "Building openssl-${OPENSSL_VERSION}"
  clean_extract "openssl-${OPENSSL_VERSION}.tar.gz" "openssl-${OPENSSL_VERSION}"
  cd "$WORK/openssl-${OPENSSL_VERSION}"
  ./Configure --prefix="$DEPS_PREFIX" \
              --openssldir="$DEPS_PREFIX/ssl" \
              shared linux-x86_64 >"$LOGS/openssl-configure.log" 2>&1
  make -j"$THREADS" >"$LOGS/openssl-make.log" 2>&1
  make install_sw >"$LOGS/openssl-install.log" 2>&1
}

build_apr() {
  log "Building apr-${APR_VERSION}"
  clean_extract "apr-${APR_VERSION}.tar.gz" "apr-${APR_VERSION}"
  cd "$WORK/apr-${APR_VERSION}"
  ./configure --prefix="$DEPS_PREFIX" >"$LOGS/apr-configure.log" 2>&1
  make -j"$THREADS" >"$LOGS/apr-make.log" 2>&1
  make install >"$LOGS/apr-install.log" 2>&1
}

build_apr_util() {
  log "Building apr-util-${APR_UTIL_VERSION}"
  clean_extract "apr-util-${APR_UTIL_VERSION}.tar.gz" "apr-util-${APR_UTIL_VERSION}"
  cd "$WORK/apr-util-${APR_UTIL_VERSION}"
  ./configure --prefix="$DEPS_PREFIX" \
              --with-apr="$DEPS_PREFIX" \
              --with-expat="$DEPS_PREFIX" \
              --with-openssl="$DEPS_PREFIX" >"$LOGS/apr-util-configure.log" 2>&1
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
    --with-mpm=event \
    --with-apr="$DEPS_PREFIX/bin/apr-1-config" \
    --with-apr-util="$DEPS_PREFIX/bin/apu-1-config" \
    --with-pcre="$DEPS_PREFIX/bin/pcre2-config" \
    --with-ssl="$DEPS_PREFIX" \
    --with-z="$DEPS_PREFIX" >"$LOGS/httpd-configure.log" 2>&1
  make -j"$THREADS" >"$LOGS/httpd-make.log" 2>&1
  make install >"$LOGS/httpd-install.log" 2>&1
}

post_layout() {
  log "Adjusting package layout"
  mkdir -p "$APACHE_PREFIX/run" "$APACHE_PREFIX/logs"

  if [ -d "$DEPS_PREFIX/lib64" ] && [ ! -e "$DEPS_PREFIX/lib" ]; then
    ln -s lib64 "$DEPS_PREFIX/lib"
  fi
  if [ -d "$DEPS_PREFIX/lib" ] && [ ! -e "$DEPS_PREFIX/lib64" ]; then
    ln -s lib "$DEPS_PREFIX/lib64"
  fi

  cat > "$APACHE_PREFIX/bin/env.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
APP_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
APP_HOME="$(cd "${APP_BIN_DIR}/.." && pwd)"
export APP_HOME
export LD_LIBRARY_PATH="${APP_HOME}/bins/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export PATH="${APP_HOME}/bin:${APP_HOME}/bins/bin${PATH:+:${PATH}}"
EOS
  chmod 755 "$APACHE_PREFIX/bin/env.sh"

  cat > "$APACHE_PREFIX/bin/relocate_apache_paths.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

APP_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
APP_HOME="$(cd "${APP_BIN_DIR}/.." && pwd)"
COMPILE_HOME="/Product/httpd-2.4.66-build/package/apache"
CONF_FILE="${APP_HOME}/conf/httpd.conf"
RUN_DIR="${APP_HOME}/run"
LOG_DIR="${APP_HOME}/logs"
MARKER_FILE="${RUN_DIR}/.relocate_apache_paths.done"
STATE_FILE="${RUN_DIR}/.relocate_apache_paths.home"
FORCE_RELOCATE="${FORCE_RELOCATE:-0}"

TARGET_DIRS=(
  "${APP_HOME}/bin"
  "${APP_HOME}/bins"
)

if [ ! -x "${APP_HOME}/bin/httpd" ]; then
  echo "ERROR: httpd not found: ${APP_HOME}/bin/httpd" >&2
  exit 1
fi

if [ ! -f "${CONF_FILE}" ]; then
  echo "ERROR: httpd.conf not found: ${CONF_FILE}" >&2
  exit 1
fi

mkdir -p "${LOG_DIR}" "${RUN_DIR}"

PREV_HOME=""
if [ -f "${STATE_FILE}" ]; then
  PREV_HOME="$(cat "${STATE_FILE}" 2>/dev/null || true)"
fi

if [ "${FORCE_RELOCATE}" != "1" ] && [ -f "${MARKER_FILE}" ]; then
  if [ -z "${PREV_HOME}" ] || [ "${PREV_HOME}" = "${APP_HOME}" ]; then
    echo "INFO: relocate_apache_paths.sh already completed once. skip."
    exit 0
  fi
fi

TEXT_FILES=()
for dir in "${TARGET_DIRS[@]}"; do
  [ -d "${dir}" ] || continue
  while IFS= read -r file; do
    [ -n "${file}" ] && TEXT_FILES+=("${file}")
  done < <(
    grep -IlR . "${dir}" \
      --exclude='*.so' \
      --exclude='*.a' \
      --exclude='*.o' \
      --exclude='*.la' \
      --exclude='*.pyc' \
      --exclude='*.swp' \
      --exclude='*.pem' \
      --exclude='*.crt' \
      --exclude='*.key' \
      --exclude='*.der' \
      --exclude='*.p12' \
      --exclude='*.gz' \
      --exclude='*.xz' \
      --exclude='*.zip' 2>/dev/null || true
  )
done

replace_exact_path() {
  local old_path="$1"
  local new_path="$2"
  local file

  [ -n "${old_path}" ] || return 0
  [ "${old_path}" = "${new_path}" ] && return 0

  for file in "${TEXT_FILES[@]:-}"; do
    OLD_PATH="${old_path}" NEW_PATH="${new_path}" \
      perl -0pi -e 'BEGIN { $old = $ENV{OLD_PATH}; $new = $ENV{NEW_PATH}; } s/\Q$old\E/$new/g' "${file}"
  done
}

replace_exact_path "${COMPILE_HOME}" "${APP_HOME}"
if [ -n "${PREV_HOME}" ]; then
  replace_exact_path "${PREV_HOME}" "${APP_HOME}"
fi

if grep -qE '^[#[:space:]]*ServerRoot[[:space:]]+' "${CONF_FILE}"; then
  sed -i "s|^[#[:space:]]*ServerRoot[[:space:]].*|ServerRoot \"${APP_HOME}\"|g" "${CONF_FILE}"
else
  printf '\nServerRoot "%s"\n' "${APP_HOME}" >> "${CONF_FILE}"
fi

if grep -qE '^[#[:space:]]*DefaultRuntimeDir[[:space:]]+' "${CONF_FILE}"; then
  sed -i "s|^[#[:space:]]*DefaultRuntimeDir[[:space:]].*|DefaultRuntimeDir \"${APP_HOME}/run\"|g" "${CONF_FILE}"
else
  printf 'DefaultRuntimeDir "%s/run"\n' "${APP_HOME}" >> "${CONF_FILE}"
fi

if grep -qE '^[#[:space:]]*PidFile[[:space:]]+' "${CONF_FILE}"; then
  sed -i "s|^[#[:space:]]*PidFile[[:space:]].*|PidFile \"${APP_HOME}/logs/httpd.pid\"|g" "${CONF_FILE}"
else
  printf 'PidFile "%s/logs/httpd.pid"\n' "${APP_HOME}" >> "${CONF_FILE}"
fi

if grep -qE '^[#[:space:]]*ErrorLog[[:space:]]+' "${CONF_FILE}"; then
  sed -i "s|^[#[:space:]]*ErrorLog[[:space:]].*|ErrorLog \"${APP_HOME}/logs/error_log\"|g" "${CONF_FILE}"
fi

if grep -qE '^[#[:space:]]*ServerName[[:space:]]+' "${CONF_FILE}"; then
  sed -i '0,/^[#[:space:]]*ServerName[[:space:]].*/s//ServerName localhost/' "${CONF_FILE}"
else
  printf 'ServerName localhost\n' >> "${CONF_FILE}"
fi

printf '%s\n' "${APP_HOME}" > "${STATE_FILE}"
touch "${MARKER_FILE}"

"${APP_HOME}/bin/httpd" -d "${APP_HOME}" -f "${CONF_FILE}" -t
EOS
  chmod 755 "$APACHE_PREFIX/bin/relocate_apache_paths.sh"

  cat > "$APACHE_PREFIX/bin/start.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
APP_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
APP_HOME="$(cd "${APP_BIN_DIR}/.." && pwd)"
source "${APP_HOME}/bin/env.sh"
cd "${APP_HOME}"
exec "${APP_HOME}/bin/httpd" -d "${APP_HOME}" -f "${APP_HOME}/conf/httpd.conf" -k start "$@"
EOS
  chmod 755 "$APACHE_PREFIX/bin/start.sh"

  cat > "$APACHE_PREFIX/bin/stop.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
APP_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
APP_HOME="$(cd "${APP_BIN_DIR}/.." && pwd)"
source "${APP_HOME}/bin/env.sh"
cd "${APP_HOME}"
exec "${APP_HOME}/bin/httpd" -d "${APP_HOME}" -f "${APP_HOME}/conf/httpd.conf" -k stop "$@"
EOS
  chmod 755 "$APACHE_PREFIX/bin/stop.sh"

  cat > "$APACHE_PREFIX/bin/restart.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
APP_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
APP_HOME="$(cd "${APP_BIN_DIR}/.." && pwd)"
source "${APP_HOME}/bin/env.sh"
cd "${APP_HOME}"
exec "${APP_HOME}/bin/httpd" -d "${APP_HOME}" -f "${APP_HOME}/conf/httpd.conf" -k restart "$@"
EOS
  chmod 755 "$APACHE_PREFIX/bin/restart.sh"

  cat > "$APACHE_PREFIX/bin/status.sh" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
APP_BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
APP_HOME="$(cd "${APP_BIN_DIR}/.." && pwd)"
PID_FILE="${APP_HOME}/logs/httpd.pid"

if [ -f "${PID_FILE}" ]; then
  PID="$(cat "${PID_FILE}")"
  if ps -p "${PID}" >/dev/null 2>&1; then
    echo "Apache running (PID: ${PID})"
    exit 0
  fi
fi

echo "Apache stopped"
exit 1
EOS
  chmod 755 "$APACHE_PREFIX/bin/status.sh"
}

verify() {
  log "Verifying binaries"
  "$APACHE_PREFIX/bin/httpd" -v | tee "$LOGS/verify-httpd-version.log"
  "$APACHE_PREFIX/bin/httpd" -V | tee "$LOGS/verify-httpd-build.log"
  "$APACHE_PREFIX/bin/httpd" -d "$APACHE_PREFIX" -f "$APACHE_PREFIX/conf/httpd.conf" -t | tee "$LOGS/verify-httpd-configtest.log" || true
  ldd "$APACHE_PREFIX/bin/httpd" | tee "$LOGS/verify-ldd-httpd.log" || true
  if [ -f "$APACHE_PREFIX/modules/mod_ssl.so" ]; then
    ldd "$APACHE_PREFIX/modules/mod_ssl.so" | tee "$LOGS/verify-ldd-mod_ssl.log" || true
  fi
}

package_output() {
  log "Creating final archive"
  cd "$PKG"
  rm -f "$OUT_TAR"
  tar czf "$OUT_TAR" apache
  log "Archive created: $OUT_TAR"
}

main() {
  require_cmd sudo
  require_cmd curl
  require_cmd tar
  require_cmd make

  prepare_build_tools
  prepare_dirs
  download_sources
  prepare_env
  build_zlib
  build_expat
  build_pcre2
  build_openssl
  build_apr
  build_apr_util
  build_httpd
  post_layout
  verify
  package_output

  log "Completed"
}

main "$@"

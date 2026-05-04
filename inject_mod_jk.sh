#!/usr/bin/env bash
set -euo pipefail

MOD_JK_VERSION="1.2.50"
OUT_TAR="/Product/httpd-2.4.66-build/httpd-2.4.66-compiled.tar.gz"
FINAL_TAR="/Product/httpd-2.4.66-glibc2.25-compiled.tar.gz"
REPACK_DIR="/tmp/httpd_modjk_repack"
JK_SRC_DIR="/tmp/modjk_src"
JK_DOWNLOAD_URL="https://downloads.apache.org/tomcat/tomcat-connectors/jk/tomcat-connectors-${MOD_JK_VERSION}-src.tar.gz"

# mod_jk는 반드시 Rocky Linux 8 컨테이너에서 빌드해야 glibc 2.28 수준 유지
# 호스트(Rocky 10, glibc 2.39)에서 빌드하면 GLIBC_2.38 심볼이 박힘

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

# ── tarball 존재 확인 ──────────────────────────────────────────────────────
[ -f "${OUT_TAR}" ] || { log "ERROR: 빌드 tarball 없음: ${OUT_TAR}"; exit 1; }
log "기존 빌드 tarball 확인 OK"

# ── tarball 압축 해제 ──────────────────────────────────────────────────────
log "패키지 압축 해제: ${OUT_TAR}"
rm -rf "${REPACK_DIR}" && mkdir -p "${REPACK_DIR}"
tar xzf "${OUT_TAR}" -C "${REPACK_DIR}"
APACHE_PREFIX="${REPACK_DIR}/apache"

# ── mod_jk 소스 다운로드 (호스트에서, 네트워크 접근 용이) ─────────────────
log "mod_jk-${MOD_JK_VERSION} 소스 다운로드"
rm -rf "${JK_SRC_DIR}" && mkdir -p "${JK_SRC_DIR}"
curl -fSL --retry 3 --connect-timeout 20 --max-time 300 \
  "${JK_DOWNLOAD_URL}" \
  -o "${JK_SRC_DIR}/tomcat-connectors-${MOD_JK_VERSION}-src.tar.gz"
tar xzf "${JK_SRC_DIR}/tomcat-connectors-${MOD_JK_VERSION}-src.tar.gz" -C "${JK_SRC_DIR}"
log "소스 다운로드 완료"

# ── Rocky Linux 8 컨테이너 안에서 mod_jk 빌드 ────────────────────────────
# apxs가 원본 빌드 경로(/Product/...)를 하드코딩 → /Product를 동일 경로로 마운트
log "Rocky Linux 8 컨테이너에서 mod_jk 빌드 시작 (glibc 2.28 환경)"

# 원본 빌드에서 apxs 경로 (config_vars.mk 포함)
ORIG_APACHE="/Product/httpd-2.4.66-build/package/apache"
ORIG_APXS="${ORIG_APACHE}/bin/apxs"
[ -f "${ORIG_APXS}" ] || { log "ERROR: 원본 apxs 없음: ${ORIG_APXS}"; exit 1; }

podman rm -f modjk-build 2>/dev/null || true
podman run --rm \
  --name modjk-build \
  --user root \
  -v "/Product:/Product:z" \
  -v "${REPACK_DIR}:/mnt/repack:z" \
  -v "${JK_SRC_DIR}:/mnt/modjk_src:z" \
  httpd-build-rocky8-base:latest \
  bash -c '
    set -euo pipefail
    NATIVE_DIR="/mnt/modjk_src/tomcat-connectors-'"${MOD_JK_VERSION}"'-src/native"
    APXS="'"${ORIG_APXS}"'"
    REPACK_MODULES="/mnt/repack/apache/modules"

    cd "${NATIVE_DIR}"
    ./configure --with-apxs="${APXS}" > /tmp/jk-configure.log 2>&1
    make -j"$(nproc)"                 >> /tmp/jk-configure.log 2>&1

    # 빌드 결과 찾기 (apxs 설치 경로는 원본 빌드 경로이므로 직접 복사)
    SO_PATH="$(find "${NATIVE_DIR}" -name "mod_jk.so" | head -1)"
    [ -n "${SO_PATH}" ] || { echo "ERROR: mod_jk.so 빌드 결과 없음"; cat /tmp/jk-configure.log; exit 1; }
    cp "${SO_PATH}" "${REPACK_MODULES}/mod_jk.so"

    # patchelf: DT_RPATH 설정 ($ORIGIN 기준 상대 경로)
    patchelf --force-rpath \
      --set-rpath '"'"'$ORIGIN/../bins/lib:$ORIGIN/../bins/lib64'"'"' \
      "${REPACK_MODULES}/mod_jk.so"

    echo "OK: mod_jk.so → ${REPACK_MODULES}/mod_jk.so"
    objdump -T "${REPACK_MODULES}/mod_jk.so" | grep GLIBC | awk '"'"'{print $5}'"'"' | sort -uV
  '

log "mod_jk.so 빌드 완료 (컨테이너)"

# 결과 검증
[ -f "${APACHE_PREFIX}/modules/mod_jk.so" ] || { log "ERROR: mod_jk.so 컨테이너 빌드 후에도 없음"; exit 1; }
log "GLIBC 버전 확인:"
objdump -T "${APACHE_PREFIX}/modules/mod_jk.so" | grep GLIBC | awk '{print $5}' | sort -uV | tee /dev/stderr

# ── httpd.conf mod_jk 블록 추가 ───────────────────────────────────────────
CONF_FILE="${APACHE_PREFIX}/conf/httpd.conf"
if ! grep -q 'mod_jk' "${CONF_FILE}"; then
  cat >> "${CONF_FILE}" <<'MODJK'

# ── mod_jk (Tomcat AJP Connector) ────────────────────────────────────────────
# 사용 시 아래 주석을 해제하고 conf/workers.properties 를 환경에 맞게 수정하세요.
#LoadModule jk_module modules/mod_jk.so
#JkWorkersFile conf/workers.properties
#JkLogFile logs/mod_jk.log
#JkLogLevel info
#JkMount /app/* worker1
#JkMount /manager/* worker1
MODJK
  log "httpd.conf: mod_jk 설정 블록 추가 (주석 처리)"
fi

# ── workers.properties 샘플 생성 ──────────────────────────────────────────
cat > "${APACHE_PREFIX}/conf/workers.properties.minimal" <<'WORKERS'
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
log "conf/workers.properties.minimal 생성"

# ── relocate_apache_paths.sh 최신본 교체 ──────────────────────────────────
\cp /Product/relocate_apache_paths.sh \
  "${APACHE_PREFIX}/bin/relocate_apache_paths.sh"
chmod 755 "${APACHE_PREFIX}/bin/relocate_apache_paths.sh"
log "relocate_apache_paths.sh 최신본 반영"

# ── 재압축 ────────────────────────────────────────────────────────────────
log "최종 패키지 재압축: ${FINAL_TAR}"
[ -f "${FINAL_TAR}" ] && mv "${FINAL_TAR}" "${FINAL_TAR}.bak"
tar czf "${FINAL_TAR}" -C "${REPACK_DIR}" apache
SIZE=$(du -sh "${FINAL_TAR}" | awk '{print $1}')
log "완료: ${FINAL_TAR} (${SIZE})"

# ── 정리 ──────────────────────────────────────────────────────────────────
rm -rf "${REPACK_DIR}" "${JK_SRC_DIR}"

log "====================================="
log "mod_jk ${MOD_JK_VERSION} 패키지 주입 완료"
log "  modules/mod_jk.so (Rocky 8 컨테이너 빌드, glibc 2.28 호환)"
log "  conf/workers.properties.minimal"
log "  httpd.conf mod_jk 블록 (주석)"
log "====================================="

#!/bin/bash
# Rocky Linux 8 + 빌드 도구 베이스 이미지 생성
# 이 이미지로 httpd 빌드 시 패키지 설치 단계 생략 가능

set -euo pipefail

IMAGE_NAME="httpd-build-rocky8-base"
IMAGE_TAG="1.0"
CONTAINER_NAME="httpd-base-setup"

echo "=== 베이스 이미지 생성 시작 ==="

# 기존 컨테이너 정리
podman rm -f "$CONTAINER_NAME" 2>/dev/null || true

# 패키지 설치 전용 컨테이너 실행
echo "[1/3] 컨테이너 시작 및 패키지 설치 중..."
podman run \
  --name "$CONTAINER_NAME" \
  --user root \
  docker.io/rockylinux:8 \
  bash -c '
    set -e
    # sudo shim
    printf "#!/bin/bash\nexec \"\$@\"\n" > /usr/local/bin/sudo
    chmod +x /usr/local/bin/sudo

    echo "[패키지] Development Tools 설치..."
    dnf groupinstall -y "Development Tools"

    echo "[패키지] 빌드 도구 설치..."
    dnf install -y \
      wget curl tar gzip xz bzip2 \
      perl make which file diffutils findutils \
      grep sed gawk

    echo "[패키지] EPEL 설치..."
    dnf install -y epel-release

    echo "[패키지] patchelf 설치..."
    dnf install -y patchelf || {
      echo "EPEL patchelf 실패 → 소스 빌드"
      PE_VER="0.18.0"
      curl -fSL "https://github.com/NixOS/patchelf/releases/download/${PE_VER}/patchelf-${PE_VER}.tar.bz2" \
        -o /tmp/patchelf.tar.bz2
      tar -xjf /tmp/patchelf.tar.bz2 -C /tmp
      cd /tmp/patchelf-${PE_VER}
      ./configure --prefix=/usr/local
      make -j$(nproc)
      make install
    }

    echo "[패키지] dnf 캐시 정리..."
    dnf clean all

    echo "[완료] 모든 패키지 설치 완료"
    gcc --version | head -1
    patchelf --version
  '

echo "[2/3] 이미지 커밋: ${IMAGE_NAME}:${IMAGE_TAG}"
podman commit \
  -f docker \
  --author "httpd-build" \
  "$CONTAINER_NAME" \
  "${IMAGE_NAME}:${IMAGE_TAG}"

# latest 태그도 추가
podman tag "${IMAGE_NAME}:${IMAGE_TAG}" "${IMAGE_NAME}:latest"

echo "[3/3] 컨테이너 정리..."
podman rm "$CONTAINER_NAME"

echo ""
echo "=== 베이스 이미지 생성 완료 ==="
podman images | grep "$IMAGE_NAME"
echo ""
echo "다음 빌드 실행 명령어:"
echo "  podman run -d -v /Product:/Product:z --name httpd-build-env --user root \\"
echo "    ${IMAGE_NAME}:latest \\"
echo "    bash -c 'bash /Product/httpd_build_final_v3.sh 2>&1 | tee /Product/httpd-2.4.66-build/build.log'"

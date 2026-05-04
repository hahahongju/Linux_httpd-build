# httpd 2.4.66 빌드 재개 프롬프트

---

## A. 베이스 이미지 있는 경우 (권장)

```
httpd 2.4.66 빌드 작업 이어서 해줘.

[환경]
- 빌드 OS: rockylinux:8 컨테이너 (glibc 2.28) → RHEL 8+ 배포용
- 베이스 이미지: httpd-build-rocky8-base:latest (Development Tools + EPEL + patchelf 설치 완료)
- 빌드 스크립트: /Product/httpd_build_final_v6.sh
- 출력 tarball: /Product/httpd-2.4.66-build/httpd-2.4.66-glibc2.25-compiled-v6.tar.gz

[포함 구성요소]
APR 1.7.6, APR-util 1.6.3, OpenSSL 3.5.6(-O1), PCRE2 10.45,
zlib 1.3.1, expat 2.7.1, nghttp2 1.65.0, mod_jk 1.2.50
patchelf로 $ORIGIN RPATH 처리, start.sh로 경로 자동 relocate

[실행 명령어]
rm -rf /Product/httpd-2.4.66-build && mkdir -p /Product/httpd-2.4.66-build

podman run -d \
  -v /Product:/Product:z \
  --name httpd-build-env \
  --user root \
  httpd-build-rocky8-base:latest \
  bash -c 'bash /Product/httpd_build_final_v6.sh 2>&1 | tee /Product/httpd-2.4.66-build/build.log; echo "BUILD_EXIT:$?"'

[빌드 완료 후 검증]
# GLIBC 버전 확인
find /Product/httpd-2.4.66-build/package/apache -type f | \
  xargs -r objdump -T 2>/dev/null | \
  grep -oP '\(GLIBC_[0-9.]+\)' | sort -uV | tail -5

[완성 파일 복사]
cp /Product/httpd-2.4.66-build/httpd-2.4.66-glibc2.25-compiled-v6.tar.gz \
   /Product/httpd-2.4.66-glibc2.25-compiled.tar.gz

[컨테이너 정리]
podman rm -f httpd-build-env
```

---

## B. 베이스 이미지 없는 경우 (처음부터)

```
httpd 2.4.66 빌드 작업 이어서 해줘.

[환경]
- 빌드 OS: rockylinux:8 컨테이너 (glibc 2.28) → RHEL 8+ 배포용
- 빌드 스크립트: /Product/httpd_build_final_v6.sh
- 베이스 이미지 생성 스크립트: /Product/make_base_image.sh

[실행 순서]
1. 베이스 이미지 생성 (패키지 설치 캐싱):
   bash /Product/make_base_image.sh

2. 빌드 실행:
   rm -rf /Product/httpd-2.4.66-build && mkdir -p /Product/httpd-2.4.66-build
   podman run -d \
     -v /Product:/Product:z \
     --name httpd-build-env \
     --user root \
     httpd-build-rocky8-base:latest \
     bash -c 'bash /Product/httpd_build_final_v6.sh 2>&1 | tee /Product/httpd-2.4.66-build/build.log; echo "BUILD_EXIT:$?"'

[주요 수정 이력]
- patchelf: EPEL repo에서 설치 (기본 repo에 없음), 실패 시 소스 빌드 폴백
- OpenSSL Configure에 -O1 추가 (N100 VM 환경에서 컴파일 속도 개선)
- DT_RUNPATH→DT_RPATH (--disable-new-dtags + patchelf --force-rpath)
- libcrypt.so.1 번들 + ldd 기반 누락 라이브러리 자동 감지
- mod_jk: make install 불사용, find로 직접 복사 후 httpd.conf에 주석 처리 추가
- relocate_apache_paths.sh: sh 호환화 (AWX 환경 대응)
- OpenSSL 3.5.6 (LTS) 적용

[빌드 완료 후 검증]
objdump -T /Product/httpd-2.4.66-build/package/apache/bin/httpd \
  | grep GLIBC | awk '{print $5}' | sort -uV

[완성 파일 복사]
cp /Product/httpd-2.4.66-build/httpd-2.4.66-glibc2.25-compiled-v6.tar.gz \
   /Product/httpd-2.4.66-glibc2.25-compiled.tar.gz

[컨테이너 정리]
podman rm -f httpd-build-env
```

---

## C. 네이티브 빌드 (컨테이너 없는 경우)

```
[환경]
- 빌드 OS: RHEL 8 / Rocky Linux 8 권장 (glibc 2.28)
- 스크립트: /Product/httpd_build_native_v2.sh

[실행]
bash /Product/httpd_build_native_v2.sh
# 경로 커스터마이즈:
BUILD_BASE=/data/httpd-build bash /Product/httpd_build_native_v2.sh
```

---

## 빌드 소요 시간 참고 (N100 VM 기준)
- 전체: 약 90분
- OpenSSL: 40~45분 (가장 오래 걸림, 3.5.x는 다소 증가 가능)
- httpd 본체: 약 30분

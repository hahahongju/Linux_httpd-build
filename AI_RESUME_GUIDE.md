# AI 작업 재개 가이드

새로운 AI 세션에서 이 프로젝트를 이어받아 작업할 때 사용하는 컨텍스트 프롬프트입니다.

---

## 프롬프트 (복사해서 붙여넣기)

```
아래 프로젝트를 이어서 작업해줘.

## 프로젝트 개요
Apache HTTP Server 2.4.66을 RHEL 8+(glibc 2.28) 환경에 배포 가능한
portable tarball로 빌드하는 프로젝트.

## 빌드 방식 (2가지)

### A. 컨테이너 빌드 (Podman/Docker 있는 경우, 권장)
- 빌드 OS: rockylinux:8 컨테이너 (glibc 2.28)
- 베이스 이미지: httpd-build-rocky8-base:latest
- 스크립트: /Product/httpd_build_final_v6.sh
- 실행:
    rm -rf /Product/httpd-2.4.66-build && mkdir -p /Product/httpd-2.4.66-build
    podman run -d \
      -v /Product:/Product:z \
      --name httpd-build-env \
      --user root \
      httpd-build-rocky8-base:latest \
      bash -c 'bash /Product/httpd_build_final_v6.sh \
        2>&1 | tee /Product/httpd-2.4.66-build/build.log; echo "BUILD_EXIT:$?"'

### B. 네이티브 빌드 (컨테이너 없는 경우)
- 빌드 OS: RHEL 8/Rocky 8 권장 (glibc 2.28), RHEL 9 가능
- 스크립트: /Product/httpd_build_native_v2.sh
- 실행:
    bash /Product/httpd_build_native_v2.sh
    # 경로 커스터마이즈:
    BUILD_BASE=/data/httpd-build bash /Product/httpd_build_native_v2.sh

## 핵심 파일
- 컨테이너 빌드 스크립트: /Product/httpd_build_final_v6.sh
- 네이티브 빌드 스크립트: /Product/httpd_build_native_v2.sh
- 베이스 이미지 생성: /Product/make_base_image.sh
- mod_jk 개별 주입(참고용): /Product/inject_mod_jk.sh
- 최종 tarball(권장): /Product/httpd-2.4.66-glibc2.25-compiled-v6.tar.gz (빌드 후 생성)
- 호환용 별칭(선택): /Product/httpd-2.4.66-glibc2.25-compiled.tar.gz
- 사용 매뉴얼: /Product/BUILD_MANUAL.md

## 포함 구성요소
httpd 2.4.66, APR 1.7.6, APR-util 1.6.3, OpenSSL 3.5.6(-O1),
PCRE2 10.45, zlib 1.3.1, expat 2.7.1, nghttp2 1.65.0, mod_jk 1.2.50

## GLIBC 호환성
- httpd 바이너리: GLIBC 2.14
- mod_jk.so: GLIBC 2.14
- bins/lib 최대: GLIBC 2.25 (APR getrandom, APR-util explicit_bzero, expat)
- 배포 가능: RHEL 8+ (glibc 2.28+)
- RHEL 7 미지원 (glibc 2.17)

## 핵심 설계 결정
1. DT_RPATH 강제 (--disable-new-dtags + patchelf --force-rpath)
   → LD_LIBRARY_PATH가 번들 라이브러리를 덮어쓰는 문제 방지
   → apr_crypto_shutdown undefined symbol 오류 원인이었음
2. libcrypt.so.1 명시 번들 + ldd 기반 누락 라이브러리 자동 감지
3. mod_jk: make install 불사용 → apxs -i -a 가 LoadModule 활성 추가하므로
   find로 mod_jk.so 직접 복사 후 post_layout()에서 주석 처리로 추가
4. mod_jk 빌드는 Rocky 8 컨테이너 내부 또는 RHEL 8 호스트에서만
   (RHEL 10 호스트에서 빌드 시 GLIBC_2.38 심볼 오염 확인됨)
5. 네이티브 빌드 시 OS/glibc 버전 자동 감지 → 호환성 경고 표시

## 빌드 후 처리 (컨테이너 방식)
cp /Product/httpd-2.4.66-build/httpd-2.4.66-glibc2.25-compiled-v6.tar.gz \
   /Product/httpd-2.4.66-glibc2.25-compiled.tar.gz
podman rm -f httpd-build-env

## 현재 상태 (2026-04-10 기준)
- 최종 tarball(권장): httpd-2.4.66-glibc2.25-compiled-v6.tar.gz (빌드 후 생성)
- mod_jk 1.2.50 포함 (GLIBC_2.14, RHEL 8+ 호환)
- OpenSSL 3.5.6 (LTS) 적용
- 컨테이너 빌드 스크립트: httpd_build_final_v6.sh
- 네이티브 빌드 스크립트: httpd_build_native_v2.sh
- 빌드 킷: httpd-2.4.66-build-kit.tar.gz (스크립트+매뉴얼 패키지)

## 작업 요청
[여기에 원하는 작업 내용을 적어주세요]
```

---

## 작업 유형별 추가 컨텍스트

### 빌드 실패 디버깅

```
위 컨텍스트에 추가:

빌드 방식: [컨테이너 / 네이티브]
빌드 OS: [예: Rocky Linux 8, RHEL 9 등]
실패 단계: [예: openssl, mod_jk, apr 등]
에러 메시지:
  [에러 내용 붙여넣기]
로그 파일: [빌드경로]/logs/[단계]-make.log

확인해서 수정해줘.
```

### 새 컴포넌트/모듈 추가

```
위 컨텍스트에 추가:

[컴포넌트명]을 빌드 스크립트 양쪽(v5 컨테이너 + native)에 추가해줘.
- 버전: [버전]
- 다운로드 URL: [URL]
- 목적: [어떤 기능을 위한지]

주의: 추후 별도 주입이 아닌 빌드 과정(main() 흐름)에 통합해줘.
```

### 배포 경로 변경 / 운영 이슈

```
위 컨텍스트에 추가:

설치 경로: [예: /opt/apache]
설치 방식: [컨테이너 빌드 tarball / 네이티브 빌드 tarball]
증상: [예: httpd 시작 안됨, 라이브러리 로드 실패 등]
에러:
  [에러 메시지]

bin/start.sh, relocate_apache_paths.sh, env.sh 관련 스크립트를 참고해서 해결해줘.
```

### 새로운 OS에 네이티브 빌드 세팅

```
위 컨텍스트에 추가:

OS 정보: [예: Rocky Linux 9.3, Ubuntu 22.04 등]
glibc 버전: [ldd --version 결과]
패키지 매니저: [dnf / yum / apt 등]

httpd_build_native.sh가 이 환경에서 동작하도록 필요한 수정이 있으면 해줘.
```

---

## 주요 이슈 이력

| 이슈 | 원인 | 해결 |
|------|------|------|
| `apr_crypto_shutdown undefined symbol` | DT_RUNPATH → LD_LIBRARY_PATH가 번들 라이브러리 덮어씀 | DT_RPATH 강제 (--disable-new-dtags) |
| `libcrypt.so.1: cannot open` | 번들 누락 | 명시적 번들 + ldd 자동 감지 추가 |
| mod_jk GLIBC_2.38 오류 | 호스트(Rocky 10, glibc 2.39)에서 컴파일 | Rocky 8 컨테이너 내부에서 빌드 |
| patchelf `No such file or directory` | mod_jk.so 복사 전 patchelf 실행 순서 오류 | cp → patchelf 순서 수정 |
| apxs `config_vars.mk not found` | 컨테이너 마운트 경로가 원본 빌드 경로와 달라 apxs 참조 실패 | `/Product`를 동일 경로로 마운트 |
| `LoadModule jk_module` 활성 추가 문제 | `make install`이 apxs -i -a로 httpd.conf에 자동 추가 | make install 제거 → mod_jk.so 직접 복사 |

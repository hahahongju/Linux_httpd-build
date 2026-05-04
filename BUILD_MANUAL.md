# Apache HTTP Server 2.4.66 Portable Build - 사용 매뉴얼

## 개요

Apache HTTP Server 2.4.66을 **RHEL/Rocky Linux 8 이상** 환경에
설치·운영하기 위한 portable tarball 빌드 및 배포 절차를 설명합니다.

- **배포 대상**: RHEL 8 / Rocky Linux 8 이상 (glibc 2.28+)
- **포함 구성요소**: httpd 2.4.66, APR 1.7.6, APR-util 1.6.3, OpenSSL 3.5.6,
  PCRE2 10.45, zlib 1.3.1, expat 2.7.1, nghttp2 1.65.0, **mod_jk 1.2.50**
- **특징**: 모든 의존 라이브러리 번들 → 배포 대상 서버에 별도 패키지 설치 불필요

### 빌드 방식 선택

| 상황 | 권장 방식 | 스크립트 |
|------|-----------|----------|
| 빌드 서버에 Podman/Docker 있음 | **컨테이너 빌드** (Rocky 8 격리 환경) | `httpd_build_final_v6.sh` |
| 빌드 서버가 RHEL/Rocky 8 (glibc 2.28) | **네이티브 빌드** | `httpd_build_native_v2.sh` |
| 빌드 서버가 RHEL/Rocky 9 (glibc 2.34) | 네이티브 빌드 (RHEL 9+ 배포용) | `httpd_build_native_v2.sh` |
| 빌드 서버가 RHEL 10 (glibc 2.39) | **컨테이너 빌드 권장** (glibc 오염 방지) | `httpd_build_final_v6.sh` |

> **RHEL 7 미지원**: APR, APR-util, expat이 GLIBC_2.25 심볼을 사용하므로
> glibc 2.17인 RHEL 7에서는 실행 불가.

---

## 목차

1. [사전 요구사항](#1-사전-요구사항)
2. [방법 A: 컨테이너 빌드 (Podman/Docker 있는 경우)](#2-방법-a-컨테이너-빌드)
3. [방법 B: 네이티브 빌드 (컨테이너 없는 경우)](#3-방법-b-네이티브-빌드)
4. [배포 및 설치](#4-배포-및-설치)
5. [Apache 기동·관리](#5-apache-기동관리)
6. [mod_jk (Tomcat 연동) 설정](#6-mod_jk-tomcat-연동-설정)
7. [트러블슈팅](#7-트러블슈팅)

---

## 1. 사전 요구사항

### 빌드 서버 공통

| 항목 | 요구사항 |
|------|----------|
| CPU 아키텍처 | x86_64 |
| 인터넷 연결 | 소스 다운로드 필요 (약 100MB) |
| 디스크 여유 공간 | 빌드 디렉터리 기준 **5GB 이상** |
| 권한 | **root 또는 sudo** (패키지 설치 필요) |
| 빌드 소요 시간 | N100 VM 기준 약 **90분** (OpenSSL 40~45분) |

### 배포 대상 서버

| 항목 | 요구사항 |
|------|----------|
| OS | **RHEL 8 / Rocky Linux 8 이상** (glibc 2.28+) |
| 추가 패키지 | **없음** (모든 라이브러리 tarball 내 포함) |
| 디스크 | 설치 경로 기준 약 **150MB** |

---

## 2. 방법 A: 컨테이너 빌드

Podman 또는 Docker가 설치된 서버에서 Rocky Linux 8 컨테이너로 빌드합니다.
**RHEL 8 배포 호환성을 가장 안정적으로 보장하는 방법**입니다.

### 2-1. Podman 설치 (없는 경우)

```bash
# RHEL/Rocky 8/9/10
sudo dnf install -y podman
```

### 2-2. 베이스 이미지 생성 (최초 1회)

```bash
bash /opt/httpd-build-kit/make_base_image.sh

# 확인
podman images | grep httpd-build-rocky8-base
```

### 2-3. 빌드 실행

```bash
# 빌드 디렉터리 초기화
rm -rf /opt/httpd-2.4.66-build && mkdir -p /opt/httpd-2.4.66-build

# 스크립트를 /opt/httpd-build-kit 에 배치했다고 가정
podman run -d \
  -v /opt/httpd-build-kit:/Product:z \
  --name httpd-build-env \
  --user root \
  httpd-build-rocky8-base:latest \
  bash -c 'bash /Product/httpd_build_final_v6.sh \
    2>&1 | tee /Product/../httpd-2.4.66-build/build.log; \
    echo "BUILD_EXIT:$?"'
```

> **경로 참고**: `httpd_build_final_v5.sh` 내부에 `/Product/` 경로가 하드코딩되어 있습니다.
> 실행 전 스크립트 상단의 `BASE` 경로 설정을 확인하세요.

### 2-4. 빌드 모니터링

```bash
# 로그 실시간 확인
tail -f /opt/httpd-2.4.66-build/build.log

# 완료 확인 (EXIT:0 이어야 성공)
podman ps -a --filter name=httpd-build-env
```

### 2-5. 결과 tarball 복사 및 정리

```bash
cp /opt/httpd-2.4.66-build/httpd-2.4.66-glibc2.25-compiled-v6.tar.gz \
   /opt/httpd-2.4.66-glibc2.25-compiled.tar.gz

podman rm -f httpd-build-env
```

> `httpd-2.4.66-glibc2.25-compiled-local-improved-20260409.tar.gz` 는 로컬 검증용 산출물이며
> 공식 배포/운영 기준에서는 제외합니다.

---

## 3. 방법 B: 네이티브 빌드

컨테이너 없이 **호스트 OS에서 직접** 빌드합니다.

### 호환성 주의사항

| 빌드 OS | glibc | 결과물 배포 가능 범위 |
|---------|-------|----------------------|
| RHEL 8 / Rocky 8 | 2.28 | RHEL 8+ ✓ |
| RHEL 9 / Rocky 9 | 2.34 | RHEL 9+ (RHEL 8 불가) |
| RHEL 10 | 2.39 | RHEL 10+ (권장하지 않음) |

### 3-1. 스크립트 배치

```bash
# 빌드 킷을 /opt/httpd-build-kit 에 배치
mkdir -p /opt/httpd-build-kit
tar xzf httpd-2.4.66-build-kit.tar.gz -C /opt/httpd-build-kit
```

### 3-2. 빌드 실행

```bash
# 기본 실행 (빌드 경로: /opt/httpd-2.4.66-build)
bash /opt/httpd-build-kit/httpd_build_native_v2.sh

# 빌드 경로 커스터마이즈
BUILD_BASE=/data/httpd-build bash /opt/httpd-build-kit/httpd_build_native_v2.sh
```

스크립트가 자동으로 수행하는 작업:
1. OS/glibc 버전 감지 및 호환성 경고
2. 빌드 도구 설치 (`dnf groupinstall "Development Tools"`, patchelf 등)
3. 소스 다운로드 (Apache, OpenSSL, APR 등)
4. 전체 컴포넌트 빌드 및 패키징

### 3-3. 빌드 로그 확인

```bash
# 전체 로그는 터미널에 직접 출력됨
# 개별 컴포넌트 로그
ls /opt/httpd-2.4.66-build/logs/
cat /opt/httpd-2.4.66-build/logs/openssl-make.log
```

### 3-4. 결과 확인

```bash
ls -lh /opt/httpd-2.4.66-build/httpd-2.4.66-glibc2.25-compiled-v6.tar.gz

# GLIBC 요구 버전 확인
find /opt/httpd-2.4.66-build/package/apache -type f \
  | xargs -r objdump -T 2>/dev/null \
  | grep -oP '\(GLIBC_[0-9.]+\)' | sort -uV | tail -5
```

---

## 4. 배포 및 설치

빌드 서버에서 만든 tarball을 배포 대상 서버에 복사합니다.

```bash
# 배포 대상 서버에서 실행
# 예: /opt/apache 에 설치
mkdir -p /opt/apache
tar xzf httpd-2.4.66-glibc2.25-compiled-v5.tar.gz -C /opt/apache --strip-components=1

# 또는 원하는 경로에
mkdir -p /app/web/apache
tar xzf httpd-2.4.66-glibc2.25-compiled-v5.tar.gz -C /app/web/apache --strip-components=1
```

> 설치 경로는 어디든 자유롭게 지정 가능합니다.
> 첫 기동 시 `start.sh`가 경로를 자동 재설정합니다.

---

## 5. Apache 기동·관리

### 첫 기동

```bash
cd /opt/apache
sh bin/start.sh
```

첫 실행 시 `relocate_apache_paths.sh`가 자동 실행되어:
- 빌드 시 하드코딩된 경로 → 현재 설치 경로로 교체
- `DocumentRoot`/`htdocs` 경로까지 현재 설치 경로로 재설정
- `httpd -t` 설정 검증 수행

### 기동·중지·재시작·상태

```bash
sh bin/start.sh     # Apache 시작
sh bin/stop.sh      # Apache 중지
sh bin/restart.sh   # Apache 재시작 (graceful)
sh bin/status.sh    # 실행 상태 확인
```

### 다른 경로로 이전 시

```bash
# 새 경로에 압축 해제 후 start.sh 실행하면 자동 재설정
FORCE_RELOCATE=1 sh bin/start.sh
```

### 주요 설정

```bash
vi conf/httpd.conf

# 포트 변경
# Listen 80  →  Listen 8080

# 설정 검증
bin/httpd -t
```

---

## 6. mod_jk (Tomcat 연동) 설정

`modules/mod_jk.so` 포함. 기본 **비활성** 상태.

### 6-1. workers.properties 설정

```bash
cp conf/workers.properties.minimal conf/workers.properties
vi conf/workers.properties
```

```properties
worker.list=worker1
worker.worker1.type=ajp13
worker.worker1.host=127.0.0.1   # Tomcat 서버 IP
worker.worker1.port=8009         # Tomcat AJP 포트
```

### 6-2. httpd.conf 활성화

`conf/httpd.conf` 하단의 `#` 제거:

```apache
LoadModule jk_module modules/mod_jk.so
JkWorkersFile conf/workers.properties
JkLogFile logs/mod_jk.log
JkLogLevel info
JkMount /app/* worker1
```

### 6-3. 재시작

```bash
sh bin/restart.sh
```

---

## 7. 트러블슈팅

### httpd 시작 실패

```bash
# 설정 검증
sh bin/start.sh   # 내부적으로 httpd -t 수행

# 에러 로그
tail -50 logs/error_log
```

### 포트 충돌

```bash
ss -tlnp | grep :80
vi conf/httpd.conf   # Listen 80 → Listen 8080
```

### `library not found` 오류

```bash
. bin/env.sh   # LD_LIBRARY_PATH 설정
sh bin/start.sh
```

### 경로 재배치 수동 실행

```bash
FORCE_RELOCATE=1 sh bin/relocate_apache_paths.sh
```

### GLIBC 버전 오류

```bash
# 배포 서버의 glibc 버전 확인
ldd --version | head -1
# glibc 2.28 이상 필요 (RHEL 8+)
```

### 빌드 실패 시 로그

```bash
# 네이티브 빌드
ls /opt/httpd-2.4.66-build/logs/
cat /opt/httpd-2.4.66-build/logs/openssl-make.log

# 컨테이너 빌드
cat /opt/httpd-2.4.66-build/build.log | grep -E 'ERROR|error:' | head -30
```

---

## 파일 구조

```
빌드 킷 (httpd-2.4.66-build-kit.tar.gz):
├── httpd_build_final_v6.sh     # 컨테이너 빌드 스크립트
├── httpd_build_native_v2.sh    # 네이티브 빌드 스크립트
├── make_base_image.sh          # Rocky 8 베이스 이미지 생성
├── inject_mod_jk.sh            # mod_jk 개별 주입 (참고용)
├── relocate_apache_paths.sh    # 경로 재배치 (참고용)
├── BUILD_MANUAL.md             # 이 매뉴얼
└── AI_RESUME_GUIDE.md          # AI 작업 재개 가이드

설치 후 구조 (예: /opt/apache/):
├── bin/
│   ├── httpd
│   ├── start.sh / stop.sh / restart.sh / status.sh
│   ├── env.sh
│   └── relocate_apache_paths.sh
├── bins/lib/                   # 번들 라이브러리 (libssl, libapr 등)
├── conf/
│   ├── httpd.conf
│   └── workers.properties.minimal
├── modules/
│   ├── mod_ssl.so
│   ├── mod_jk.so
│   └── ...
├── logs/
└── htdocs/
```

# Apache HTTP Server 2.4.66 Portable Build Project

## 📦 프로젝트 개요

Rocky Linux 8 컨테이너를 사용하여 RHEL 8+ (glibc 2.28+)에 배포 가능한 portable tarball을 빌드합니다.

- **httpd**: 2.4.66
- **OpenSSL**: 3.5.6 (LTS)
- **mod_jk**: 1.2.50 (Tomcat 연동)
- **배포 대상**: RHEL 8, Rocky Linux 8 이상
- **GLIBC 호환성**: GLIBC 2.25 이하

## 🚀 빠른 시작

### 1. 컨테이너 빌드 (권장, 모든 환경)

```bash
# Rocky 8 베이스 이미지 생성 (최초 1회)
bash make_base_image.sh

# 빌드 실행
rm -rf /Product/httpd-2.4.66-build && mkdir -p /Product/httpd-2.4.66-build

podman run -d \
  -v /Product/APACHE_PROJECT:/Product:z \
  --name httpd-build-env \
  --user root \
  httpd-build-rocky8-base:latest \
  bash -c 'bash /Product/httpd_build_final_v7.sh 2>&1 | tee /Product/../httpd-2.4.66-build/build.log; echo "BUILD_EXIT:$?"'

# 로그 모니터링
tail -f /Product/httpd-2.4.66-build/build.log
```

### 2. 네이티브 빌드 (RHEL 8/9 호스트)

```bash
bash httpd_build_native_v3.sh
```

## 📁 폴더 구조

```
APACHE_PROJECT/
├── httpd_build_final_v7.sh      # 컨테이너 빌드 (v7, mod_jk 통합) ✅
├── httpd_build_final_v6.sh      # 컨테이너 빌드 (v6, mod_jk 별도)
├── httpd_build_native_v3.sh     # 네이티브 빌드 (v3, mod_jk 통합) ✅
├── httpd_build_native_v2.sh     # 네이티브 빌드 (v2, 기존)
├── make_base_image.sh           # Rocky 8 베이스 이미지
├── inject_mod_jk.sh             # mod_jk 개별 주입 (참고)
├── relocate_apache_paths.sh     # 경로 자동 재배치
├── BUILD_MANUAL.md              # 배포·설치 상세 가이드
├── AI_RESUME_GUIDE.md           # 작업 재개 가이드
├── resume_prompt.md             # 재개 시나리오 (3가지)
└── httpd-2.4.66-glibc2.25-compiled.tar.gz  # 완성된 바이너리 (22M)
```

## 📋 스크립트 버전 정보

### 컨테이너 빌드 (httpd_build_final_v*.sh)

| 버전 | 출시일 | OpenSSL | mod_jk | 특징 | 상태 |
|------|--------|---------|--------|------|------|
| v7 | 2026-04-11 | 3.5.6 | 통합 | mod_jk를 main 빌드에 포함 | ✅ 권장 |
| v6 | 2026-04-11 | 3.5.6 | 별도 | 재빌드 성공, GLIBC 검증 OK | ✅ 안정 |
| v5 | 2026-04-10 | 3.5.6 | 별도 | sh 호환화 (AWX 배포) | 유지 |
| v4 | 2026-04-09 | 3.0.17 | 별도 | DT_RPATH, mod_jk 포함 | 참고 |
| 이전 | - | - | - | 초기 버전 | 참고 |

### 네이티브 빌드 (httpd_build_native_v*.sh)

| 버전 | 출시일 | 특징 |
|------|--------|------|
| v3 | 2026-04-11 | ✅ mod_jk 메인 빌드 통합 (권장) |
| v2 | 2026-04-10 | mod_jk 별도 빌드 (안정) |
| v1 | - | 초기 버전 |

## ✨ v7/v3 개선사항

### 이전 (v6/v2)
```
build_httpd()     → httpd 컴파일/설치
build_mod_jk()    → mod_jk 별도 빌드 (apxs 기반)
```

### 신규 (v7/v3)
```
build_httpd_with_mod_jk()
  ├─ Phase 1: httpd 컴파일/설치 (apxs 생성)
  └─ Phase 2: mod_jk 빌드 (apxs 즉시 사용)
```

**장점**
- 메인 빌드 흐름 명확화
- 함수 간결화 (build_mod_jk 제거)
- 의존성 명시 (Phase 1→2)

## 📦 배포 방법

```bash
# 배포 대상 서버
mkdir -p /opt/apache
tar xzf httpd-2.4.66-glibc2.25-compiled.tar.gz -C /opt/apache --strip-components=1
cd /opt/apache
sh bin/start.sh
```

`start.sh` 실행 시 자동으로:
- 경로 재배치 (relocate_apache_paths.sh)
- httpd 설정 검증
- Apache 시작

## 🔗 문서

- **BUILD_MANUAL.md**: 상세 빌드·배포 절차
- **AI_RESUME_GUIDE.md**: AI 작업 재개 가이드
- **resume_prompt.md**: 3가지 재개 시나리오

## 📝 주요 특징

- ✅ **Portable**: 모든 의존 라이브러리 번들
- ✅ **GLIBC 호환**: RHEL 8+ 배포 가능
- ✅ **mod_jk 포함**: Tomcat AJP 연동 준비
- ✅ **자동 경로 설정**: 설치 경로 자동 재배치
- ✅ **sh 호환**: AWX 등 sh 환경 지원

## 🛠️ 빌드 환경

### 컨테이너 빌드
- **OS**: Rocky Linux 8.9 (glibc 2.28)
- **GCC**: 8.5.0
- **Threads**: 4 (자동 감지)

### 예상 소요 시간
- 컴파일 단계: ~46분
- gzip 압축: ~2시간 6분
- **총합**: ~3시간 (N100 VM 기준)

## 📞 참고

- 메인 프로젝트: `/Product/`
- 빌드 로그: `/Product/httpd-2.4.66-build/build.log`
- 메모리: `/root/.claude/projects/-Product/memory/`

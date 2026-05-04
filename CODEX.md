# CODEX.md

## 프로젝트 개요
- 프로젝트명: `OpenSource-Mddileware-Patch`
- 목적: AWX/Ansible 기반 Tomcat 패치/롤백 자동화
- 주요 경로: `ansible/OpenSource-Mddileware-Patch/awx-tomcat-project`

## 자주 쓰는 명령어

### 1) 문법 검증
```bash
cd ansible/OpenSource-Mddileware-Patch/awx-tomcat-project
ansible-playbook --syntax-check -i inventory/hosts.ini playbooks/tomcat_patch.yml
ansible-playbook --syntax-check -i inventory/hosts.ini playbooks/rollback.yml
```

### 2) 패치 실행
```bash
ansible-playbook -i inventory/hosts.ini playbooks/tomcat_patch.yml
```

### 3) 롤백 실행
```bash
# 최신 백업 기준
ansible-playbook -i inventory/hosts.ini playbooks/tomcat_patch.yml -e "rollback=true"

# 명시적 롤백 플레이북
ansible-playbook -i inventory/hosts.ini playbooks/rollback.yml -e "rollback_target=latest"
```

### 4) 압축 배포본 생성
```bash
cd ansible/OpenSource-Mddileware-Patch
out="awx-tomcat-project-$(date +%Y%m%d_%H%M%S).tar.gz"
tar -czf "$out" awx-tomcat-project
ls -lh "$out"
```

## 최근 반영된 핵심 수정
- `bin/lib` 교체 후 커스터마이징 재적용
  - `setenv.sh` 복원
  - `lib` 누락 커스텀 jar 병합
- 기동 판정 강화
  - 즉시 기동 확인 + 안정화 대기 후 재확인
  - 인스턴스별 JVM 상태 확인으로 성공 판정
- 롤백 경로 통합
  - `rollback=true` 시 구 `rollback_instance.yml` 대신 통합 `rollback` role 사용

## 운영 체크 포인트
- AWX 로그에서 `Tomcat started` 문구만으로 성공 판단하지 말 것
- 안정화 재확인 태스크 통과 여부 확인
- `Error_note/job_*.txt`에서 인스턴스별 실패 지점 확인

## 주의
- Git 워크트리 정리(`.gitignore`/이동 반영)는 최종 완료 시점에 수행

## Daily Summary Reference
- 작업 시작 시 아래 경로를 **1회 참고**해서 전일/당일 맥락을 확인합니다.
- 경로: `/Users/hongjulee/Library/CloudStorage/GoogleDrive-haha.hongju@gmail.com/내 드라이브/hjl/02_logs/conversation_logs`
- 용도: 하루 진행 내용을 요약 정리한 공용 저장소(결정사항/이슈/다음 액션 확인)
- 원칙: 참고만 하고, 실제 수정 범위는 현재 프로젝트 루트로 제한합니다.

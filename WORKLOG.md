# WORKLOG

## Rules
- 최신 작업부터 위에 추가
- 항목 형식: 날짜 / 작업 / 이슈 / 다음 액션

## Entries
### 2026-04-07
- 작업: 프로세스 판정식 정밀화 - 셸 프로세스 오탐 방지를 위해 `ps -eo pid,user,comm,args` 기준으로 `comm=java` 및 `-Dcatalina.home=<instance path>` 매칭 조건 추가
- 이슈: 기존 판정식은 AWX shell 명령 문자열(예: `org.apache...` 포함)을 JVM으로 오인할 가능성 확인
- 다음 액션: AWX 재실행 시 Egene 판정 PID가 실제 Java PID인지(`comm=java`, `-Dcatalina.home` 일치) 확인

- 작업: 계정 하드코딩 제거 - 프로세스 판정/종료/검증 로직의 `wasadmin` 비교를 `tomcat_process_user`(기본 `ansible_user`, fallback `wasadmin`) 기반으로 변수화
- 이슈: 계정 고정 시 타 환경(다른 운영 계정)에서 오탐/미탐 가능성
- 다음 액션: AWX Job Template에서 `tomcat_process_user` 지정(필요 시) 후 실제 운영 계정으로 판정되는지 확인

- 작업: 사용자 재현 로그 기반 오탐 방지 강화 - 패치/롤백/사후검증의 기동 판정을 `Bootstrap + catalina_home + wasadmin` 기준으로 통일하고 `tomcat.pid` 유효성(실제 PID 매칭) 검증 추가
- 이슈: AWX 로그는 정상완료이나 실제 `tomcat.pid`가 stale PID를 가리키는 케이스 재현됨(실제 JVM 미기동)
- 다음 액션: AWX 재실행 후 `PID_STALE` 즉시 실패 여부와 Egene 실프로세스(`Bootstrap start`) 유지 여부 확인

- 작업: `job_94` 로그 기반 추가 픽스 - 패치/롤백 기동 직전에 `CATALINA_OUT`, `-Xloggc` 경로 디렉토리를 자동 생성하도록 보정 태스크 추가
- 이슈: 로그 경로 누락 시 `mv: cannot stat .../catalina.out`, `Cannot open file .../gclog/gc.log` 경고/실패 가능성 확인
- 다음 액션: AWX 재실행 후 DIAG의 `CATALINA_OUT PATH`와 GC 로그 경로가 생성됐는지 확인

- 작업: `job_94` 로그 기준 기능 픽스 - 종료 대상 PID 탐지를 `pgrep -f catalina_home`에서 `Bootstrap + catalina_home + wasadmin` 조건으로 강화하고, kill 시 자기 프로세스(`$$`, `$PPID`) 제외 처리
- 이슈: 기존 종료 루틴에서 경로 문자열 오탐으로 `ALIVE` 오판정 및 `rc=-15` 발생 가능성 확인
- 다음 액션: AWX 패치 Job 재실행 후 Egene 종료 판정이 `STOPPED`로 통과하는지 확인

- 작업: `patch_instance.yml`에서 Tomcat 미종료(ALIVE) 상태 시 경고 후 진행하던 흐름을 즉시 중단(`fail`)하도록 수정
- 이슈: 없음
- 다음 액션: AWX에서 패치 Job 1회 실행하여 ALIVE 분기 시 실제 중단 동작과 메시지 확인

### 2026-04-06
- 작업: 프로젝트별 독립 컨텍스트 운영 파일 초기화
- 이슈: 없음
- 다음 액션: 실제 작업 시 결과와 이슈를 계속 누적 기록

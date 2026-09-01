# CI/CD (GitHub Actions)

StackBox 플랫폼 저장소의 CI/CD 구성입니다.

## 워크플로

| 파일 | 트리거 | 내용 |
|---|---|---|
| `.github/workflows/ci.yml` | PR, `main` push | 4개 잡 병렬 실행 |
| `.github/workflows/deploy.yml` | `main` push (관련 경로), 수동(`workflow_dispatch`) | GHCR 이미지 빌드/푸시 + 서버 SSH 배포 |

## CI (`ci.yml`)

| 잡 | 실행 내용 |
|---|---|
| `integration-test` | `docker-compose.test.yml` 전체 스택 기동 → `tester` 스모크 테스트 (전 서비스 health 확인) |
| `backend-test` | Elixir: `mix compile --warnings-as-errors` + `mix test` (Postgres/Redis 서비스 컨테이너 사용) |
| `frontend-test` | `npm ci` → `eslint` → `tsc --noEmit` → `next build` |
| `web-worker-test` | `cargo test` (web_worker/code_runner/ppt_builder) |

> **web-worker-test 참고**: code_runner의 C/C++ 테스트는 실제 컴파일러를 `RLIMIT_NPROC` 제한 하에서 실행합니다. 개발 머신(같은 UID로 실행 중인 다른 프로세스가 많은 호스트)에서는 이 테스트들이 간헐적으로 실패할 수 있습니다(`code_runner.rs`의 `COMPILE_NPROC_LIMIT` 주석 참조). CI는 전용 VM이라 해당 문제가 없습니다.

## CD (`deploy.yml`)

1. `build-and-push`: 4개 이미지를 GHCR에 빌드/푸시
   - `ghcr.io/{owner}/stackbox-backend`
   - `ghcr.io/{owner}/stackbox-frontend`
   - `ghcr.io/{owner}/stackbox-web-worker`
   - `ghcr.io/{owner}/stackbox-code-runner`
   - 태그: `latest` + `sha-<short>`
2. `deploy`: SSH로 서버 접속 → `git pull` + 서브모듈 갱신 → GHCR 로그인 → `docker compose pull` → `docker compose up -d --wait` → nginx 경유 backend health check → `docker image prune -f`

`docker-compose.yml`의 각 서비스에 `image:`가 지정되어 있어 서버는 빌드 없이 GHCR 이미지를 풀해서 사용합니다. 로컬 개발은 기존대로 `docker compose up --build`로 동작합니다.

> **롤백**: 빌드 시 `sha-<short>` 불변 태그도 함께 푸시됩니다. 서버에서 직전 커밋으로 되돌리려면 `git checkout <commit>` 후 `.env`의 이미지 태그를 그 커밋의 `sha-<short>`로 바꾸거나, 서버에서 `docker compose pull` 대신 `docker compose up -d --no-build` 전에 `docker pull ghcr.io/{owner}/stackbox-<svc>:sha-<short>`로 직접 받아 태그를 붙이면 됩니다 (`latest`는 항상 마지막 push를 가리키므로 롤백 수단으로는 쓰지 마세요).

## 배포 준비 (최초 1회)

### 1. GitHub Actions secrets 설정

저장소 **Settings → Secrets and variables → Actions** 에 등록:

| Secret/Variable | 값 |
|---|---|
| `DEPLOY_HOST` | 배포 서버 IP/도메인 (secret) |
| `DEPLOY_USER` | SSH 접속 사용자 (secret) |
| `DEPLOY_SSH_KEY` | 배포 전용 SSH 프라이빗 키 (secret) |
| `DEPLOY_PORT` | SSH 포트, 기본 22 (secret, 선택) |
| `DEPLOY_PATH` | 서버에서 저장소가 클론된 절대 경로 (secret) |
| `DEPLOY_GHCR_USERNAME` | GHCR 읽기 전용 PAT의 GitHub 사용자명 (secret) |
| `DEPLOY_GHCR_TOKEN` | GHCR 읽기 전용 PAT (`read:packages`만 있으면 충분, secret) |
| `NEXT_PUBLIC_API_URL` | 브라우저가 쓰는 API base URL, 예: `https://stackbox.example.com/api` (variable) |
| `NEXT_PUBLIC_WORKER_URL` | WS base URL, 예: `wss://stackbox.example.com/worker` (variable) |
| `DEPLOY_DOMAIN` | `NEXT_PUBLIC_*` 미설정 시 폴백 도메인 (variable, 선택) |

**GHCR 인증 (빌드 vs 서버):**
- **빌드** (`build-and-push`): CI가 `GITHUB_TOKEN`(`packages: write`)으로 로그인하므로 별도 설정이 필요 없습니다.
- **서버** (`deploy`): GHCR 패키지는 기본적으로 **private**라서 서버가 익명으로는 pull할 수 없습니다. 아래 서버 준비의 `DEPLOY_GHCR_TOKEN`(read-only PAT)으로 `docker login ghcr.io`를 수행합니다. PAT 발급은 `https://github.com/settings/tokens` → *Fine-grained tokens* → `read:packages` 권한, 리포지토리는 이 저장소로 제한. (clone 계정과 같은 사용자명/토큰이어야 합니다.)

### 2. 서버 준비

```bash
# 1) 배포 전용 SSH 키 생성 후 공개키를 서버 authorized_keys에 등록,
#    프라이빗 키를 DEPLOY_SSH_KEY secret으로 등록
ssh-keygen -t ed25519 -f ~/.ssh/stackbox_deploy -N ""

# 2) 서버에서 저장소 클론 (DEPLOY_PATH가 가리키는 위치)
git clone --recurse-submodules \
  https://github.com/2026-Sunrin-Vacation-Project-TEAM6/stackbox-platform.git \
  /opt/stackbox

# 3) .env 생성 (저장소의 .env.example 참고)
cd /opt/stackbox
cp .env.example .env
# → 실제 값 입력 (SECRET_KEY_BASE 등 필수)

# 4) GHCR 로그인 (DEPLOY_GHCR_USERNAME / DEPLOY_GHCR_TOKEN secret과 동일한 값)
#    read:packages만 있는 Fine-grained PAT로 발급받은 토큰 사용
echo "$DEPLOY_GHCR_TOKEN" | docker login ghcr.io -u "$DEPLOY_GHCR_USERNAME" --password-stdin

# 5) TTY 없이 sudo 없이 docker를 쓸 수 있게 (배포 유저가 docker 그룹에 속하도록)
sudo usermod -aG docker "$(whoami)"
```

서버 전제조건: **docker compose v2.20+** (`up -d --wait` 지원)와 **curl** (배포 후 health check에 사용).

이후 `main`에 push하면 GHCR push → 서버 자동 배포가 실행됩니다.
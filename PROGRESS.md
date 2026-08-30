# StackBox 진행 상황

_최종 업데이트: 2026-08-28_

## 1. 실시간 협업(WebSocket) 스택 검증
- `web_worker` (Rust/Axum) 기반 realtime 서비스에서 두 명의 인증된 사용자가 동시 접속했을 때:
  - presence/cursor broadcast가 서로에게 정상 relay 되는지 확인
  - 클라이언트가 보낸 `user_id`를 서버가 무시하고 JWT에서 뽑은 값으로 강제 stamping 하는지 확인
  - 늦게 접속한 사용자가 DB에서 presence snapshot을 받아오는지 확인
- 위 세 가지 모두 정상 동작 확인 완료.

### ✅ 해결됨 — nginx 실시간 WS 라우팅 버그 (2026-08-28)
- **원인**: `web_worker`는 `/ws/{stack_box_id}`에서 WS를 서비스하지만, nginx는 `location /worker/`에서만 `web_worker`로 프록시한다. 프론트 `socket.ts`는 설정된 base URL 뒤에 `/ws/{stackBoxId}`를 붙이는데, `.env.example`의 browser-facing 값이 `NEXT_PUBLIC_WORKER_URL=wss://localhost/ws`여서 실제 연결 경로가 `wss://localhost/ws/ws/{id}`가 되어 nginx `location /`(default → frontend)로 새어나가 실시간 협업이 성립하지 않았다.
  - 추가로 `.env.example`에 `NEXT_PUBLIC_WORKER_URL`/`NEXT_PUBLIC_API_URL`이 **중복 정의**되어 있었고(54행과 64행), compose는 마지막 정의(`ws://localhost:3000`)를 우선했으나 `web_worker`는 `expose`만 되어 있어 브라우저가 직접 접근 불가 → 어느 쪽이든 깨짐.
- **조치**: `.env.example`의 browser-facing `NEXT_PUBLIC_WORKER_URL`을 `wss://localhost/worker`로 수정하고, 충돌하는 중복 정의(직접 localhost 포트)를 제거해 한 곳에서만 정의되게 정리.
  - 이제 클라이언트는 `wss://localhost/worker/ws/{id}?token=...`로 연결 → nginx `/worker/` 스트립 → `web_worker/ws/{id}` → 핸드셰이크 성립 (worker가 `?token=` JWT 검증 + 접근 권한 확인 — `main.rs ws_handler`).
- **검증**: `frontend/lib/realtime/socket.ts`의 base URL append 로직, `nginx/nginx.conf`의 `/worker/` location, `web_worker/src/main.rs`의 `/ws/{stack_box_id}` 라우트 + `verify_token`을 교차 확인해 배선 무결성 입증.
- GitHub OAuth 라우팅은 정상임을 재확인: `/api/github/authorize-url`은 frontend 전용 exact match, `/api/github/oauth/callback`은 `/api/` prefix로 backend `github.py`에 정확히 흐름.

## 2. 환경변수(.env) 정리
- 루트에 `.env`, `.env.example` 생성. `db`, `backend`, `web_worker`, `code_runner` 4개 서비스가 실제로 사용하는 모든 환경변수를 포함.
- `docker-compose.yml`의 하드코딩된 값들을 전부 `${VAR}` 방식으로 교체해서 `.env` 값이 실제로 반영되도록 연동.
  - `backend` / `web_worker`에 `JWT_SECRET`, `JWT_ALGORITHM`을 동일하게 명시 (두 서비스가 같은 시크릿을 써야 토큰 검증이 통과됨).
- `.gitignore`에 `.env` 추가해서 실제 시크릿 값이 git에 올라가지 않도록 처리. `git check-ignore -v .env`로 무시되는 것 확인.
- `docker compose config`로 최종 치환 결과를 두 번 검증 (환경변수 세팅 직후, `TOKEN_ENCRYPTION_KEY` 추가 후).
- `backend`가 CORS 허용 origin을 하드코딩 대신 `CORS_ALLOWED_ORIGINS` env로 읽도록 수정(`dd47780`), 루트 `docker-compose.yml`도 이 변수를 backend 서비스에 전달하도록 커밋 완료(`b52c162`).

### ✅ 해결됨 — 쉘 환경변수 충돌
- 쉘에 `OPENAI_API_KEY`, `OPENAI_MODEL`, `OPENAI_BASE_URL` 세 개 모두 export 되어 있음 (Claude Code 프로바이더 프록시 설정).
- Docker Compose는 `.env` 파일보다 쉘 환경변수를 우선 → `backend` 컨테이너에 엉뚱한 값이 들어가는 문제.
- **조치**: `.env`/`.env.example`의 키를 `BACKEND_OPENAI_*`로 변경, `docker-compose.yml`도 이 이름으로 치환. 컨테이너 내부 env 이름은 `OPENAI_*` 유지 (Python 코드가 기대하는 이름).

## 3. GitHub OAuth 연동
- `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` 발급 방법 안내 (GitHub OAuth App 등록, callback URL은 `backend/app/routers/github.py`의 콜백 경로와 정확히 일치해야 함).
- 실제 값 `.env`에 채워 넣음.

## 4. 토큰 암호화 키 (TOKEN_ENCRYPTION_KEY)
- `backend/app/crypto.py`에서 GitHub OAuth access token을 저장 전에 `Fernet`으로 암호화하는 데 사용.
- Fernet 키(32바이트, url-safe base64) 새로 생성해서 `.env`에 채워 넣음.

## 5. OpenAI Base URL 커스터마이징 기능 추가
- `openai_api_key` 바로 아래에 `openai_base_url` 설정 추가 (`backend/app/config.py`).
- `backend/app/ai_client.py`의 `_get_client()`가 `base_url`이 비어있으면 `None`을 넘겨서 OpenAI SDK 기본 엔드포인트를 자동으로 쓰도록 수정.

## 6. nginx 리버스 프록시 (프로덕션, 도메인 + Let's Encrypt)
- 단일 nginx 엔트리포인트(80/443)로 `frontend`(`/`), `backend`(`/api/`), `web_worker`(`/worker/`) 라우팅.
- `nginx/templates/default.conf.template`, `nginx/init-letsencrypt.sh` 추가. `docker-compose.yml`에 `nginx` 서비스 추가, 서비스별 host 포트 노출 제거(`web_worker`, `code_runner`, `frontend`는 `expose`).
- `.env.example`에 `DOMAIN`/`CERTBOT_EMAIL`(placeholder), `CORS_ALLOWED_ORIGINS`, `NEXT_PUBLIC_API_URL=https://localhost/api`, `NEXT_PUBLIC_WORKER_URL=wss://localhost/worker` (2026-08-28 수정) 추가.
- **상태**: 루트 저장소에 커밋 완료. 실제 도메인 연결 전까지는 `localhost` 기준으로 동작.

## 7. Elixir/Phoenix 백엔드 재작성 + PPT 기능 Rust 이관

### Part A — `backend` 서브모듈, 브랜치 `migration/elixir-phoenix-backend`
- Phase 1 (스켈레톤 + 핵심 리소스): **완료**. `mix phx.new` 스켈레톤, 12개 테이블 Ecto 마이그레이션, Guardian JWT 인증, RBAC, HTTP 컨트롤러 레이어, 테스트 커버리지, 보안 리뷰 저-심각도 findings 수정까지 완료. 원격에 push 완료 (`f451e94`).
- Phase 2 (나머지 기능): **구현 완료, 별도 PR로 분리, 리뷰/머지 대기 중**.
  - `feat/elixir-ai-github-codeexec` (PR [backend#5](https://github.com/2026-Sunrin-Vacation-Project-TEAM6/stackbox-backend/pull/5)): GitHub OAuth, AI, code_exec 프록시 구현. OAuth callback 라우팅 버그 발견·수정.
  - `feat/elixir-docs-crdt` (PR [backend#6](https://github.com/2026-Sunrin-Vacation-Project-TEAM6/stackbox-backend/pull/6)): Phoenix Channel 기반 실시간 문서 협업.
- 두 PR 병합 순서 무관. `migration/elixir-phoenix-backend` → `main` PR은 이 둘이 머지된 뒤 생성 예정.
- 아직 `mix ecto.migrate` 실제 DB 대상 검증 전 (compile/test만 확인됨).

### Part B — `web_worker` 서브모듈, 브랜치 `feat/ppt-rust-builder` (PR [web_worker#2](https://github.com/2026-Sunrin-Vacation-Project-TEAM6/web_worker/pull/2))
- `src/bin/ppt_builder.rs`: OpenAI로 슬라이드 개요 생성 → `ppt-rs`로 `.pptx` 빌드. `cargo build` 클린. 실제 OpenAI 호출 → `.pptx` end-to-end 검증 전 (backend `doc-to-ppt` 머지 필요).

## 8. 병렬 워크트리 작업 (`.worktrees/`) — 결과

| 워크트리 | 브랜치 | 대상 저장소 | 상태 |
|---|---|---|---|
| `backend-repo-docs` | `feat/repo-architecture-docs` | backend | ✅ PR [backend#4](https://github.com/2026-Sunrin-Vacation-Project-TEAM6/stackbox-backend/pull/4) |
| `frontend-diagram-exec` | `feat/diagram-code-exec-link` | frontend | ✅ PR [frontend#3](https://github.com/2026-Sunrin-Vacation-Project-TEAM6/stackbox-frontend/pull/3) |
| `frontend-multilang` | `feat/code-runner-multi-lang` | frontend | ✅ PR [frontend#4](https://github.com/2026-Sunrin-Vacation-Project-TEAM6/stackbox-frontend/pull/4) |
| `web_worker-merge-codeexec` | `feat/code-runner-merged` | web_worker | ✅ PR [web_worker#3](https://github.com/2026-Sunrin-Vacation-Project-TEAM6/web_worker/pull/3) — Redis 캐싱 + 멀티랭귀지 병합(build/test 25/25/clippy 클린) |
| `web_worker-ppt-builder` | `feat/ppt-rust-builder` | web_worker | ✅ PR [web_worker#2](https://github.com/2026-Sunrin-Vacation-Project-TEAM6/web_worker/pull/2) |
| `backend-elixir-phase1` | `migration/elixir-phoenix-backend` | backend | ✅ 원격 push 완료 (PR은 Phase 2 머지 후 main 대상 생성 예정) |
| `backend-elixir-ai-github` | `feat/elixir-ai-github-codeexec` | backend | ✅ PR [backend#5](https://github.com/2026-Sunrin-Vacation-Project-TEAM6/stackbox-backend/pull/5) |
| `backend-elixir-docs-crdt` | `feat/elixir-docs-crdt` | backend | ✅ PR [backend#6](https://github.com/2026-Sunrin-Vacation-Project-TEAM6/stackbox-backend/pull/6) |
| `backend-code-exec-caching` | `feat/code-exec-redis-cache` | backend | ✅ 이미 `origin/main`에 반영 (별도 PR 불필요) |

## 다음에 할 일
- [x] 위 7개 PR 리뷰 + 머지 완료 (2026-08-30): backend#4/#5/#6, frontend#3/#4, web_worker#2/#3
- [x] fix PR 생성·머지 (2026-08-30): frontend#5(이벤트 베이스64url), backend#7(rate-limit/github), web_worker#4(WS 프레임 제한)
- [x] Elixir/Phoenix로 FastAPI **완전 대체** 결정 → backend#9 머지 (2026-08-30) — FastAPI(`app/`, `requirements.txt`) 삭제, Elixir 멀티스테이지 Dockerfile + `Stackbox.Release.migrate` 마이그레이션 부트
- [x] Guardian HS256 맞춤 (backend#10, 2026-08-30): web_worker 검증기와 토큰 알고리즘 일치 (`allowed_algos: ["HS256"]`, `verify_issuer: false`)
- [x] 루트 compose/.env: DATABASE_URL → `postgres://`(Ecto scheme), `SECRET_KEY_BASE`/`PHX_HOST`/`POOL_SIZE` 추가 (2026-08-30)
- [x] 서브모듈 3개(`backend`, `frontend`, `web_worker`) 초기화 완료 (2026-08-28)
- [x] 실시간 WS 라우팅 버그(.env.example) 수정 완료 (2026-08-28)
- [x] Elixir 이미지 빌드 + 부팅 검증 (2026-08-30): `mix compile --warnings-as-errors` + `mix release` 통과, 런타임 이미지가 설정 로드 후 Postgres 연결 시도까지 확인; Guardian HS256 설정 로딩 검증
- [ ] `docker compose up`으로 전체 스택 실제 기동 테스트 ⚠️ 이 환경은 `podman compose` 미지원이라 호스트에서 실행 필요 (DB/Redis 포함 Elixir 부팅 확인)
- [ ] `mix ecto.migrate` 실제 DB 대상 최초 마이그레이션 적용 검증 (`Stackbox.Release.migrate` 부트 경로)
- [ ] Rust `ppt_builder`: 실제 OpenAI 호출로 `.pptx` 생성 검증 (backend `doc-to-ppt`와 연동 후)

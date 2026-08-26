# StackBox 진행 상황

_최종 업데이트: 2026-08-26_

## 1. 실시간 협업(WebSocket) 스택 검증
- `web_worker` (Rust/Axum) 기반 realtime 서비스에서 두 명의 인증된 사용자가 동시 접속했을 때:
  - presence/cursor broadcast가 서로에게 정상 relay 되는지 확인
  - 클라이언트가 보낸 `user_id`를 서버가 무시하고 JWT에서 뽑은 값으로 강제 stamping 하는지 확인
  - 늦게 접속한 사용자가 DB에서 presence snapshot을 받아오는지 확인
- 위 세 가지 모두 정상 동작 확인 완료.

## 2. 환경변수(.env) 정리
- 루트에 `.env`, `.env.example` 생성. `db`, `backend`, `web_worker`, `code_runner` 4개 서비스가 실제로 사용하는 모든 환경변수를 포함.
- `docker-compose.yml`의 하드코딩된 값들을 전부 `${VAR}` 방식으로 교체해서 `.env` 값이 실제로 반영되도록 연동.
  - `backend` / `web_worker`에 `JWT_SECRET`, `JWT_ALGORITHM`을 동일하게 명시 (두 서비스가 같은 시크릿을 써야 토큰 검증이 통과됨).
- `.gitignore`에 `.env` 추가해서 실제 시크릿 값이 git에 올라가지 않도록 처리. `git check-ignore -v .env`로 무시되는 것 확인.
- `docker compose config`로 최종 치환 결과를 두 번 검증 (환경변수 세팅 직후, `TOKEN_ENCRYPTION_KEY` 추가 후).
- `backend`가 CORS 허용 origin을 하드코딩 대신 `CORS_ALLOWED_ORIGINS` env로 읽도록 수정(`dd47780`), 루트 `docker-compose.yml`도 이 변수를 backend 서비스에 전달하도록 커밋 완료(`b52c162`).

### ✅ 해결됨 — 쉘 환경변수 충돌
- 확인해보니 쉘에 `OPENAI_API_KEY`, `OPENAI_MODEL`, `OPENAI_BASE_URL` 세 개 모두 export 되어 있었음 (Claude Code 프로바이더 프록시 설정으로 보임).
- Docker Compose는 `.env` 파일보다 쉘 환경변수를 우선하기 때문에, 그대로 두면 `backend` 컨테이너에 `.env`에 적은 값이 아니라 쉘에 있던 값(엉뚱한 키/모델/엔드포인트)이 들어감.
- **조치**: `.env`/`.env.example`의 키를 `OPENAI_API_KEY` → `BACKEND_OPENAI_API_KEY`, `OPENAI_MODEL` → `BACKEND_OPENAI_MODEL`, `OPENAI_BASE_URL` → `BACKEND_OPENAI_BASE_URL`로 변경. `docker-compose.yml`도 이 이름으로 치환하도록 수정.
  - 컨테이너 내부 환경변수 이름은 그대로 `OPENAI_API_KEY` 등 (Python 코드가 기대하는 이름) — 호스트에서 값을 가져올 때 쓰는 이름만 바꿔서 쉘과 충돌하지 않게 함.
- `docker compose config`로 재검증: `backend` 서비스의 `OPENAI_API_KEY`/`OPENAI_BASE_URL`이 빈 값, `OPENAI_MODEL`이 `gpt-4o-mini`로 `.env` 값과 정확히 일치하는 것 확인 완료.

## 3. GitHub OAuth 연동
- `GITHUB_CLIENT_ID` / `GITHUB_CLIENT_SECRET` 발급 방법 안내 (GitHub OAuth App 등록, callback URL은 `backend/app/routers/github.py`의 콜백 경로와 정확히 일치해야 함).
- 실제 값 `.env`에 채워 넣음.

## 4. 토큰 암호화 키 (TOKEN_ENCRYPTION_KEY)
- `backend/app/crypto.py`에서 GitHub OAuth access token을 저장 전에 `Fernet`으로 암호화하는 데 사용.
- Fernet 키(32바이트, url-safe base64) 새로 생성해서 `.env`에 채워 넣음.

## 5. OpenAI Base URL 커스터마이징 기능 추가
- `openai_api_key` 바로 아래에 `openai_base_url` 설정 추가 (`backend/app/config.py`).
- `backend/app/ai_client.py`의 `_get_client()`가 `base_url`이 비어있으면 `None`을 넘겨서 OpenAI SDK 기본 엔드포인트(`https://api.openai.com/v1`)를 자동으로 쓰도록 수정.
- `.env`, `.env.example`, `docker-compose.yml`에 `OPENAI_BASE_URL` 항목 동일하게 추가 (기본은 빈 값).

## 6. nginx 리버스 프록시 (프로덕션, 도메인 + Let's Encrypt)
- 단일 nginx 엔트리포인트(80/443)로 `frontend`(`/`), `backend`(`/api/`), `web_worker`(`/ws/`) 라우팅.
- `nginx/templates/default.conf.template`, `nginx/init-letsencrypt.sh` 추가. `docker-compose.yml`에 `nginx`/`certbot` 서비스 추가, 3개 서비스의 host 포트 노출 제거.
- `.env.example`에 `DOMAIN`/`CERTBOT_EMAIL`(placeholder), `CORS_ALLOWED_ORIGINS`, `NEXT_PUBLIC_API_URL=https://localhost/api`, `NEXT_PUBLIC_WORKER_URL=wss://localhost/ws` 추가.
- **상태**: 루트 저장소에 커밋 완료. 실제 도메인 연결 전까지는 `localhost` 기준으로 동작.

## 7. Elixir/Phoenix 백엔드 재작성 + PPT 기능 Rust 이관

### Part A — `backend` 서브모듈, 브랜치 `migration/elixir-phoenix-backend`
- Phase 1 (스켈레톤 + 핵심 리소스): **완료**. `mix phx.new` 스켈레톤, 12개 테이블 Ecto 마이그레이션, Guardian JWT 인증, RBAC, HTTP 컨트롤러 레이어, 테스트 커버리지, 보안 리뷰 저-심각도 findings 수정까지 완료. 원격에 push 완료 (`f451e94`).
- Phase 2 (나머지 기능): **구현 완료, 별도 PR로 분리, 리뷰/머지 대기 중**.
  - `feat/elixir-ai-github-codeexec` (PR [backend#5](https://github.com/2026-Sunrin-Vacation-Project-TEAM6/stackbox-backend/pull/5), base `migration/elixir-phoenix-backend`): GitHub OAuth, AI(summarize/fix-code/draft/chat/doc-to-ppt), code_exec 프록시 구현. `mix compile --warnings-as-errors` / `mix test`(32/32) 클린. OAuth callback 라우팅 버그(인증 파이프라인에 걸려 항상 401 나던 문제) 발견·수정함.
  - `feat/elixir-docs-crdt` (PR [backend#6](https://github.com/2026-Sunrin-Vacation-Project-TEAM6/stackbox-backend/pull/6), base `migration/elixir-phoenix-backend`): Phoenix Channel 기반 실시간 문서 협업(presence + doc update). `mix test`(36/36) 클린, JWT 강제 스탬핑/RBAC/presence spoofing 방지 테스트 포함.
  - 두 PR 모두 서로 독립적인 파일을 건드리므로 병합 순서 무관. `migration/elixir-phoenix-backend` → `main` PR은 이 둘이 머지된 뒤에 생성할 것.
- 아직 `mix ecto.migrate` 실제 DB 대상 검증 전 (compile/test만 확인됨).

### Part B — `web_worker` 서브모듈, 브랜치 `feat/ppt-rust-builder` (PR [web_worker#2](https://github.com/2026-Sunrin-Vacation-Project-TEAM6/web_worker/pull/2))
- `src/bin/ppt_builder.rs`: OpenAI로 슬라이드 개요 생성 → `ppt-rs`로 `.pptx` 빌드, `code_runner.rs`와 동일한 공유 시크릿 헤더 인증 패턴. Dockerfile 런타임 스테이지(네트워크 egress 포함)까지 완료.
- `cargo build` 클린. 아직 실제 OpenAI 호출 → `.pptx` end-to-end 검증 전 — Part A의 `doc-to-ppt` 엔드포인트(PR backend#5)가 머지되어야 실제 연동 테스트 가능.

## 8. 병렬 워크트리 작업 (`.worktrees/`) — 결과

| 워크트리 | 브랜치 | 대상 저장소 | 상태 |
|---|---|---|---|
| `backend-repo-docs` | `feat/repo-architecture-docs` | backend | ✅ PR [backend#4](https://github.com/2026-Sunrin-Vacation-Project-TEAM6/stackbox-backend/pull/4) (AI 저장소 구조 분석 엔드포인트) |
| `frontend-diagram-exec` | `feat/diagram-code-exec-link` | frontend | ✅ PR [frontend#3](https://github.com/2026-Sunrin-Vacation-Project-TEAM6/stackbox-frontend/pull/3) (다이어그램-코드블록 연동, flow 순서 실행, 에러 상태 표시) |
| `frontend-multilang` | `feat/code-runner-multi-lang` | frontend | ✅ PR [frontend#4](https://github.com/2026-Sunrin-Vacation-Project-TEAM6/stackbox-frontend/pull/4) (C/C++/Rust 언어 선택 UI) |
| `web_worker-merge-codeexec` | `feat/code-runner-merged` | web_worker | ✅ PR [web_worker#3](https://github.com/2026-Sunrin-Vacation-Project-TEAM6/web_worker/pull/3) — Redis 캐싱(`feat/redis-caching-optim`) + 멀티랭귀지(`feat/code-runner-multi-lang`)를 하나로 병합·검증 완료(build/test 25/25/clippy 클린). 이 PR이 두 원본 브랜치를 대체하므로 그쪽은 별도 PR 없음. |
| `web_worker-ppt-builder` | `feat/ppt-rust-builder` | web_worker | ✅ PR [web_worker#2](https://github.com/2026-Sunrin-Vacation-Project-TEAM6/web_worker/pull/2) (위 7번 Part B 참고) |
| `backend-elixir-phase1` | `migration/elixir-phoenix-backend` | backend | ✅ 원격 push 완료 (PR은 Phase 2 두 브랜치 머지 후 main 대상으로 생성 예정) |
| `backend-elixir-ai-github` | `feat/elixir-ai-github-codeexec` | backend | ✅ PR [backend#5](https://github.com/2026-Sunrin-Vacation-Project-TEAM6/stackbox-backend/pull/5) (위 7번 Part A 참고) |
| `backend-elixir-docs-crdt` | `feat/elixir-docs-crdt` | backend | ✅ PR [backend#6](https://github.com/2026-Sunrin-Vacation-Project-TEAM6/stackbox-backend/pull/6) (위 7번 Part A 참고) |
| `backend-code-exec-caching` | `feat/code-exec-redis-cache` | backend | ✅ 이미 `origin/main`에 반영됨 (별도 PR 불필요) |

## 다음에 할 일
- [ ] 위 7개 PR 리뷰 + 머지 (권장 순서: backend#4 → backend#5, backend#6(순서 무관) → frontend#3, frontend#4(순서 무관) → web_worker#2, web_worker#3(순서 무관))
- [ ] `migration/elixir-phoenix-backend`에 Phase 2 PR 2개 머지 후, 그 브랜치를 `main` 대상 PR로 올리기
- [ ] `docker compose up`으로 전체 스택 실제 기동 테스트
- [ ] Elixir backend: `mix ecto.migrate` 실제 DB 대상 검증
- [ ] Rust `ppt_builder`: 실제 OpenAI 호출로 `.pptx` 생성 검증 (backend `doc-to-ppt`와 연동 후)
- [ ] OpenAI base URL 커스텀 엔드포인트로 실제 호출 테스트 (선택)
- [ ] Elixir backend가 main으로 머지되면, 기존 FastAPI `backend` 서비스를 대체할지 병행 운영할지 결정 필요

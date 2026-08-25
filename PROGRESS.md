# StackBox 진행 상황

_최종 업데이트: 2026-08-25_

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
- **상태**: 루트 저장소에 커밋 준비 완료(staged). 실제 도메인 연결 전까지는 `localhost` 기준으로 동작.
- 계획 문서: `~/.claude/plans/reactive-munching-eagle.md`

## 7. Elixir/Phoenix 백엔드 재작성 + PPT 기능 Rust 이관 (진행 중)
계획 문서: `~/.claude/plans/purring-swimming-map.md`

### Part A — `backend` 서브모듈, 브랜치 `feat/elixir-rewrite` (커밋 안 됨, dirty)
- Phase 1 (스켈레톤 + 핵심 리소스): 거의 완료.
  - `mix phx.new` 스켈레톤, 12개 테이블 전체 Ecto 마이그레이션 작성 완료.
  - Guardian 기반 JWT 인증(`auth_controller.ex`), `users`/`workspaces`/`workspace_members`/`stack_boxes`/`blocks` 컨트롤러+컨텍스트 구현됨 (47개 `.ex` 파일).
  - RBAC(`Authz.require_role!/3`) 반영 여부는 다음 세션에서 코드 확인 필요.
- Phase 2 (나머지 기능): **미착수**. `code_exec`, `github` OAuth, `ai`(summarize/fix-code/draft/chat/doc-to-ppt), `reactions`, docs/CRDT(snapshot/updates/presence) 컨트롤러가 아직 없음 (컨텍스트 디렉터리만 일부 존재: `reactions`, `docs`, `code_runs`).
  - `ai`의 `doc-to-ppt`는 Part B(아래) 완료 후에만 연동 가능.
- 아직 `mix compile` / `mix test` / `mix ecto.migrate` 검증 전.

### Part B — `web_worker` 서브모듈, 브랜치 `feat/ppt-rust-builder` (커밋 안 됨, dirty)
- 새 바이너리 `src/bin/ppt_builder.rs` (398줄) 작성 완료: OpenAI로 슬라이드 개요 생성 → `ppt-rs`로 `.pptx` 빌드, `code_runner.rs`와 동일한 공유 시크릿 헤더 인증 패턴.
- `Cargo.toml`/`Cargo.lock`에 `ppt-rs`, `reqwest` 의존성 추가됨. Dockerfile은 아직 미수정(네트워크 egress 필요한 별도 런타임 스테이지 필요).
- 아직 `cargo build`/`cargo clippy`/`curl` 실제 호출 검증 전. backend `ai` 컨텍스트(Part A Phase 2)가 없어서 아직 연동 불가 — 독립 검증만 가능한 상태.

## 8. 병렬 워크트리 작업 (`.worktrees/`)
같은 세션에서 4가지 독립 기능을 별도 워크트리로 동시 진행:

| 워크트리 | 브랜치 | 대상 서브모듈 | 상태 |
|---|---|---|---|
| `backend-repo-docs` | `feat/repo-architecture-docs` | backend | ✅ 커밋 완료 (AI 저장소 구조 분석 엔드포인트), origin에는 미푸시 |
| `frontend-diagram-exec` | `feat/diagram-code-exec-link` | frontend | ✅ 커밋 완료 (다이어그램-코드블록 연동, Canvas flow 실행 시 활성 노드 하이라이팅), origin에는 미푸시 |
| `web_worker-caching` | `feat/redis-caching-optim` | web_worker | 🔶 진행 중, 커밋 안 됨 — `code_runner.rs`에 `cache_key`/`cached` 필드 및 캐싱 로직 + 단위 테스트 추가됨. `cargo test` 검증 및 커밋 필요 |
| `web_worker-multilang` | `feat/code-runner-multi-lang` | web_worker | 🔶 진행 중, 커밋 안 됨 — `code_runner.rs`에 C/C++/Rust 컴파일 실행 지원(`Runtime::Compiled`) + 단위 테스트 추가됨. `cargo test` 검증 및 커밋 필요 |
| `frontend-multilang` | `feat/code-runner-multi-lang` | frontend | ⬜ 미착수 — multilang 지원에 맞는 프론트엔드(언어 선택 UI 등) 작업 필요 |

> `web_worker-caching`과 `web_worker-multilang`은 동일 파일(`code_runner.rs`)을 같은 베이스 커밋에서 각자 수정 중이므로, 나중에 한쪽을 먼저 병합하고 다른 쪽을 리베이스해야 함.

## 다음에 할 일
- [ ] `docker compose up`으로 전체 스택 실제 기동 테스트
- [ ] OpenAI base URL 커스텀 엔드포인트로 실제 호출 테스트 (선택)
- [ ] nginx 리버스 프록시: 루트 저장소 커밋 + `docker compose config` / `curl -vk https://localhost/api/health` 검증
- [ ] Elixir backend: `mix compile --warnings-as-errors`, `mix ecto.migrate`, `mix test` 실행 후 Phase 1 커밋
- [ ] Elixir backend Phase 2: `code_exec`, `github`, `ai`(doc-to-ppt 포함), `reactions`, docs/CRDT 컨트롤러 구현
- [ ] Rust `ppt_builder`: `cargo build`/`cargo clippy` + 실제 OpenAI 호출로 `.pptx` 검증, Dockerfile 런타임 스테이지 추가
- [ ] `web_worker-caching`, `web_worker-multilang`: 각각 `cargo test` 확인 후 커밋 → 하나 먼저 병합 후 다른 쪽 리베이스
- [ ] `backend-repo-docs`, `frontend-diagram-exec`: 서브모듈 origin에 push + PR 생성
- [ ] `frontend-multilang`: multilang 코드 실행에 맞는 언어 선택 UI 작업 시작
- [ ] 병합 순서 정리: nginx(루트) → backend Phase 1 → web_worker(caching/multilang 순차 병합) → ppt_builder ↔ backend ai 연동 → frontend 워크들

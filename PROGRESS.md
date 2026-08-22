# StackBox 진행 상황

_최종 업데이트: 2026-08-10_

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

## 다음에 할 일 (제안)
- [ ] `docker compose up`으로 전체 스택 실제 기동 테스트
- [ ] OpenAI base URL 커스텀 엔드포인트로 실제 호출 테스트 (선택)

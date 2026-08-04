-- StackBox: 회원 + 워크스페이스 + 파일 트리 + Notion/Figma 통합 스키마

CREATE TYPE stack_box_type AS ENUM ('folder', 'page', 'canvas', 'edgeless');
CREATE TYPE workspace_role AS ENUM ('owner', 'admin', 'editor', 'viewer');
CREATE TYPE doc_mode AS ENUM ('page', 'edgeless');

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 회원
CREATE TABLE users (
    id            BIGSERIAL PRIMARY KEY,
    email         VARCHAR(255) NOT NULL UNIQUE,
    password_hash VARCHAR(255),
    name          VARCHAR(100) NOT NULL,
    avatar_url    VARCHAR(512),
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_users_email ON users (email);

CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 로그인 세션 (refresh token)
CREATE TABLE user_sessions (
    id         BIGSERIAL PRIMARY KEY,
    user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash VARCHAR(255) NOT NULL UNIQUE,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_user_sessions_user ON user_sessions (user_id);
CREATE INDEX idx_user_sessions_expires ON user_sessions (expires_at);

-- 워크스페이스
CREATE TABLE workspaces (
    id          BIGSERIAL PRIMARY KEY,
    name        VARCHAR(255) NOT NULL,
    slug        VARCHAR(100) NOT NULL UNIQUE,
    description TEXT NOT NULL DEFAULT '',
    icon        VARCHAR(64),
    owner_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_workspaces_owner ON workspaces (owner_id);
CREATE INDEX idx_workspaces_slug ON workspaces (slug);

CREATE TRIGGER trg_workspaces_updated_at
    BEFORE UPDATE ON workspaces
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 워크스페이스 멤버
CREATE TABLE workspace_members (
    id           BIGSERIAL PRIMARY KEY,
    workspace_id BIGINT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    user_id      BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role         workspace_role NOT NULL DEFAULT 'viewer',
    invited_by   BIGINT REFERENCES users(id) ON DELETE SET NULL,
    joined_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, user_id)
);

CREATE INDEX idx_workspace_members_workspace ON workspace_members (workspace_id);
CREATE INDEX idx_workspace_members_user ON workspace_members (user_id);

-- 워크스페이스 초대 (이메일)
CREATE TABLE workspace_invitations (
    id           BIGSERIAL PRIMARY KEY,
    workspace_id BIGINT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    email        VARCHAR(255) NOT NULL,
    role         workspace_role NOT NULL DEFAULT 'viewer',
    token_hash   VARCHAR(255) NOT NULL UNIQUE,
    invited_by   BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    expires_at   TIMESTAMPTZ NOT NULL,
    accepted_at  TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (workspace_id, email)
);

CREATE INDEX idx_workspace_invitations_workspace ON workspace_invitations (workspace_id);
CREATE INDEX idx_workspace_invitations_email ON workspace_invitations (email);

-- 사이드바 파일 트리 (워크스페이스 소속)
CREATE TABLE stack_boxes (
    id           BIGSERIAL PRIMARY KEY,
    workspace_id BIGINT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    parent_id    BIGINT REFERENCES stack_boxes(id) ON DELETE CASCADE,
    type         stack_box_type NOT NULL DEFAULT 'folder',
    name         VARCHAR(255) NOT NULL,
    description  TEXT NOT NULL DEFAULT '',
    icon         VARCHAR(64),
    cover_url    VARCHAR(512),
    sort_order   INT NOT NULL DEFAULT 0,
    created_by   BIGINT REFERENCES users(id) ON DELETE SET NULL,
    updated_by   BIGINT REFERENCES users(id) ON DELETE SET NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_stack_boxes_workspace ON stack_boxes (workspace_id);
CREATE INDEX idx_stack_boxes_parent ON stack_boxes (parent_id);
CREATE INDEX idx_stack_boxes_workspace_parent_sort ON stack_boxes (workspace_id, parent_id, sort_order);
CREATE INDEX idx_stack_boxes_type ON stack_boxes (type);

CREATE TRIGGER trg_stack_boxes_updated_at
    BEFORE UPDATE ON stack_boxes
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- page/canvas 내부 블록 (Notion 블록 + Figma 레이어)
CREATE TABLE blocks (
    id              BIGSERIAL PRIMARY KEY,
    stack_box_id    BIGINT NOT NULL REFERENCES stack_boxes(id) ON DELETE CASCADE,
    parent_block_id BIGINT REFERENCES blocks(id) ON DELETE CASCADE,
    type            VARCHAR(50) NOT NULL,
    content         JSONB,
    x               DOUBLE PRECISION,
    y               DOUBLE PRECISION,
    width           DOUBLE PRECISION,
    height          DOUBLE PRECISION,
    rotation        DOUBLE PRECISION NOT NULL DEFAULT 0,
    z_index         INT NOT NULL DEFAULT 0,
    sort_order      INT NOT NULL DEFAULT 0,
    is_locked       BOOLEAN NOT NULL DEFAULT FALSE,
    created_by      BIGINT REFERENCES users(id) ON DELETE SET NULL,
    updated_by      BIGINT REFERENCES users(id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_blocks_stack_box ON blocks (stack_box_id);
CREATE INDEX idx_blocks_parent ON blocks (parent_block_id);
CREATE INDEX idx_blocks_stack_box_sort ON blocks (stack_box_id, sort_order);
CREATE INDEX idx_blocks_stack_box_z ON blocks (stack_box_id, z_index);
CREATE INDEX idx_blocks_content ON blocks USING GIN (content);

CREATE TRIGGER trg_blocks_updated_at
    BEFORE UPDATE ON blocks
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- 업로드 에셋 (이미지, 파일)
CREATE TABLE assets (
    id           BIGSERIAL PRIMARY KEY,
    stack_box_id BIGINT NOT NULL REFERENCES stack_boxes(id) ON DELETE CASCADE,
    block_id     BIGINT REFERENCES blocks(id) ON DELETE SET NULL,
    name         VARCHAR(255) NOT NULL,
    url          VARCHAR(512) NOT NULL,
    mime_type    VARCHAR(100) NOT NULL,
    size_bytes   BIGINT NOT NULL DEFAULT 0 CHECK (size_bytes >= 0),
    uploaded_by  BIGINT REFERENCES users(id) ON DELETE SET NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_assets_stack_box ON assets (stack_box_id);
CREATE INDEX idx_assets_block ON assets (block_id);

-- AFFiNE WorkspaceDoc: page / edgeless 메타
CREATE TABLE stack_box_docs (
    stack_box_id  BIGINT PRIMARY KEY REFERENCES stack_boxes(id) ON DELETE CASCADE,
    mode          doc_mode NOT NULL DEFAULT 'page',
    title         VARCHAR(255),
    summary       TEXT,
    is_published  BOOLEAN NOT NULL DEFAULT FALSE,
    published_at  TIMESTAMPTZ,
    is_blocked    BOOLEAN NOT NULL DEFAULT FALSE,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_stack_box_docs_updated_at
    BEFORE UPDATE ON stack_box_docs
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- AFFiNE Tier 2: Yjs CRDT merged snapshot
CREATE TABLE doc_snapshots (
    stack_box_id BIGINT PRIMARY KEY REFERENCES stack_boxes(id) ON DELETE CASCADE,
    blob         BYTEA NOT NULL,
    state        BYTEA,
    size         BIGINT NOT NULL DEFAULT 0 CHECK (size >= 0),
    version      BIGINT NOT NULL DEFAULT 0,
    created_by   BIGINT REFERENCES users(id) ON DELETE SET NULL,
    updated_by   BIGINT REFERENCES users(id) ON DELETE SET NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_doc_snapshots_updated ON doc_snapshots (updated_at);

CREATE TRIGGER trg_doc_snapshots_updated_at
    BEFORE UPDATE ON doc_snapshots
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- AFFiNE Tier 1: raw CRDT updates
CREATE TABLE doc_updates (
    id           BIGSERIAL PRIMARY KEY,
    stack_box_id BIGINT NOT NULL REFERENCES stack_boxes(id) ON DELETE CASCADE,
    blob         BYTEA NOT NULL,
    seq          BIGINT NOT NULL,
    created_by   BIGINT REFERENCES users(id) ON DELETE SET NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (stack_box_id, seq)
);

CREATE INDEX idx_doc_updates_stack_box_created ON doc_updates (stack_box_id, created_at);

-- AFFiNE Tier 3: snapshot history
CREATE TABLE doc_snapshot_histories (
    id           BIGSERIAL PRIMARY KEY,
    stack_box_id BIGINT NOT NULL REFERENCES stack_boxes(id) ON DELETE CASCADE,
    blob         BYTEA NOT NULL,
    state        BYTEA,
    expired_at   TIMESTAMPTZ NOT NULL,
    created_by   BIGINT REFERENCES users(id) ON DELETE SET NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_doc_snapshot_histories_stack_box ON doc_snapshot_histories (stack_box_id, created_at);

-- FigJam: 블록 간 커넥터 (화살표, 마인드맵 선)
CREATE TABLE block_connectors (
    id              BIGSERIAL PRIMARY KEY,
    stack_box_id    BIGINT NOT NULL REFERENCES stack_boxes(id) ON DELETE CASCADE,
    source_block_id BIGINT NOT NULL REFERENCES blocks(id) ON DELETE CASCADE,
    target_block_id BIGINT NOT NULL REFERENCES blocks(id) ON DELETE CASCADE,
    source_anchor   JSONB,
    target_anchor   JSONB,
    label           VARCHAR(255),
    style           JSONB,
    created_by      BIGINT REFERENCES users(id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT block_connectors_distinct_ends_chk CHECK (source_block_id <> target_block_id)
);

CREATE INDEX idx_block_connectors_stack_box ON block_connectors (stack_box_id);
CREATE INDEX idx_block_connectors_source ON block_connectors (source_block_id);
CREATE INDEX idx_block_connectors_target ON block_connectors (target_block_id);

CREATE TRIGGER trg_block_connectors_updated_at
    BEFORE UPDATE ON block_connectors
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- AFFiNE/FigJam: 캔버스 코멘트
CREATE TABLE comments (
    id           BIGSERIAL PRIMARY KEY,
    stack_box_id BIGINT NOT NULL REFERENCES stack_boxes(id) ON DELETE CASCADE,
    block_id     BIGINT REFERENCES blocks(id) ON DELETE SET NULL,
    user_id      BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    anchor_x     DOUBLE PRECISION,
    anchor_y     DOUBLE PRECISION,
    content      JSONB NOT NULL,
    is_resolved  BOOLEAN NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at   TIMESTAMPTZ
);

CREATE INDEX idx_comments_stack_box ON comments (stack_box_id, created_at);
CREATE INDEX idx_comments_block ON comments (block_id);
CREATE INDEX idx_comments_user ON comments (user_id);

CREATE TRIGGER trg_comments_updated_at
    BEFORE UPDATE ON comments
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE comment_replies (
    id           BIGSERIAL PRIMARY KEY,
    comment_id   BIGINT NOT NULL REFERENCES comments(id) ON DELETE CASCADE,
    stack_box_id BIGINT NOT NULL REFERENCES stack_boxes(id) ON DELETE CASCADE,
    user_id      BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    content      JSONB NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at   TIMESTAMPTZ
);

CREATE INDEX idx_comment_replies_comment ON comment_replies (comment_id, created_at);
CREATE INDEX idx_comment_replies_stack_box ON comment_replies (stack_box_id);

CREATE TRIGGER trg_comment_replies_updated_at
    BEFORE UPDATE ON comment_replies
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- FigJam: 실시간 커서 / 선택 상태
CREATE TABLE canvas_presence (
    stack_box_id BIGINT NOT NULL REFERENCES stack_boxes(id) ON DELETE CASCADE,
    user_id      BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    cursor_x     DOUBLE PRECISION,
    cursor_y     DOUBLE PRECISION,
    selection    JSONB,
    color        VARCHAR(32),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (stack_box_id, user_id)
);

CREATE INDEX idx_canvas_presence_last_seen ON canvas_presence (last_seen_at);

-- FigJam: 라이브 세션 (공유 링크)
CREATE TABLE canvas_sessions (
    id           BIGSERIAL PRIMARY KEY,
    stack_box_id BIGINT NOT NULL REFERENCES stack_boxes(id) ON DELETE CASCADE,
    share_token  VARCHAR(64) NOT NULL UNIQUE,
    started_by   BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    is_active    BOOLEAN NOT NULL DEFAULT TRUE,
    expires_at   TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_canvas_sessions_stack_box ON canvas_sessions (stack_box_id);

-- FigJam: 스티키 투표 / 스탬프
CREATE TABLE block_reactions (
    id         BIGSERIAL PRIMARY KEY,
    block_id   BIGINT NOT NULL REFERENCES blocks(id) ON DELETE CASCADE,
    user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    reaction   VARCHAR(32) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (block_id, user_id, reaction)
);

CREATE INDEX idx_block_reactions_block ON block_reactions (block_id);

-- FigJam/AFFiNE edgeless: 캔버스 뷰 설정
CREATE TABLE canvas_settings (
    stack_box_id  BIGINT PRIMARY KEY REFERENCES stack_boxes(id) ON DELETE CASCADE,
    viewport      JSONB,
    grid_enabled  BOOLEAN NOT NULL DEFAULT TRUE,
    snap_enabled  BOOLEAN NOT NULL DEFAULT TRUE,
    background    JSONB,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TRIGGER trg_canvas_settings_updated_at
    BEFORE UPDATE ON canvas_settings
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- AFFiNE: 블록 간 링크 / 임베드
CREATE TABLE block_bindings (
    id                  BIGSERIAL PRIMARY KEY,
    source_block_id     BIGINT NOT NULL REFERENCES blocks(id) ON DELETE CASCADE,
    target_stack_box_id BIGINT REFERENCES stack_boxes(id) ON DELETE CASCADE,
    target_block_id     BIGINT REFERENCES blocks(id) ON DELETE CASCADE,
    binding_type        VARCHAR(32) NOT NULL DEFAULT 'link',
    created_by          BIGINT REFERENCES users(id) ON DELETE SET NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT block_bindings_target_chk CHECK (
        target_stack_box_id IS NOT NULL OR target_block_id IS NOT NULL
    )
);

CREATE INDEX idx_block_bindings_source ON block_bindings (source_block_id);
CREATE INDEX idx_block_bindings_target_box ON block_bindings (target_stack_box_id);

-- 공유 링크 (FigJam/AFFiNE publish)
CREATE TABLE share_links (
    id           BIGSERIAL PRIMARY KEY,
    stack_box_id BIGINT NOT NULL REFERENCES stack_boxes(id) ON DELETE CASCADE,
    token        VARCHAR(64) NOT NULL UNIQUE,
    permission   workspace_role NOT NULL DEFAULT 'viewer',
    password_hash VARCHAR(255),
    expires_at   TIMESTAMPTZ,
    created_by   BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_share_links_stack_box ON share_links (stack_box_id);

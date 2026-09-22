PRAGMA foreign_keys = ON;

CREATE TABLE experts (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  description TEXT NOT NULL DEFAULT '',
  type TEXT NOT NULL CHECK (type IN ('expert', 'team')),
  status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'archived')),
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE expert_versions (
  id TEXT PRIMARY KEY,
  expert_id TEXT NOT NULL REFERENCES experts(id),
  version TEXT NOT NULL,
  package_key TEXT NOT NULL UNIQUE,
  package_sha256 TEXT NOT NULL,
  package_size INTEGER NOT NULL,
  manifest TEXT NOT NULL,
  release_notes TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (expert_id, version)
);

CREATE TABLE shares (
  id TEXT PRIMARY KEY,
  expert_version_id TEXT NOT NULL REFERENCES expert_versions(id),
  token TEXT NOT NULL UNIQUE,
  enabled INTEGER NOT NULL DEFAULT 1,
  expires_at TEXT,
  install_clicks INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_versions_expert ON expert_versions(expert_id, created_at DESC);
CREATE INDEX idx_shares_version ON shares(expert_version_id, created_at DESC);

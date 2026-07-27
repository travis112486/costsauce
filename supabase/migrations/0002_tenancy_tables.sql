CREATE TABLE organizations (
  id            uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  name          text NOT NULL CHECK (length(trim(name)) > 0),
  plan          text NOT NULL DEFAULT 'starter'
                  CHECK (plan IN ('starter', 'growth', 'pro')),
  sync_counter  bigint NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE memberships (
  id         uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  org_id     uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  role       text NOT NULL CONSTRAINT memberships_role_check
               CHECK (role IN ('owner', 'manager', 'bookkeeper')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, org_id)
);
CREATE INDEX memberships_user_idx ON memberships (user_id);
CREATE INDEX memberships_org_idx  ON memberships (org_id);

CREATE TABLE locations (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  org_id              uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name                text NOT NULL,
  target_fc_pct       numeric(5,2) NOT NULL DEFAULT 30.00,
  drift_threshold_pct numeric(5,2) NOT NULL DEFAULT 5.00,
  created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX locations_org_idx ON locations (org_id);

CREATE TABLE profiles (
  user_id                   uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  apple_sub                 text UNIQUE,
  contact_email             citext NOT NULL,
  contact_email_verified_at timestamptz,
  created_at                timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE invites (
  id          uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  org_id      uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  email       citext NOT NULL,
  role        text NOT NULL CHECK (role IN ('owner', 'manager', 'bookkeeper')),
  token_hash  text NOT NULL UNIQUE,
  invited_by  uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  expires_at  timestamptz NOT NULL,
  accepted_at timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX invites_org_idx ON invites (org_id);

CREATE TABLE email_verifications (
  id         uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE apple_link_requests (
  id         uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  apple_sub  text NOT NULL,
  token_hash text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

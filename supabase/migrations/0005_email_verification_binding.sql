-- Task 7 review, Important-1: a verification token must only ever be able to
-- verify the specific address it was issued for. Before this, tokens were
-- matched on (user_id, token_hash, expires_at) alone -- nothing bound a
-- token to the email it was minted for, so a stale, still-unexpired token
-- from an earlier set_contact_email call could verify whatever address
-- happens to be on the profile *now*, including one set afterwards that the
-- token's original recipient never consented to. Table starts empty on every
-- migration run (fresh schema per test / per environment bootstrap), so a
-- NOT NULL column needs no backfill default here.
ALTER TABLE email_verifications ADD COLUMN email citext NOT NULL;

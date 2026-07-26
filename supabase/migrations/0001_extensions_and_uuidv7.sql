CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

-- Postgres 17 has no native uuidv7(); this is the documented fallback,
-- extended per RFC 9562 Method 3 ("Replace Left-Most Random Bits with
-- Increased Clock Precision") so that UUIDs generated within the same
-- millisecond still sort in generation order.
--
-- Layout: 48-bit big-endian ms timestamp (bytes 0-5) | version 7 nibble +
-- 12-bit sub-ms fraction "rand_a" (bytes 6-7) | variant + 62 random bits
-- "rand_b" (bytes 8-15).
CREATE OR REPLACE FUNCTION uuid_generate_v7() RETURNS uuid AS $$
DECLARE
  ts      timestamptz := clock_timestamp();
  -- Single microsecond-resolution reading of the clock. unix_ms and
  -- sub_ms are both derived from this one integer below, so they can
  -- never straddle a tick relative to each other.
  unix_us bigint := (extract(epoch FROM ts) * 1000000)::bigint;
  unix_ms bigint := unix_us / 1000;
  sub_ms  bigint := unix_us % 1000;
  -- Sub-millisecond fraction (0-999) scaled into 12 bits (0-4095).
  rand_a  int := least(((sub_ms * 4096) / 1000)::int, 4095);
  bytes   bytea := gen_random_bytes(16);
BEGIN
  bytes := set_byte(bytes, 0, ((unix_ms >> 40) & 255)::int);
  bytes := set_byte(bytes, 1, ((unix_ms >> 32) & 255)::int);
  bytes := set_byte(bytes, 2, ((unix_ms >> 24) & 255)::int);
  bytes := set_byte(bytes, 3, ((unix_ms >> 16) & 255)::int);
  bytes := set_byte(bytes, 4, ((unix_ms >>  8) & 255)::int);
  bytes := set_byte(bytes, 5,  (unix_ms        & 255)::int);
  -- version 7 in the high nibble of byte 6; low nibble = top 4 bits of rand_a
  bytes := set_byte(bytes, 6, (112 | ((rand_a >> 8) & 15)));
  -- byte 7 = bottom 8 bits of rand_a
  bytes := set_byte(bytes, 7, (rand_a & 255));
  -- RFC 4122 variant in the high bits of byte 8; rest of rand_b stays random
  bytes := set_byte(bytes, 8, ((get_byte(bytes, 8) & 63) | 128));
  RETURN encode(bytes, 'hex')::uuid;
END;
$$ LANGUAGE plpgsql VOLATILE;

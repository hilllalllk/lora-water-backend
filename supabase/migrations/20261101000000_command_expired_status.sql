-- LoRa Water Management System - 'expired' command status
--
-- A pending command that the gateway did not pick up in time must never run later
-- (docs/08-guvenlik.md §3). It ends as 'expired' instead.
--
-- Kept in its own migration: PostgreSQL does not allow a new enum value to be used
-- in the same transaction that adds it, and the next migration uses it.
alter type public.command_status add value if not exists 'expired';

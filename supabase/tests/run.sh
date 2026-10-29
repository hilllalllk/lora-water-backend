#!/usr/bin/env bash
# Tests the schema and RLS policies in throwaway PostgreSQL databases.
# Every test file gets a fresh database: stub + all migrations (in order) + the test.
# Requires: psql and a reachable PostgreSQL (PGHOST/PGUSER/PGPASSWORD env vars).
#   bash backend/supabase/tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB="${TEST_DB:-lwm_test}"
for test in tests/rls_test.sql tests/roles_alarms_test.sql tests/lifecycle_test.sql tests/robustness_test.sql tests/mobile_fields_test.sql tests/text_ingest_test.sql; do
  echo "== $test"
  psql -v ON_ERROR_STOP=1 -q -d postgres -c "drop database if exists $DB" -c "create database $DB"
  psql -v ON_ERROR_STOP=1 -q -d "$DB" -f tests/supabase_stub.sql
  for m in migrations/*.sql; do
    psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$m"
  done
  psql -v ON_ERROR_STOP=1 -q -d "$DB" -f "$test"
done
echo "ALL TEST FILES PASSED"

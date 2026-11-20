-- Remove the abandoned historical FTO recovery import RPC.
-- Historical FTO read-only discovery/listing remains available.
DROP FUNCTION IF EXISTS public.vbgramg_import_historical_fto_recovery(jsonb, uuid);

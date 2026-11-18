-- Remove the original RPC signature now that the Edge Function uses the
-- preview-version-checked signature.
drop function if exists public.vbgramg_apply_fto_co_revision(uuid,integer,numeric,numeric,text,uuid,text);
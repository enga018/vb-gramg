-- Permit complete FTO snapshots to retain transactions outside the active MIS.
-- The legacy check constraint made is_in_scope=true mandatory for every stored row,
-- which conflicts with the snapshot-history requirement. Keep the column and its
-- per-row boolean value; remove only the legacy restriction on that value.
alter table public.vbgramg_fto_transactions
  drop constraint if exists vbgramg_fto_transactions_local_scope_only;

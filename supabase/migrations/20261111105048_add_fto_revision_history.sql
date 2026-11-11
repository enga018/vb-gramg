-- FTO revision versioning and immutable revision audit history.
-- Existing batches begin at revision 1; each applied revision records revision >= 2.

ALTER TABLE public.vbgramg_fto_batches
  ADD COLUMN revision_number integer NOT NULL DEFAULT 1
  CONSTRAINT vbgramg_fto_batches_revision_number_check
  CHECK (revision_number >= 1);

CREATE TABLE public.vbgramg_fto_revision_history (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL
    REFERENCES public.vbgramg_fto_batches(id) ON DELETE RESTRICT,
  revision_number integer NOT NULL
    CHECK (revision_number >= 2),
  revision_reason text NOT NULL
    CHECK (length(btrim(revision_reason)) > 0),
  actor_user_id uuid,
  actor_email text,
  changed_at timestamptz NOT NULL DEFAULT now(),

  old_period_id uuid,
  new_period_id uuid,
  old_contribution_period text,
  new_contribution_period text,

  old_calculation_divisor numeric,
  new_calculation_divisor numeric,
  old_calculation_multiplier numeric,
  new_calculation_multiplier numeric,

  affected_transaction_count integer NOT NULL DEFAULT 0
    CHECK (affected_transaction_count >= 0),
  old_eligible_total numeric(14,2),
  new_eligible_total numeric(14,2),

  -- Full before/after evidence, including affected transactions, ledger rows,
  -- allocations, waivers and exemption state captured by the revision engine.
  before_snapshot jsonb NOT NULL,
  after_snapshot jsonb NOT NULL,

  CONSTRAINT uq_vbgramg_fto_revision_history_batch_revision
    UNIQUE (batch_id, revision_number)
);

CREATE INDEX idx_vbgramg_fto_revision_history_batch
  ON public.vbgramg_fto_revision_history (batch_id, revision_number DESC);

ALTER TABLE public.vbgramg_fto_revision_history ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.vbgramg_fto_revision_history
  FROM PUBLIC, anon, authenticated;

GRANT ALL ON TABLE public.vbgramg_fto_revision_history
  TO service_role;

COMMENT ON TABLE public.vbgramg_fto_revision_history IS
  'Audit history for atomic FTO batch revisions. Each row stores before/after financial evidence.';
COMMENT ON COLUMN public.vbgramg_fto_batches.revision_number IS
  'Optimistic concurrency version for FTO batch revisions; starts at 1.';

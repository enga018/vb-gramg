-- Reusable Government FTO applicant-name to Active MIS applicant mappings.
-- Access is restricted to trusted Edge Functions using the service role.
create table if not exists public.vbgramg_fto_applicant_mappings (
  id uuid primary key default gen_random_uuid(),
  job_card_number text not null,
  normalized_fto_name text not null,
  government_applicant_name text not null,
  applicant_name text not null,
  applicant_number text,
  applicant_unique_id text,
  confirmed_by uuid references auth.users(id) on delete set null,
  confirmed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint vbgramg_fto_applicant_mappings_identity_unique
    unique (job_card_number, normalized_fto_name),
  constraint vbgramg_fto_applicant_mappings_job_card_nonempty
    check (length(btrim(job_card_number)) > 0),
  constraint vbgramg_fto_applicant_mappings_name_nonempty
    check (length(btrim(normalized_fto_name)) > 0),
  constraint vbgramg_fto_applicant_mappings_applicant_nonempty
    check (length(btrim(applicant_name)) > 0)
);

create index if not exists vbgramg_fto_applicant_mappings_applicant_idx
  on public.vbgramg_fto_applicant_mappings (applicant_unique_id)
  where applicant_unique_id is not null;

alter table public.vbgramg_fto_applicant_mappings enable row level security;

revoke all on public.vbgramg_fto_applicant_mappings from anon, authenticated;
grant all on public.vbgramg_fto_applicant_mappings to service_role;

comment on table public.vbgramg_fto_applicant_mappings is
  'Confirmed mapping from a Government FTO applicant name within a Job Card to a stable Active MIS applicant identity.';

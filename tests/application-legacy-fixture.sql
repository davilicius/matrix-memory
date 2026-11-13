-- The historical study fixture omits this production table. Mirror its shape
-- and owner policy so the new production restriction is exercised unchanged.
create table public.legacy_directives (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  beneficiary_contact text,
  instructions text not null,
  activation_condition text,
  is_active boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.legacy_directives enable row level security;
grant select,insert,update,delete on public.legacy_directives to authenticated;
create policy legacy_directives_own on public.legacy_directives for all to authenticated
using (owner_id=(select auth.uid())) with check(owner_id=(select auth.uid()));

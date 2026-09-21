-- Baseline capture (part 3): RLS policy definitions.
--
-- None of these were ever created by a migration -- profiles' and
-- admin_notes' policies come from the "roles" saved query in the Supabase
-- SQL editor (predates 20260913030000_fix_profiles_rls_privilege_escalation,
-- which only DROPPED the insecure policies layered on top later -- it
-- never recreated the correct ones shown here, because they'd survived
-- untouched the whole time). reservations' and login_attempts' policies
-- come from the "Reservation table" and "Failed login tracker" saved
-- queries respectively.
--
-- Likely origin of the 20260913030000 vulnerability, for the record: these
-- three profiles policies are cleanly hand-named and correctly scoped.
-- The ones that migration dropped ("Enable read access for all users",
-- "users can create their own profile") are Supabase's own default names
-- for its dashboard "quick policy" templates. Someone probably clicked a
-- one-click "allow public read" template on top of the real policies,
-- not realizing Postgres OR's every policy on a table together rather
-- than replacing -- worth flagging to the team as a reason to keep doing
-- policies as SQL migrations, not dashboard templates, going forward.
--
-- `drop policy if exists` before each `create policy` makes this safe to
-- run regardless of the live database's exact current state -- no error
-- if the policy's already there under this name, no duplicate if it is.

-- ---- profiles ----
-- (RLS already enabled by 20260921010000_baseline_capture_predates_migrations.sql)

drop policy if exists "Users can view own profile" on public.profiles;
create policy "Users can view own profile"
  on public.profiles for select
  using (auth.uid() = id);

drop policy if exists "Users can upsert own profile as customer" on public.profiles;
create policy "Users can upsert own profile as customer"
  on public.profiles for insert
  with check (auth.uid() = id and role = 'customer');

drop policy if exists "Users can update own non-role fields" on public.profiles;
create policy "Users can update own non-role fields"
  on public.profiles for update
  using (auth.uid() = id)
  with check (auth.uid() = id and role = 'customer');

-- ---- admin_notes ----
-- (RLS already enabled by 20260921010000_baseline_capture_predates_migrations.sql)

drop policy if exists "Only admins can read admin notes" on public.admin_notes;
create policy "Only admins can read admin notes"
  on public.admin_notes for select
  using (
    exists (
      select 1 from public.profiles
      where profiles.id = auth.uid() and profiles.role = 'admin'
    )
  );

-- ---- reservations ----
-- Deliberately SELECT-only: no insert/update policy, by design -- every
-- write goes through SECURITY DEFINER functions (create_reservation,
-- process_payment, cancel_reservation, rebook_reservation), never a
-- direct client insert/update.

drop policy if exists "Users can view own reservations" on public.reservations;
create policy "Users can view own reservations"
  on public.reservations for select
  using (auth.uid() = user_id);

-- ---- login_attempts ----
-- Deliberately NO policies at all -- the table is reachable only through
-- check_login_lock / record_failed_login / clear_login_attempts (all
-- SECURITY DEFINER), so a client can never read or clear their own
-- lockout by writing to the table directly. Nothing to create here; this
-- comment exists so the "no policies" is a documented decision, not a
-- silent gap.

-- ---------------------------------------------------------------------
-- Still open: flights, payments, and payment_methods policy text isn't
-- captured anywhere yet (no saved query covered them). Run this and send
-- me the result to close the gap:
--
-- select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
-- from pg_policies
-- where schemaname = 'public' and tablename in ('flights', 'payments', 'payment_methods')
-- order by tablename, policyname;
-- ---------------------------------------------------------------------

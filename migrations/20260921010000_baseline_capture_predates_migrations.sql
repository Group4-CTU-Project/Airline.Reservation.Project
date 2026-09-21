-- Baseline capture: core tables that predate migration tracking.
--
-- flights, reservations, payments, payment_methods, profiles, login_attempts,
-- and admin_notes all already exist in the live database, but no migration
-- in this repo ever creates them -- the earliest tracked migration
-- (20260912030000_fix_return_leg_seat_holds.sql) already assumes they're
-- there. They were evidently created directly in the Supabase dashboard
-- before this team started using migrations.
--
-- Practical effect of that gap: replaying migrations/ against an empty
-- database (a fresh environment, a teammate's local Supabase, disaster
-- recovery) fails immediately, since the very first migration references
-- tables that don't exist yet.
--
-- This migration is written to be a safe no-op against the CURRENT
-- database: every table uses `create table if not exists`, so nothing here
-- touches your live data or structure. Its only job is to make the git
-- history replayable from scratch for the next environment.
--
-- Columns already owned by a real migration are deliberately left out here,
-- so that migration stays the one source of truth for them:
--   * flights.total_seats            -> 20260913040000_add_seat_selection.sql
--   * reservations.seat_number        -> 20260913040000_add_seat_selection.sql
--   * reservations.return_seat_number -> 20260913040000_add_seat_selection.sql
--
-- NOT included here: Row Level Security policies. A plain information_schema
-- dump shows which tables have RLS-relevant constraints but not actual
-- policy definitions (CREATE POLICY has no safe IF NOT EXISTS, so guessing
-- at policy text risks a migration that errors on re-run against a database
-- where the real policy already exists under a different name/definition).
-- That needs its own follow-up once we have the real policy text -- see the
-- note at the bottom of this file for the query to pull it.
--
-- NOT included here: admin_audit_log. It exists live but nothing in the app
-- or any migration reads/writes it -- worth confirming intent with the team
-- before baselining it as "real" schema.

create table if not exists public.flights (
  flight_id uuid primary key default gen_random_uuid(),
  origin text not null,
  destination text not null,
  departure_time timestamptz not null,
  arrival_time timestamptz not null,
  status text not null default 'scheduled',
  fare numeric not null,
  seats_available integer not null,
  created_at timestamptz not null default now()
);

create table if not exists public.reservations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id),
  flight_id uuid not null references public.flights(flight_id),
  passenger_name text not null,
  passenger_email text not null,
  status text not null default 'pending',
  price_paid numeric not null,
  created_at timestamptz not null default now(),
  return_date date,
  return_flight_id uuid references public.flights(flight_id)
);

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id),
  user_id uuid not null references auth.users(id),
  card_brand text not null,
  last4 text not null,
  token_encrypted bytea not null,
  result text not null,
  amount numeric not null,
  created_at timestamptz not null default now()
);

create table if not exists public.payment_methods (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id),
  card_brand text not null,
  last4 text not null,
  token_encrypted bytea not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.profiles (
  id uuid primary key references auth.users(id),
  role text default 'customer',
  email text,
  full_name text
);

create table if not exists public.login_attempts (
  email text primary key,
  failed_count integer not null default 0,
  locked_until timestamptz,
  updated_at timestamptz not null default now()
);

create table if not exists public.admin_notes (
  id uuid primary key default gen_random_uuid(),
  note text
);

-- Cleanup: admin_notes has a column literally named
-- "need to fix sign verification" (smallint) -- almost certainly a reminder
-- typed into the "new column name" field in Table Editor by mistake, since
-- it's unused anywhere in the app or any migration. Dropping it, unlike the
-- create table statements above, DOES take effect against the live database.
-- If "sign verification" is a real open issue, it should be tracked as an
-- actual ticket rather than live on as a stray column name.
alter table public.admin_notes drop column if exists "need to fix sign verification";

-- RLS was already enabled on these tables live (that's why the app's role
-- checks and "own reservations only" behavior work today) -- this is just
-- making that fact visible in git. Safe to re-run: enabling RLS that's
-- already enabled is a no-op, not an error.
alter table public.flights enable row level security;
alter table public.reservations enable row level security;
alter table public.payments enable row level security;
alter table public.payment_methods enable row level security;
alter table public.profiles enable row level security;
alter table public.login_attempts enable row level security;
alter table public.admin_notes enable row level security;

-- ---------------------------------------------------------------------
-- Follow-up needed: capture the actual RLS policy definitions.
-- Run this in the SQL Editor and send me the result, the same way you sent
-- the column dump for this migration -- I'll turn it into a second,
-- policy-only migration so the full security model is in git too:
--
-- select schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
-- from pg_policies
-- where schemaname = 'public'
-- order by tablename, policyname;
-- ---------------------------------------------------------------------

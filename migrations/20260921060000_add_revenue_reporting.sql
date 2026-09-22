-- S2-04 / PB-10: ticket-sales reporting and revenue aggregates.
--
-- Admin-only, per the design confirmed back in
-- 20260921050000_add_manager_role.sql: manager gets the reservation-
-- tracking dashboard, not revenue. Nothing here is callable by manager.
--
-- Schema gap this migration has to solve first: reservations has no
-- timestamp for *when a cancellation happened* -- only created_at (when the
-- booking was made). A "cancellations over time" graph built on created_at
-- would actually be graphing "bookings made on day X that are, as of right
-- now, cancelled" -- not when those cancellations occurred, which is a
-- different (and wrong) chart. So:
--   1. add a nullable cancelled_at column
--   2. a trigger stamps it the moment any UPDATE flips status to
--      'cancelled' -- this fires no matter which code path does the
--      update (cancel_reservation(), a future admin tool, a manual fix),
--      so it doesn't require touching cancel_reservation()'s existing body
--   3. it's cleared back to null if a row is ever un-cancelled (rebook_
--      reservation() reactivating it), so a stale cancelled_at can't survive
--      a status flip back to pending/confirmed
--   4. existing already-cancelled rows are backfilled with cancelled_at =
--      created_at, as the closest available approximation -- flagged below
--      so nobody mistakes that backfilled value for a real cancellation
--      timestamp when eyeballing old data.

alter table public.reservations add column if not exists cancelled_at timestamptz;

update public.reservations
set cancelled_at = created_at
where status = 'cancelled' and cancelled_at is null;
-- ^ Backfill only. Every row touched by this line has an approximate
-- cancelled_at (= its booking date, not its real cancel date) baked in
-- because the real value was never captured historically. Anything
-- cancelled from this migration forward gets a true timestamp via the
-- trigger below.

create or replace function public.trg_set_reservation_cancelled_at()
returns trigger
language plpgsql
as $function$
begin
  if new.status = 'cancelled' and (old.status is distinct from 'cancelled') then
    new.cancelled_at := now();
  elsif new.status <> 'cancelled' and old.status = 'cancelled' then
    new.cancelled_at := null;
  end if;
  return new;
end;
$function$;

drop trigger if exists set_reservation_cancelled_at on public.reservations;
create trigger set_reservation_cancelled_at
  before update on public.reservations
  for each row
  execute function public.trg_set_reservation_cancelled_at();

-- ---------------------------------------------------------------------
-- get_revenue_summary(): headline numbers for a date range.
--   * Revenue/confirmed/pending/payment_failed counts are scoped by
--     created_at (when the booking was made) within the range.
--   * cancelled_count is scoped by cancelled_at (when it was cancelled)
--     within the SAME range -- these are two different date filters on
--     purpose, since "sales made this month" and "cancellations that
--     happened this month" are different questions and a booking made
--     last month but cancelled this month belongs in the second, not
--     the first.
--   * p_date_from/p_date_to both null = all-time.
--
-- Dropped first: this signature already exists live with a different
-- return row shape (same story as the undocumented functions found during
-- the earlier baseline-capture pass -- someone built a first version of
-- this directly against the database, never captured in a migration, and
-- `create or replace` can't change a function's OUT-parameter row type in
-- place, only `drop` + `create` can).
drop function if exists public.get_revenue_summary(date, date);
create or replace function public.get_revenue_summary(
  p_date_from date default null,
  p_date_to date default null
)
returns table(
  total_revenue numeric,
  confirmed_count bigint,
  pending_count bigint,
  payment_failed_count bigint,
  cancelled_count bigint,
  cancellation_rate numeric
)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not exists (
    select 1 from public.profiles pr
    where pr.id = auth.uid() and pr.role = 'admin'
  ) then
    raise exception 'Access denied: admin role required';
  end if;

  return query
  with booked as (
    select r.status, r.price_paid
    from public.reservations r
    where (p_date_from is null or r.created_at::date >= p_date_from)
      and (p_date_to is null or r.created_at::date <= p_date_to)
  ),
  cancelled as (
    select 1
    from public.reservations r
    where r.status = 'cancelled'
      and (p_date_from is null or r.cancelled_at::date >= p_date_from)
      and (p_date_to is null or r.cancelled_at::date <= p_date_to)
  )
  select
    coalesce(sum(b.price_paid) filter (where b.status = 'confirmed'), 0)::numeric,
    count(*) filter (where b.status = 'confirmed')::bigint,
    count(*) filter (where b.status = 'pending')::bigint,
    count(*) filter (where b.status = 'payment_failed')::bigint,
    (select count(*) from cancelled)::bigint,
    case when count(*) filter (where b.status = 'confirmed') + (select count(*) from cancelled) = 0
      then 0
      else round(
        (select count(*) from cancelled)::numeric
        / (count(*) filter (where b.status = 'confirmed') + (select count(*) from cancelled)),
        4
      )
    end
  from booked b;
end;
$function$;

grant execute on function public.get_revenue_summary(date, date) to authenticated;

-- ---------------------------------------------------------------------
-- get_revenue_by_day(): the actual sales-tracker graph data -- one row per
-- calendar day in range, with that day's revenue, bookings, and
-- cancellations, all three normalized to zero (not a missing row) for a
-- day with no activity, so the frontend can plot a continuous line/bar
-- series without gap-filling client-side.
--
-- Defaults to the last 30 days when no range is given -- an unbounded
-- generate_series would happily build years of empty rows for a database
-- this young, and 30 days is a sane default window for a "recent sales
-- trend" chart regardless of how much history eventually piles up.
--
-- Dropped first defensively, same reasoning as get_revenue_summary() above
-- -- if this signature also already exists live with a different return
-- shape, `create or replace` alone would fail the same way.
drop function if exists public.get_revenue_by_day(date, date);
create or replace function public.get_revenue_by_day(
  p_date_from date default null,
  p_date_to date default null
)
returns table(
  day date,
  revenue numeric,
  bookings_count bigint,
  cancellations_count bigint
)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_from date;
  v_to date;
begin
  if not exists (
    select 1 from public.profiles pr
    where pr.id = auth.uid() and pr.role = 'admin'
  ) then
    raise exception 'Access denied: admin role required';
  end if;

  v_to := coalesce(p_date_to, current_date);
  v_from := coalesce(p_date_from, v_to - interval '29 days');

  if v_from > v_to then
    raise exception 'p_date_from must not be after p_date_to';
  end if;

  return query
  with days as (
    select generate_series(v_from, v_to, interval '1 day')::date as day
  ),
  bookings as (
    select r.created_at::date as day, r.price_paid, r.status
    from public.reservations r
    where r.created_at::date between v_from and v_to
  ),
  cancellations as (
    select r.cancelled_at::date as day
    from public.reservations r
    where r.status = 'cancelled' and r.cancelled_at::date between v_from and v_to
  )
  select
    d.day,
    coalesce(sum(b.price_paid) filter (where b.status = 'confirmed'), 0)::numeric,
    coalesce(count(*) filter (where b.status = 'confirmed'), 0)::bigint,
    coalesce((select count(*) from cancellations c where c.day = d.day), 0)::bigint
  from days d
  left join bookings b on b.day = d.day
  group by d.day
  order by d.day;
end;
$function$;

grant execute on function public.get_revenue_by_day(date, date) to authenticated;

-- ---------------------------------------------------------------------
-- get_revenue_by_route(): top routes by revenue in range (confirmed
-- bookings only) -- feeds a "top routes" bar on the same dashboard.
-- Same 30-day default as get_revenue_by_day, same reasoning.
--
-- Dropped first defensively, same reasoning as the two functions above.
drop function if exists public.get_revenue_by_route(date, date, integer);
create or replace function public.get_revenue_by_route(
  p_date_from date default null,
  p_date_to date default null,
  p_limit integer default 10
)
returns table(
  origin text,
  destination text,
  revenue numeric,
  bookings_count bigint
)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_from date;
  v_to date;
begin
  if not exists (
    select 1 from public.profiles pr
    where pr.id = auth.uid() and pr.role = 'admin'
  ) then
    raise exception 'Access denied: admin role required';
  end if;

  v_to := coalesce(p_date_to, current_date);
  v_from := coalesce(p_date_from, v_to - interval '29 days');
  p_limit := least(greatest(coalesce(p_limit, 10), 1), 50);

  return query
  select
    f.origin,
    f.destination,
    sum(r.price_paid)::numeric as revenue,
    count(*)::bigint as bookings_count
  from public.reservations r
  join public.flights f on f.flight_id = r.flight_id
  where r.status = 'confirmed'
    and r.created_at::date between v_from and v_to
  group by f.origin, f.destination
  order by revenue desc
  limit p_limit;
end;
$function$;

grant execute on function public.get_revenue_by_route(date, date, integer) to authenticated;

-- ---------------------------------------------------------------------
-- get_revenue_summary(date,date) turned out to already exist live under a
-- different return shape -- the same "built directly against the database,
-- never captured in a migration" story as book_flight/release_reservation/
-- confirm_reservation earlier. The three `drop function if exists ...`
-- lines above only match that exact (date,date)/(date,date)/(date,date,
-- integer) signature; if get_revenue_by_day or get_revenue_by_route were
-- ALSO pre-existing but under a different signature (extra/missing/
-- differently-typed params), that drop wouldn't have matched it, and this
-- migration would have created a second, differently-signed overload
-- sitting alongside the old one rather than replacing it.
--
-- Run this and send me the result so we can confirm there's nothing left
-- to clean up:
--
-- select p.proname, pg_get_function_identity_arguments(p.oid) as args
-- from pg_proc p
-- join pg_namespace n on n.oid = p.pronamespace
-- where n.nspname = 'public'
--   and p.proname in ('get_revenue_summary', 'get_revenue_by_day', 'get_revenue_by_route');
-- ---------------------------------------------------------------------

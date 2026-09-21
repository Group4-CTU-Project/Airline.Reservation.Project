-- S2-03 / PB-09: Manager reservation-tracking dashboard and filters
--
-- The manager dashboard needs to browse and filter reservations across ALL
-- customers, which get_my_reservations() can't do (it's scoped to
-- r.user_id = auth.uid() by design, for the customer-facing My Trips view).
--
-- Two new admin-gated RPCs, following the same "raise exception unless
-- profiles.role = 'admin'" pattern already used by get_revenue_summary /
-- get_revenue_by_day / get_revenue_by_route (see
-- 20260920120000_rebooking_fixes_and_net_revenue.sql):
--
--   * get_all_reservations(...) -- filterable, paginated list of every
--     reservation, joined to flight + payment info the same way
--     get_my_reservations() is. Returns total_count (via count(*) over())
--     on every row so the frontend can paginate without a second query.
--     Deliberately does NOT join auth.users -- passenger_name/
--     passenger_email captured at booking time is enough to track and
--     search reservations, and it avoids taking a dependency on the
--     migration role having select on auth.users.
--   * get_reservation_status_counts() -- count of reservations per status,
--     for the dashboard's summary tiles (pending/confirmed/payment_failed/
--     cancelled at a glance).
--
-- Both are SECURITY DEFINER so they can read across all users' reservations
-- (RLS on public.reservations otherwise scopes reads to the owning user),
-- exactly like get_my_reservations() already does for the single-user case.

create or replace function public.get_all_reservations(
  p_status text default null,
  p_origin text default null,
  p_destination text default null,
  p_date_from date default null,
  p_date_to date default null,
  p_search text default null,
  p_limit integer default 25,
  p_offset integer default 0
)
returns table(
  reservation_id uuid,
  status text,
  price_paid numeric,
  created_at timestamptz,
  passenger_name text,
  passenger_email text,
  flight_id uuid,
  origin text,
  destination text,
  departure_time timestamptz,
  arrival_time timestamptz,
  seat_number text,
  return_date date,
  return_flight_id uuid,
  return_origin text,
  return_destination text,
  return_departure_time timestamptz,
  return_arrival_time timestamptz,
  return_seat_number text,
  card_brand text,
  last4 text,
  payment_result text,
  total_count bigint
)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not exists (
    select 1 from public.profiles pr where pr.id = auth.uid() and pr.role = 'admin'
  ) then
    raise exception 'Access denied: admin role required';
  end if;

  -- Keep pagination bounded regardless of what the client sends.
  p_limit := least(greatest(coalesce(p_limit, 25), 1), 100);
  p_offset := greatest(coalesce(p_offset, 0), 0);

  return query
  select
    r.id,
    r.status,
    r.price_paid,
    r.created_at,
    r.passenger_name,
    r.passenger_email,
    f.flight_id,
    f.origin,
    f.destination,
    f.departure_time,
    f.arrival_time,
    r.seat_number,
    r.return_date,
    rf.flight_id,
    rf.origin,
    rf.destination,
    rf.departure_time,
    rf.arrival_time,
    r.return_seat_number,
    p.card_brand,
    p.last4,
    p.result,
    count(*) over()::bigint as total_count
  from public.reservations r
  join public.flights f on f.flight_id = r.flight_id
  left join public.flights rf on rf.flight_id = r.return_flight_id
  left join public.payments p on p.reservation_id = r.id
  where (p_status is null or p_status = '' or r.status = p_status)
    and (p_origin is null or p_origin = '' or f.origin ilike '%' || p_origin || '%')
    and (p_destination is null or p_destination = '' or f.destination ilike '%' || p_destination || '%')
    and (p_date_from is null or f.departure_time::date >= p_date_from)
    and (p_date_to is null or f.departure_time::date <= p_date_to)
    and (
      p_search is null or p_search = ''
      or r.passenger_name ilike '%' || p_search || '%'
      or r.passenger_email ilike '%' || p_search || '%'
      or r.id::text ilike p_search || '%'
    )
  order by r.created_at desc
  limit p_limit offset p_offset;
end;
$function$;

grant execute on function public.get_all_reservations(text, text, text, date, date, text, integer, integer) to authenticated;

create or replace function public.get_reservation_status_counts()
returns table(status text, count bigint)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not exists (
    select 1 from public.profiles pr where pr.id = auth.uid() and pr.role = 'admin'
  ) then
    raise exception 'Access denied: admin role required';
  end if;

  return query
  select r.status, count(*)::bigint
  from public.reservations r
  group by r.status;
end;
$function$;

grant execute on function public.get_reservation_status_counts() to authenticated;

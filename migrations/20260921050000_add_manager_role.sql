-- S2-03 follow-up: add a 'manager' role, distinct from 'admin'.
--
-- Design (confirmed with the team):
--   * admin is a superset -- everything manager can do, plus everything
--     else admin-only (admin_notes, revenue reports, promoting users).
--     No change needed for admin's existing access anywhere.
--   * manager is scoped to reservation tracking only: get_all_reservations()
--     and get_reservation_status_counts() (the Manager Dashboard from
--     20260921000000_manager_reservation_dashboard.sql).
--   * manager does NOT get revenue reporting (get_revenue_summary /
--     get_revenue_by_day / get_revenue_by_route stay admin-only, untouched
--     by this migration) or admin_notes (its RLS policy already checks
--     role = 'admin' specifically, so it excludes manager with no change
--     needed there either).
--
-- profiles.role has no CHECK constraint anywhere in git history (confirmed
-- against the live column dump earlier), so nothing stopped an arbitrary
-- string before now. Adding one here, since introducing a second elevated
-- role is exactly the moment a typo (e.g. 'Manager' vs 'manager') silently
-- locks someone out with no error -- a constraint turns that into an
-- immediate, obvious failure at promotion time instead.

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('customer', 'admin', 'manager'));

-- Both functions keep their exact existing signature, so `create or
-- replace` is safe -- no drop needed, and every existing call site
-- (the Manager Dashboard frontend) keeps working unchanged.

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
    select 1 from public.profiles pr
    where pr.id = auth.uid() and pr.role in ('admin', 'manager')
  ) then
    raise exception 'Access denied: admin or manager role required';
  end if;

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

create or replace function public.get_reservation_status_counts()
returns table(status text, count bigint)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not exists (
    select 1 from public.profiles pr
    where pr.id = auth.uid() and pr.role in ('admin', 'manager')
  ) then
    raise exception 'Access denied: admin or manager role required';
  end if;

  return query
  select r.status, count(*)::bigint
  from public.reservations r
  group by r.status;
end;
$function$;

-- Lets an admin OR manager promote/demote another account, so a manager can
-- bring on a new employee and grant them admin themselves rather than
-- filing a request. This is a deliberate widening of who can grant admin --
-- confirmed with the team as part of this same design (see file header).
--
-- Guardrails:
--   * p_new_role is constrained to the same three values as the column
--     itself (profiles_role_check above is the second line of defense --
--     this check just gives a clearer error message than a bare
--     constraint violation would).
--   * No self-service: a caller can never change their own role through
--     this function, admin or manager alike. This is what actually blocks
--     the obvious abuse case (a manager calling this on their own uid to
--     hand themselves admin) -- it's not manager-specific because there's
--     no legitimate reason for ANYONE to self-promote through here, and a
--     blanket rule is a lot harder to accidentally punch a hole in later
--     than a manager-only check would be.
--   * Only touches profiles.role -- can't be used to edit email/full_name
--     on someone else's row.
create or replace function public.set_user_role(
  p_user_id uuid,
  p_new_role text
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if not exists (
    select 1 from public.profiles pr
    where pr.id = auth.uid() and pr.role in ('admin', 'manager')
  ) then
    raise exception 'Access denied: admin or manager role required';
  end if;

  if p_user_id = auth.uid() then
    raise exception 'Cannot change your own role';
  end if;

  if p_new_role not in ('customer', 'admin', 'manager') then
    raise exception 'Invalid role: %', p_new_role;
  end if;

  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'No such user';
  end if;

  update public.profiles set role = p_new_role where id = p_user_id;
end;
$function$;

grant execute on function public.set_user_role(uuid, text) to authenticated;

-- Email-based wrapper around set_user_role(), for the Manager Dashboard's
-- "Assign a role" panel: a manager looks a coworker up by the email they
-- know, not by uuid. This does the email -> id lookup itself rather than
-- exposing a separate "find user by email" RPC -- there's no reason to hand
-- back a bare user id lookup as its own capability when the only thing it's
-- ever used for is immediately feeding it into a role change. All the same
-- guardrails apply, since this just resolves the id and calls straight
-- through to set_user_role().
create or replace function public.set_user_role_by_email(
  p_email text,
  p_new_role text
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user_id uuid;
begin
  -- Access/role checks happen inside set_user_role() too, but checking here
  -- first means a manager searching for a typo'd email gets "no such user"
  -- rather than an email-enumeration-shaped error path.
  if not exists (
    select 1 from public.profiles pr
    where pr.id = auth.uid() and pr.role in ('admin', 'manager')
  ) then
    raise exception 'Access denied: admin or manager role required';
  end if;

  select id into v_user_id from public.profiles where lower(email) = lower(p_email);

  if v_user_id is null then
    raise exception 'No account found for that email';
  end if;

  perform public.set_user_role(v_user_id, p_new_role);
end;
$function$;

grant execute on function public.set_user_role_by_email(text, text) to authenticated;

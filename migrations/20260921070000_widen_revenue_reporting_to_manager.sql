-- Follow-up to S2-04/PB-10: widen the sales/cancellations reporting from
-- admin-only to admin-or-manager.
--
-- This reverses the earlier call (20260921050000_add_manager_role.sql
-- header comment, and confirmed with "No, reservation dashboard only" when
-- the manager role was first designed) that manager would NOT get revenue.
-- Team decided managers should see the Sales & Cancellations charts on the
-- Manager Dashboard after all. Nothing else about the role split changes:
-- role assignment (set_user_role / set_user_role_by_email) is still
-- manager-only in the UI, and admin_notes / promoting to admin are
-- unaffected here.
--
-- Same signatures as before, so `create or replace` is safe -- no drop
-- needed this time (unlike the earlier get_revenue_summary conflict, this
-- isn't touching the return row shape, only the role check inside the
-- body).

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
    where pr.id = auth.uid() and pr.role in ('admin', 'manager')
  ) then
    raise exception 'Access denied: admin or manager role required';
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
    where pr.id = auth.uid() and pr.role in ('admin', 'manager')
  ) then
    raise exception 'Access denied: admin or manager role required';
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
    where pr.id = auth.uid() and pr.role in ('admin', 'manager')
  ) then
    raise exception 'Access denied: admin or manager role required';
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

-- No new grants needed -- authenticated already has execute on all three
-- from 20260921060000_add_revenue_reporting.sql; the role check inside the
-- function body is what actually gates access.

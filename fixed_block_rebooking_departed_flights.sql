-- S2-06: block rebooking a trip whose original flight has already departed.
-- Previously get_alternate_flights()/rebook_reservation() only checked that the
-- NEW flight is in the future, so a trip already flown could be "rebooked"
-- (and a lower fare recorded as a negative payment_adjustment).
-- Signatures and return types are unchanged, so CREATE OR REPLACE is safe.

create or replace function public.get_alternate_flights(p_reservation_id uuid)
returns table(flight_id uuid, origin text, destination text, departure_time timestamptz, arrival_time timestamptz, fare numeric, seats_available integer, new_price numeric, fare_difference numeric)
language plpgsql
security definer
set search_path = public
as $function$
#variable_conflict use_column
declare
  v_old_flight_id uuid;
  v_return_flight_id uuid;
  v_old_price numeric;
  v_status text;
  v_old public.flights;
  v_return_departure timestamptz;
begin
  if auth.uid() is null then
    raise exception 'Must be authenticated';
  end if;

  select r.flight_id, r.return_flight_id, r.price_paid, r.status
  into v_old_flight_id, v_return_flight_id, v_old_price, v_status
  from public.reservations r
  where r.id = p_reservation_id and r.user_id = auth.uid();

  if v_old_flight_id is null then
    raise exception 'Reservation not found';
  end if;

  if v_status <> 'confirmed' then
    raise exception 'Only confirmed reservations can be rebooked';
  end if;

  select * into v_old from public.flights f where f.flight_id = v_old_flight_id;

  if v_old.departure_time <= now() then
    raise exception 'This flight has already departed and can''t be changed';
  end if;

  if v_return_flight_id is not null then
    select f.departure_time into v_return_departure
    from public.flights f where f.flight_id = v_return_flight_id;
  end if;

  return query
  select
    f.flight_id,
    f.origin,
    f.destination,
    f.departure_time,
    f.arrival_time,
    f.fare,
    f.seats_available,
    (case when v_return_flight_id is not null then round(f.fare * 1.85, 2) else round(f.fare, 2) end)::numeric,
    (case when v_return_flight_id is not null then round(f.fare * 1.85, 2) else round(f.fare, 2) end - v_old_price)::numeric
  from public.flights f
  where f.origin = v_old.origin
    and f.destination = v_old.destination
    and f.flight_id <> v_old_flight_id
    and f.status = 'scheduled'
    and f.departure_time > now()
    and f.seats_available > 0
    and (v_return_departure is null or f.arrival_time < v_return_departure)
  order by f.departure_time;
end;
$function$;

create or replace function public.rebook_reservation(p_reservation_id uuid, p_new_flight_id uuid)
returns table(reservation_id uuid, old_flight_id uuid, new_flight_id uuid, new_price numeric, fare_difference numeric, status text)
language plpgsql
security definer
set search_path = public
as $function$
#variable_conflict use_column
declare
  v_old_flight_id uuid;
  v_return_flight_id uuid;
  v_old_price numeric;
  v_status text;
  v_seat text;
  v_old public.flights;
  v_new public.flights;
  v_return public.flights;
  v_new_price numeric;
  v_diff numeric;
  v_seat_taken boolean;
begin
  if auth.uid() is null then
    raise exception 'Must be authenticated to rebook a reservation';
  end if;

  select r.flight_id, r.return_flight_id, r.price_paid, r.status, r.seat_number
  into v_old_flight_id, v_return_flight_id, v_old_price, v_status, v_seat
  from public.reservations r
  where r.id = p_reservation_id and r.user_id = auth.uid()
  for update;

  if v_old_flight_id is null then
    raise exception 'Reservation not found';
  end if;

  if v_status <> 'confirmed' then
    raise exception 'Only confirmed reservations can be rebooked';
  end if;

  if p_new_flight_id = v_old_flight_id then
    raise exception 'New flight must be different from current flight';
  end if;

  select * into v_old from public.flights f where f.flight_id = v_old_flight_id;

  if v_old.departure_time <= now() then
    raise exception 'This flight has already departed and can''t be changed';
  end if;

  select * into v_new from public.flights f where f.flight_id = p_new_flight_id for update;

  if v_new.flight_id is null then
    raise exception 'Selected flight not found';
  end if;

  if v_new.status <> 'scheduled' then
    raise exception 'Selected flight is not available for booking';
  end if;

  if v_new.departure_time <= now() then
    raise exception 'Selected flight has already departed';
  end if;

  if v_new.origin <> v_old.origin or v_new.destination <> v_old.destination then
    raise exception 'Alternate flight must be on the same route (% to %)', v_old.origin, v_old.destination;
  end if;

  if v_new.seats_available is null or v_new.seats_available <= 0 then
    raise exception 'Selected flight has no seats available';
  end if;

  if v_return_flight_id is not null then
    select * into v_return from public.flights f where f.flight_id = v_return_flight_id;
    if v_new.arrival_time >= v_return.departure_time then
      raise exception 'New outbound flight must arrive before your return flight departs';
    end if;
  end if;

  -- Same pricing rules as create_reservation: round trip = outbound fare * 1.85
  v_new_price := case
    when v_return_flight_id is not null then round(v_new.fare * 1.85, 2)
    else round(v_new.fare, 2)
  end;
  v_diff := v_new_price - v_old_price;

  -- Keep the seat only if it is free on the new flight
  if v_seat is not null then
    select exists (
      select 1 from public.reservations r
      where r.flight_id = p_new_flight_id
        and r.seat_number = v_seat
        and r.status in ('pending', 'confirmed')
        and r.id <> p_reservation_id
    ) into v_seat_taken;

    if v_seat_taken then
      v_seat := null;
    end if;
  end if;

  update public.flights f set seats_available = f.seats_available + 1 where f.flight_id = v_old_flight_id;
  update public.flights f set seats_available = f.seats_available - 1 where f.flight_id = p_new_flight_id;

  update public.reservations r
  set flight_id = p_new_flight_id,
      price_paid = v_new_price,
      seat_number = v_seat
  where r.id = p_reservation_id;

  if v_diff <> 0 then
    insert into public.payment_adjustments (reservation_id, user_id, amount, reason)
    values (p_reservation_id, auth.uid(), v_diff, 'rebook_fare_difference');
  end if;

  return query
  select p_reservation_id, v_old_flight_id, p_new_flight_id, v_new_price, v_diff, 'confirmed'::text;
end;
$function$;

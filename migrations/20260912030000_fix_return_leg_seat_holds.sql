-- Fixes S1-09 round-trip booking: the return leg's seat was never held or
-- released, so return flights could be overbooked with no SOLD_OUT check.
--
-- Before this migration:
--   - create_reservation() held/released a seat on the OUTBOUND flight only
--   - set_reservation_return_leg() just linked a return_flight_id/return_date
--     to the reservation without ever decrementing that flight's seat count
--   - cancel_reservation() only ever released the outbound flight's seat
--
-- After this migration, round-trip bookings hold and release a seat on
-- BOTH legs, and booking a sold-out return flight now raises SOLD_OUT
-- instead of silently succeeding.

create or replace function public.set_reservation_return_leg(
  p_reservation_id uuid,
  p_return_date date,
  p_return_flight_id uuid
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_owner uuid;
  v_return_flight public.flights;
begin
  select user_id into v_owner
  from reservations
  where id = p_reservation_id
  for update;

  if v_owner is null then
    raise exception 'Reservation not found';
  end if;

  if v_owner <> auth.uid() then
    raise exception 'Not authorized';
  end if;

  select * into v_return_flight
  from public.flights
  where flight_id = p_return_flight_id
  for update;

  if v_return_flight.flight_id is null then
    raise exception 'Return flight not found';
  end if;

  if v_return_flight.seats_available is null or v_return_flight.seats_available <= 0 then
    raise exception 'SOLD_OUT: The return flight just sold out. Please search again for other options.';
  end if;

  update public.flights
  set seats_available = seats_available - 1
  where flight_id = p_return_flight_id;

  update reservations
  set return_date = p_return_date,
      return_flight_id = p_return_flight_id
  where id = p_reservation_id;
end;
$function$;

create or replace function public.cancel_reservation(p_reservation_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_flight_id uuid;
  v_return_flight_id uuid;
  v_status text;
begin
  select flight_id, return_flight_id, status into v_flight_id, v_return_flight_id, v_status
  from reservations
  where id = p_reservation_id and user_id = auth.uid()
  for update;

  if v_flight_id is null then
    raise exception 'Reservation not found';
  end if;

  if v_status not in ('pending', 'confirmed') then
    raise exception 'Only pending or confirmed reservations can be cancelled';
  end if;

  update flights
  set seats_available = seats_available + 1
  where flight_id = v_flight_id;

  if v_return_flight_id is not null then
    update flights
    set seats_available = seats_available + 1
    where flight_id = v_return_flight_id;
  end if;

  update reservations
  set status = 'cancelled'
  where id = p_reservation_id;
end;
$function$;

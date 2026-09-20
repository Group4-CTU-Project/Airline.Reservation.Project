-- S2-06: Customer rebooking workflow
-- Lets a customer move a confirmed reservation to a different flight.
-- Releases the seat on the old flight, takes a seat on the new flight,
-- updates the reservation's flight_id/price_paid, and returns the fare
-- difference (new fare - old price_paid) for the caller to display.
--
-- Scope notes:
--   * Only 'confirmed' reservations can be rebooked (not 'pending').
--   * Only the outbound flight_id is handled -- round-trip reservations
--     with a return_flight_id are not rebooked by this function.
--   * The fare difference is calculated and returned, but no actual
--     charge/refund is processed -- payment adjustment would need to
--     hook into the existing payments table separately.

create or replace function public.rebook_reservation(p_reservation_id uuid, p_new_flight_id uuid)
returns table (
  reservation_id uuid,
  old_flight_id uuid,
  new_flight_id uuid,
  new_price numeric,
  fare_difference numeric,
  status text
)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_old_flight_id uuid;
  v_old_price numeric;
  v_status text;
  v_new_fare numeric;
  v_new_seats integer;
  v_new_flight_status text;
begin
  select r.flight_id, r.price_paid, r.status
  into v_old_flight_id, v_old_price, v_status
  from reservations r
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

  select f.fare, f.seats_available, f.status
  into v_new_fare, v_new_seats, v_new_flight_status
  from flights f
  where f.flight_id = p_new_flight_id
  for update;

  if v_new_fare is null then
    raise exception 'Selected flight not found';
  end if;

  if v_new_flight_status <> 'scheduled' then
    raise exception 'Selected flight is not available for booking';
  end if;

  if v_new_seats <= 0 then
    raise exception 'Selected flight has no seats available';
  end if;

  update flights set seats_available = seats_available + 1 where flight_id = v_old_flight_id;

  update flights set seats_available = seats_available - 1 where flight_id = p_new_flight_id;

  update reservations
  set flight_id = p_new_flight_id, price_paid = v_new_fare
  where id = p_reservation_id;

  return query
  select p_reservation_id, v_old_flight_id, p_new_flight_id, v_new_fare, (v_new_fare - v_old_price), 'confirmed'::text;
end;
$$;

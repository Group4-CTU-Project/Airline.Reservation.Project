-- Adds real seat selection. Seat availability for the grid UI is derived
-- dynamically from active reservations (pending/confirmed) rather than a
-- separate bitmap, so cancellations and declined payments free the seat
-- automatically with no extra bookkeeping.
--
-- total_seats = cabin capacity for a 6-across (A-F) layout. Seeded from the
-- seats_available count at migration time, since that's the best available
-- baseline for "how many seats does this flight have" pre-seat-map.

alter table public.flights add column if not exists total_seats integer;
update public.flights set total_seats = seats_available where total_seats is null;
alter table public.flights alter column total_seats set not null;

alter table public.reservations add column if not exists seat_number text;
alter table public.reservations add column if not exists return_seat_number text;

-- Prevent two active reservations from claiming the same seat on the same
-- flight (checked separately for outbound and return legs).
create unique index if not exists reservations_unique_active_seat
  on public.reservations (flight_id, seat_number)
  where status in ('pending', 'confirmed') and seat_number is not null;

create unique index if not exists reservations_unique_active_return_seat
  on public.reservations (return_flight_id, return_seat_number)
  where status in ('pending', 'confirmed') and return_flight_id is not null and return_seat_number is not null;

-- Returns every seat currently held (pending or confirmed) on a flight, for
-- rendering the seat map. Readable without login since seat occupancy
-- itself isn't sensitive -- only the passenger identity behind it is.
create or replace function public.get_taken_seats(p_flight_id uuid)
returns table(seat_number text)
language sql
security definer
set search_path to 'public'
as $function$
  select seat_number
  from public.reservations
  where flight_id = p_flight_id
    and status in ('pending', 'confirmed')
    and seat_number is not null
  union
  select return_seat_number
  from public.reservations
  where return_flight_id = p_flight_id
    and status in ('pending', 'confirmed')
    and return_seat_number is not null;
$function$;

grant execute on function public.get_taken_seats(uuid) to anon, authenticated;

-- create_reservation and set_reservation_return_leg's signatures changed
-- (added p_seat_number / p_return_seat_number), so the old overloads must
-- be dropped explicitly before recreating -- CREATE OR REPLACE alone
-- would leave the old signature behind as a separate, stale overload.
drop function if exists public.get_my_reservations();
drop function if exists public.create_reservation(uuid, text, text, text, numeric);
drop function if exists public.set_reservation_return_leg(uuid, date, uuid);

-- create_reservation now requires and validates a specific seat.
create or replace function public.create_reservation(
  p_flight_id uuid,
  p_passenger_name text,
  p_passenger_email text,
  p_trip_type text,
  p_expected_price numeric,
  p_seat_number text
)
returns table(reservation_id uuid, status text, price_paid numeric, seats_remaining integer)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_flight public.flights;
  v_fare_for_trip numeric;
  v_reservation_id uuid;
  v_status text;
  v_seat_taken boolean;
begin
  if auth.uid() is null then
    raise exception 'Must be authenticated to book a flight';
  end if;

  if p_seat_number is null or p_seat_number = '' then
    raise exception 'A seat must be selected to book this flight';
  end if;

  select * into v_flight
  from public.flights
  where flight_id = p_flight_id
  for update;

  if v_flight.flight_id is null then
    raise exception 'Flight not found';
  end if;

  if v_flight.seats_available is null or v_flight.seats_available <= 0 then
    raise exception 'SOLD_OUT: This flight just sold out. Please search again for other options.';
  end if;

  select exists(
    select 1 from public.reservations
    where flight_id = p_flight_id
      and seat_number = p_seat_number
      and reservations.status in ('pending', 'confirmed')
  ) into v_seat_taken;

  if v_seat_taken then
    raise exception 'SEAT_TAKEN: Seat % was just taken. Please pick another seat.', p_seat_number;
  end if;

  v_fare_for_trip := case
    when p_trip_type = 'roundtrip' then round(v_flight.fare * 1.85, 2)
    else round(v_flight.fare, 2)
  end;

  if abs(v_fare_for_trip - round(p_expected_price, 2)) > 0.01 then
    raise exception 'FARE_CHANGED: %', v_fare_for_trip;
  end if;

  update public.flights
  set seats_available = seats_available - 1
  where flight_id = p_flight_id;

  insert into public.reservations (user_id, flight_id, passenger_name, passenger_email, price_paid, seat_number)
  values (auth.uid(), p_flight_id, p_passenger_name, p_passenger_email, v_fare_for_trip, p_seat_number)
  returning reservations.id, reservations.status into v_reservation_id, v_status;

  return query
  select v_reservation_id, v_status, v_fare_for_trip, (v_flight.seats_available - 1);
end;
$function$;

-- set_reservation_return_leg now also requires and validates a seat on the
-- return flight, and holds/releases that flight's seat count.
create or replace function public.set_reservation_return_leg(
  p_reservation_id uuid,
  p_return_date date,
  p_return_flight_id uuid,
  p_return_seat_number text
)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_owner uuid;
  v_return_flight public.flights;
  v_seat_taken boolean;
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

  if p_return_seat_number is null or p_return_seat_number = '' then
    raise exception 'A seat must be selected for the return flight';
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

  select exists(
    select 1 from public.reservations
    where return_flight_id = p_return_flight_id
      and return_seat_number = p_return_seat_number
      and status in ('pending', 'confirmed')
  ) into v_seat_taken;

  if v_seat_taken then
    raise exception 'SEAT_TAKEN: Seat % was just taken on the return flight. Please pick another seat.', p_return_seat_number;
  end if;

  update public.flights
  set seats_available = seats_available - 1
  where flight_id = p_return_flight_id;

  update reservations
  set return_date = p_return_date,
      return_flight_id = p_return_flight_id,
      return_seat_number = p_return_seat_number
  where id = p_reservation_id;
end;
$function$;

-- get_my_reservations now also returns seat numbers for My Trips / tickets.
create or replace function public.get_my_reservations()
returns table(reservation_id uuid, status text, price_paid numeric, created_at timestamp with time zone, passenger_name text, passenger_email text, flight_id uuid, origin text, destination text, departure_time timestamp with time zone, arrival_time timestamp with time zone, seat_number text, return_date date, return_flight_id uuid, return_origin text, return_destination text, return_departure_time timestamp with time zone, return_arrival_time timestamp with time zone, return_seat_number text, card_brand text, last4 text, payment_result text)
language sql
security definer
set search_path to 'public'
as $function$
  select
    r.id as reservation_id,
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
    rf.flight_id as return_flight_id,
    rf.origin as return_origin,
    rf.destination as return_destination,
    rf.departure_time as return_departure_time,
    rf.arrival_time as return_arrival_time,
    r.return_seat_number,
    p.card_brand,
    p.last4,
    p.result as payment_result
  from reservations r
  join flights f on f.flight_id = r.flight_id
  left join flights rf on rf.flight_id = r.return_flight_id
  left join payments p on p.reservation_id = r.id
  where r.user_id = auth.uid()
  order by r.created_at desc;
$function$;

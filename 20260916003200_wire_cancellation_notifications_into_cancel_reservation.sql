-- S2-05: Wire cancellation_notifications into cancel_reservation
-- Every call to cancel_reservation now queues a notification row
-- in addition to its existing seat-release and status-update logic.
--
-- Note: signature is unchanged (still cancel_reservation(uuid)), so
-- CREATE OR REPLACE is safe here -- no DROP FUNCTION needed per our
-- function-signature-hygiene rule, which only applies when the
-- signature itself changes.

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
  v_user_id uuid;
  v_passenger_email text;
begin
  select flight_id, return_flight_id, status, user_id, passenger_email
  into v_flight_id, v_return_flight_id, v_status, v_user_id, v_passenger_email
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

  insert into cancellation_notifications (reservation_id, user_id, passenger_email, notification_type, status, message)
  values (
    p_reservation_id,
    v_user_id,
    v_passenger_email,
    'email',
    'queued',
    'Your reservation has been cancelled.'
  );
end;
$function$;

-- S2-02: Flight-status lookup
-- Returns the current status/times for a single flight by ID.
-- Empty result set = flight not found ("unavailable" case, handled client-side).
-- Timeout handling is a client-side concern (abort + fallback message) and
-- is not represented in this migration.

create or replace function public.get_flight_status(p_flight_id uuid)
returns table (
  flight_id uuid,
  origin text,
  destination text,
  departure_time timestamptz,
  arrival_time timestamptz,
  status text
)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  return query
  select f.flight_id, f.origin, f.destination, f.departure_time, f.arrival_time, f.status
  from flights f
  where f.flight_id = p_flight_id;
end;
$$;

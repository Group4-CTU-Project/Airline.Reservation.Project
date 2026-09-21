-- Seed future alternate flights (2 per route, 15 routes) and fix an invalid arrival time.
--
-- Why: 19 of 25 flights were already in the past and every route had at most one future
-- flight, so rebooking (same route, not departed) and flight search had nothing to offer.
--
-- Notes:
--   * Two dates per route: Fri 2026-09-25 and Fri 2026-10-02 (a week apart, so round trips work).
--   * Times follow each route's existing convention (domestic and NRT>LAX: arrival = departure
--     + flight time; other international routes: arrival shown as local clock time).
--   * Idempotent: a seed row is skipped if a flight with the same route + departure_time exists.

-- 1) NRT>LAX f271e246 had arrival_time BEFORE departure_time (local arrival across the date line).
--    Store it as departure + flight time instead (17:45 + 8h35m).
update public.flights
set arrival_time = departure_time + interval '8 hours 35 minutes'
where flight_id = 'f271e246-4b87-4463-8dcc-8e81bfe4f0ef'
  and arrival_time < departure_time;

-- 2) Seed flights
with seed(origin, destination, departure_time, arrival_time, fare) as (
  values
    -- JFK > LAX
    ('JFK','LAX','2026-09-25 07:30:00+00','2026-09-25 13:50:00+00','229.00'),
    ('JFK','LAX','2026-10-02 15:45:00+00','2026-10-02 22:05:00+00','199.00'),
    -- LAX > JFK
    ('LAX','JFK','2026-09-25 08:00:00+00','2026-09-25 13:25:00+00','249.00'),
    ('LAX','JFK','2026-10-02 19:30:00+00','2026-10-03 00:55:00+00','229.00'),
    -- JFK > LHR
    ('JFK','LHR','2026-09-25 19:00:00+00','2026-09-26 07:15:00+00','569.00'),
    ('JFK','LHR','2026-10-02 22:15:00+00','2026-10-03 10:30:00+00','529.00'),
    -- LHR > JFK
    ('LHR','JFK','2026-09-25 09:30:00+00','2026-09-25 12:20:00+00','589.00'),
    ('LHR','JFK','2026-10-02 14:00:00+00','2026-10-02 16:50:00+00','559.00'),
    -- LAX > NRT
    ('LAX','NRT','2026-09-25 11:30:00+00','2026-09-26 15:00:00+00','709.00'),
    ('LAX','NRT','2026-10-02 14:45:00+00','2026-10-03 18:15:00+00','669.00'),
    -- NRT > LAX
    ('NRT','LAX','2026-09-25 16:30:00+00','2026-09-26 01:05:00+00','729.00'),
    ('NRT','LAX','2026-10-02 18:20:00+00','2026-10-03 02:55:00+00','699.00'),
    -- ORD > CDG
    ('ORD','CDG','2026-09-25 17:30:00+00','2026-09-26 07:25:00+00','519.00'),
    ('ORD','CDG','2026-10-02 21:00:00+00','2026-10-03 10:55:00+00','479.00'),
    -- CDG > ORD
    ('CDG','ORD','2026-09-25 09:00:00+00','2026-09-25 11:45:00+00','529.00'),
    ('CDG','ORD','2026-10-02 13:30:00+00','2026-10-02 16:15:00+00','499.00'),
    -- ATL > DFW
    ('ATL','DFW','2026-09-25 07:45:00+00','2026-09-25 10:25:00+00','154.99'),
    ('ATL','DFW','2026-10-02 13:15:00+00','2026-10-02 15:55:00+00','139.99'),
    -- DFW > ATL
    ('DFW','ATL','2026-09-25 09:30:00+00','2026-09-25 11:50:00+00','154.99'),
    ('DFW','ATL','2026-10-02 18:00:00+00','2026-10-02 20:20:00+00','144.99'),
    -- ORD > MIA
    ('ORD','MIA','2026-09-25 09:00:00+00','2026-09-25 12:10:00+00','189.99'),
    ('ORD','MIA','2026-10-02 16:30:00+00','2026-10-02 19:40:00+00','174.99'),
    -- MIA > ORD
    ('MIA','ORD','2026-09-25 08:15:00+00','2026-09-25 11:30:00+00','184.99'),
    ('MIA','ORD','2026-10-02 15:00:00+00','2026-10-02 18:15:00+00','169.99'),
    -- SEA > SFO
    ('SEA','SFO','2026-09-25 09:00:00+00','2026-09-25 11:15:00+00','134.99'),
    ('SEA','SFO','2026-10-02 15:30:00+00','2026-10-02 17:45:00+00','124.99'),
    -- SFO > SEA
    ('SFO','SEA','2026-09-25 08:30:00+00','2026-09-25 10:45:00+00','134.99'),
    ('SFO','SEA','2026-10-02 13:00:00+00','2026-10-02 15:15:00+00','124.99'),
    -- SFO > LAX
    ('SFO','LAX','2026-09-25 10:00:00+00','2026-09-25 11:20:00+00','94.99'),
    ('SFO','LAX','2026-10-02 17:30:00+00','2026-10-02 18:50:00+00','84.99')
)
insert into public.flights (origin, destination, departure_time, arrival_time, fare, seats_available, total_seats, status)
select
  s.origin,
  s.destination,
  s.departure_time::timestamptz,
  s.arrival_time::timestamptz,
  s.fare::numeric,
  48,
  48,
  'scheduled'
from seed s
where not exists (
  select 1 from public.flights f
  where f.origin = s.origin
    and f.destination = s.destination
    and f.departure_time = s.departure_time::timestamptz
);

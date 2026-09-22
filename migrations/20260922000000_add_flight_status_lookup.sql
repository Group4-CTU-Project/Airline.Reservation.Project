-- S2-02 / PB-07: flight-status lookup.
--
-- flights already has a `status` column (default 'scheduled', set up before
-- migration tracking started -- see 20260921010000_baseline_capture_
-- predates_migrations.sql) but nothing in the app ever reads or writes it,
-- and there's no rider-facing way to look a flight up by anything other
-- than origin/destination/date (which returns every matching flight, not
-- one specific one). This migration adds the missing piece: a human
-- flight number to search by.
--
-- flights is already selectable straight from the client with no RPC --
-- the existing flight search does a plain `.from('flights')` select and
-- works for logged-out visitors, so flight_number needs no new RLS policy
-- or wrapper function; the frontend just adds `flight_number` to the same
-- kind of direct select.

alter table public.flights add column if not exists flight_number text;

-- Backfill every existing row with a stable, sequential number (CN001,
-- CN002, ...) ordered by departure time so earlier flights get lower
-- numbers -- purely cosmetic ordering, doesn't need to mean anything
-- operationally.
with numbered as (
  select flight_id, row_number() over (order by departure_time, flight_id) as rn
  from public.flights
  where flight_number is null
)
update public.flights f
set flight_number = 'CN' || lpad(numbered.rn::text, 3, '0')
from numbered
where f.flight_id = numbered.flight_id;

-- Going forward, any flight inserted without an explicit flight_number
-- (e.g. added by hand in the Supabase table editor, the same way the
-- original seed data was) still gets a unique one automatically instead of
-- landing on flight_number = null and becoming unlookupable. The sequence
-- starts past the count of rows just backfilled so it can't collide with
-- the CN001.. numbers already assigned above.
create sequence if not exists public.flight_number_seq;
select setval('public.flight_number_seq', (select count(*) from public.flights), true);
alter table public.flights
  alter column flight_number set default ('CN' || lpad(nextval('public.flight_number_seq')::text, 3, '0'));

alter table public.flights alter column flight_number set not null;

create unique index if not exists flights_flight_number_key on public.flights (flight_number);

-- No grants needed -- flights is already readable without one (see note
-- above); this just adds a column to a table that's already public-select.

-- Removes book_flight / release_reservation / confirm_reservation: the
-- original booking lifecycle, confirmed still present in the live database
-- via a pg_proc check, but superseded by create_reservation() /
-- process_payment() / cancel_reservation() and never formally retired.
--
-- Why drop rather than leave alone: all three are `grant execute ...
-- to authenticated`, so any signed-in user could call book_flight()
-- directly right now via the Supabase client and get a reservation that
-- bypasses seat selection (no p_seat_number param -- seat_number would be
-- left null), the fare-change check create_reservation() enforces, and
-- round-trip handling entirely. Nothing in the frontend or any migration
-- calls any of the three, so there's no legitimate caller to preserve.
--
-- Exact signatures taken from the original CREATE FUNCTION statements
-- (matches the "Reservation table" saved query in the Supabase SQL editor).

drop function if exists public.book_flight(uuid, text, text);
drop function if exists public.release_reservation(uuid);
drop function if exists public.confirm_reservation(uuid);

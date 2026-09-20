# Cloud Nine Airline Reservations

A Sprint 1 demo project for an airline reservation system, built with a static HTML/JS front end and a Supabase backend (Postgres + RPC functions for auth, bookings, payments, and seat selection).

## Structure

- `airline-reservation-demo.html` — the demo app. Open it directly in a browser (no build step). On first load, replace `SUPABASE_URL` and `SUPABASE_ANON_KEY` near the bottom of the file with your own Supabase project's values (Settings → API).
- `migrations/` — SQL migrations, in the order they should be run, based on their timestamp prefix (`YYYYMMDDHHMMSS_description.sql`). Apply them in order against your Supabase project.

## Features

- Account creation, login with failed-attempt lockout, and role-based content (server-enforced via RPC).
- Flight search, round-trip booking with automatic return-flight lookup, and seat selection.
- Payment step with saved payment methods.
- "My trips" view with e-tickets/receipts and trip cancellation.

## Working on this repo

To keep history clean and avoid overwriting each other's work:

1. **Don't upload files directly to `main`.** Create a branch first (or use GitHub's "Create a new branch and start a pull request" option when uploading).
2. **Open a pull request** for any change, even a small one, so it's easy to see what changed and to review before it lands on `main`.
3. **Merge through the PR**, not by re-uploading the same file to `main`.

This avoids duplicate files (like the old `airline-reservation-demo (N).html` copies) and lost work sitting only on someone's laptop.

-- Baseline capture (part 2): the login-lockout RPC functions.
--
-- 20260921010000_baseline_capture_predates_migrations.sql already captured
-- the login_attempts TABLE, but not these three functions that operate on
-- it -- also never in any migration, despite being live and actively
-- called by the frontend (check_login_lock / record_failed_login /
-- clear_login_attempts, wired into the login form's failed-attempt
-- limiting). Confirmed accurate against production, not a stale draft:
-- the 5-attempt / 15-minute lockout here matches the frontend's own
-- MAX_FAILED_ATTEMPTS / LOCKOUT_MINUTES constants exactly.
--
-- Uses `create or replace`, which is safe to run against the current
-- database -- it will define the functions identically to what's already
-- live, not change their behavior.

create or replace function public.check_login_lock(p_email text)
returns timestamptz
language sql
security definer
set search_path = public
as $$
  select locked_until from login_attempts
  where email = lower(p_email) and locked_until > now();
$$;

create or replace function public.record_failed_login(p_email text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
  v_locked_until timestamptz;
begin
  select failed_count, locked_until into v_count, v_locked_until
  from login_attempts where email = lower(p_email);

  -- Lockout has expired, so start counting fresh
  if v_locked_until is not null and v_locked_until <= now() then
    v_count := 0;
    v_locked_until := null;
  end if;

  v_count := coalesce(v_count, 0) + 1;

  insert into login_attempts (email, failed_count, locked_until, updated_at)
  values (
    lower(p_email),
    v_count,
    case when v_count >= 5 then now() + interval '15 minutes' else null end,
    now()
  )
  on conflict (email) do update
    set failed_count = excluded.failed_count,
        locked_until = excluded.locked_until,
        updated_at = now();
end;
$$;

create or replace function public.clear_login_attempts(p_email text)
returns void
language sql
security definer
set search_path = public
as $$
  delete from login_attempts where email = lower(p_email);
$$;

-- anon (not just authenticated) needs these: failed-attempt tracking runs
-- during the login attempt itself, before a session exists.
grant execute on function public.check_login_lock(text) to anon, authenticated;
grant execute on function public.record_failed_login(text) to anon, authenticated;
grant execute on function public.clear_login_attempts(text) to anon, authenticated;

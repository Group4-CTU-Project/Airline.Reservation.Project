-- S2-07: Admin cancellation controls + audit logging (hardening)
-- Builds on 20260917010702_add_admin_audit_log and 20260917010709_add_admin_cancel_reservation_rpc.
--   1. admin_audit_log.target_user_id so role changes can be logged
--   2. admin_audit_log is append-only for API roles
--   3. admin_cancel_reservation now requires a reason
--   4. set_user_role writes an audit row (covers set_user_role_by_email too)
--   5. get_admin_audit_log() RPC for the admin UI

-- 1. Audit log can reference a user (role changes), not just a reservation
alter table public.admin_audit_log
  add column if not exists target_user_id uuid references auth.users(id);

create index if not exists admin_audit_log_created_at_idx on public.admin_audit_log (created_at desc);

-- 2. Append-only: clients can never write/alter the log directly.
--    SECURITY DEFINER functions (run as owner) still insert.
revoke insert, update, delete, truncate on public.admin_audit_log from anon, authenticated;

-- 3. admin_cancel_reservation: reason is now required.
--    Must drop first: CREATE OR REPLACE cannot remove a parameter default.
drop function if exists public.admin_cancel_reservation(uuid, text);

create function public.admin_cancel_reservation(p_reservation_id uuid, p_reason text)
returns table(reservation_id uuid, status text, cancelled_by uuid)
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_flight_id uuid;
  v_return_flight_id uuid;
  v_status text;
  v_user_id uuid;
  v_passenger_email text;
  v_admin_id uuid := auth.uid();
begin
  if not exists (select 1 from public.profiles pr where pr.id = v_admin_id and pr.role = 'admin') then
    raise exception 'Access denied: admin role required';
  end if;

  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'A cancellation reason is required';
  end if;

  select r.flight_id, r.return_flight_id, r.status, r.user_id, r.passenger_email
    into v_flight_id, v_return_flight_id, v_status, v_user_id, v_passenger_email
  from public.reservations r
  where r.id = p_reservation_id
  for update;

  if v_flight_id is null then
    raise exception 'Reservation not found';
  end if;

  if v_status not in ('pending', 'confirmed') then
    raise exception 'Only pending or confirmed reservations can be cancelled';
  end if;

  update public.flights f set seats_available = f.seats_available + 1 where f.flight_id = v_flight_id;
  if v_return_flight_id is not null then
    update public.flights f set seats_available = f.seats_available + 1 where f.flight_id = v_return_flight_id;
  end if;

  update public.reservations r set status = 'cancelled' where r.id = p_reservation_id;

  insert into public.cancellation_notifications (reservation_id, user_id, passenger_email, notification_type, status, message)
  values (p_reservation_id, v_user_id, v_passenger_email, 'email', 'queued',
          'Your reservation has been cancelled by an administrator.');

  insert into public.admin_audit_log (admin_id, action, target_reservation_id, target_user_id, reason, details)
  values (v_admin_id, 'admin_cancel_reservation', p_reservation_id, v_user_id, trim(p_reason),
          jsonb_build_object('previous_status', v_status));

  return query select p_reservation_id, 'cancelled'::text, v_admin_id;
end;
$function$;

-- 4. Role changes are now audited (set_user_role_by_email calls this, so both paths log)
create or replace function public.set_user_role(p_user_id uuid, p_new_role text)
returns void
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_old_role text;
begin
  if not exists (
    select 1 from public.profiles pr
    where pr.id = auth.uid() and pr.role in ('admin', 'manager')
  ) then
    raise exception 'Access denied: admin or manager role required';
  end if;

  if p_user_id = auth.uid() then
    raise exception 'Cannot change your own role';
  end if;

  if p_new_role not in ('customer', 'admin', 'manager') then
    raise exception 'Invalid role: %', p_new_role;
  end if;

  select pr.role into v_old_role from public.profiles pr where pr.id = p_user_id;
  if not found then
    raise exception 'No such user';
  end if;

  update public.profiles pr set role = p_new_role where pr.id = p_user_id;

  insert into public.admin_audit_log (admin_id, action, target_user_id, details)
  values (auth.uid(), 'set_user_role', p_user_id,
          jsonb_build_object('old_role', v_old_role, 'new_role', p_new_role));
end;
$function$;

-- 5. Read the audit log with names resolved (admin-only, paginated)
create or replace function public.get_admin_audit_log(
  p_action text default null,
  p_limit integer default 25,
  p_offset integer default 0
)
returns table(
  log_id uuid,
  logged_at timestamptz,
  actor_name text,
  actor_email text,
  action_type text,
  target_reservation_id uuid,
  target_name text,
  reason_text text,
  details_json jsonb,
  total_count bigint
)
language plpgsql
security definer
set search_path = public
as $function$
begin
  if not exists (select 1 from public.profiles pr where pr.id = auth.uid() and pr.role = 'admin') then
    raise exception 'Access denied: admin role required';
  end if;

  return query
  select a.id,
         a.created_at,
         actor.full_name,
         actor.email,
         a.action,
         a.target_reservation_id,
         coalesce(res.passenger_name, tgt.full_name, tgt.email),
         a.reason,
         a.details,
         count(*) over ()
  from public.admin_audit_log a
  left join public.profiles actor on actor.id = a.admin_id
  left join public.reservations res on res.id = a.target_reservation_id
  left join public.profiles tgt on tgt.id = a.target_user_id
  where p_action is null or a.action = p_action
  order by a.created_at desc
  limit least(greatest(coalesce(p_limit, 25), 1), 100)
  offset greatest(coalesce(p_offset, 0), 0);
end;
$function$;

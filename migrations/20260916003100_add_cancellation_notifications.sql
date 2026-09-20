-- S2-05: Cancellation-notification workflow
-- Logs a queued notification record whenever a reservation is cancelled.
-- Does not send real email/SMS yet -- that requires an Edge Function wired
-- to a provider (e.g. SendGrid/Twilio), which is separate, larger work.

create table if not exists public.cancellation_notifications (
  id uuid primary key default gen_random_uuid(),
  reservation_id uuid not null references public.reservations(id),
  user_id uuid not null,
  passenger_email text not null,
  notification_type text not null default 'email' check (notification_type in ('email','sms')),
  status text not null default 'queued' check (status in ('queued','sent','failed')),
  message text,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);

alter table public.cancellation_notifications enable row level security;

create policy "Users can view their own cancellation notifications"
  on public.cancellation_notifications
  for select
  using (user_id = auth.uid());

-- S1-10 security testing found two real vulnerabilities on public.profiles:
--
-- 1. "Enable read access for all users" had qual = true with no restriction,
--    letting anyone (including unauthenticated visitors) read every user's
--    email and full_name. RLS policies are OR'd together, so this alone
--    overrode the correctly-scoped "own profile only" policies.
--
-- 2. "users can create their own profile" (INSERT) and
--    "users can update their own profile" (UPDATE) checked only
--    auth.uid() = id, with no restriction on the role column. Any
--    authenticated user could set their own role to 'admin' and gain
--    access to admin_notes, since that table's policy just checks
--    profiles.role = 'admin'. Correctly-scoped sibling policies already
--    existed (with_check enforcing role = 'customer') but did nothing
--    to stop this, since permissive policies are OR'd.
--
-- Fix: drop the three insecure/unrestricted policies. The remaining
-- policies (auth.uid() = id for SELECT/UPDATE, and role = 'customer'
-- enforced on INSERT/UPDATE) are sufficient and correct on their own.

drop policy if exists "Enable read access for all users" on public.profiles;
drop policy if exists "users can create their own profile" on public.profiles;
drop policy if exists "users can update their own profile" on public.profiles;

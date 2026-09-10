-- RLS: deny by default everywhere. Public catalog is readable by anon;
-- every write path goes through the Edge Function using the service role,
-- which bypasses RLS. No anon INSERT/UPDATE/DELETE anywhere.

alter table omnibook.providers           enable row level security;
alter table omnibook.services            enable row level security;
alter table omnibook.slots               enable row level security;
alter table omnibook.clients             enable row level security;
alter table omnibook.bookings            enable row level security;
alter table omnibook.whatsapp_dispatches enable row level security;
alter table omnibook.leads               enable row level security;

drop policy if exists providers_public_read on omnibook.providers;
create policy providers_public_read on omnibook.providers
  for select to anon, authenticated
  using (is_published);

drop policy if exists services_public_read on omnibook.services;
create policy services_public_read on omnibook.services
  for select to anon, authenticated
  using (
    is_active
    and exists (select 1 from omnibook.providers p where p.id = services.provider_id and p.is_published)
  );

drop policy if exists slots_public_read on omnibook.slots;
create policy slots_public_read on omnibook.slots
  for select to anon, authenticated
  using (exists (select 1 from omnibook.providers p where p.id = slots.provider_id and p.is_published));

-- clients, bookings, whatsapp_dispatches and leads carry NO anon policy: RLS is
-- on with zero permissive policies, so anon reads and writes are denied
-- outright. Only the service role reaches them.

grant usage on schema omnibook to anon, authenticated, service_role;
grant select on omnibook.providers, omnibook.services, omnibook.slots to anon, authenticated;
grant all on all tables in schema omnibook to service_role;
grant all on all sequences in schema omnibook to service_role;

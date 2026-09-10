-- OmniBook: WhatsApp-native appointment booking platform.
-- Isolated in its own schema: this project's `public` schema hosts an unrelated app.

create schema if not exists omnibook;

do $$ begin
  create type omnibook.booking_status as enum (
    'pending', 'awaiting_deposit', 'confirmed', 'completed', 'cancelled', 'no_show'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type omnibook.provider_category as enum (
    'medical', 'dental', 'beauty', 'wellness', 'legal', 'financial'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type omnibook.dispatch_kind as enum (
    'confirmation', 'reminder_24h', 'reminder_2h', 'reschedule', 'deposit_request', 'receipt', 'cancellation'
  );
exception when duplicate_object then null; end $$;

create table if not exists omnibook.providers (
  id                uuid primary key default gen_random_uuid(),
  slug              text not null unique,
  display_name      text not null,
  headline          text,
  bio               text,
  category          omnibook.provider_category not null,
  specialty         text,
  city              text not null default 'New York',
  address           text,
  avatar_url        text,
  rating            numeric(3,2) not null default 0 check (rating >= 0 and rating <= 5),
  review_count      integer not null default 0 check (review_count >= 0),
  whatsapp_number   text,
  whatsapp_verified boolean not null default false,
  is_published      boolean not null default true,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index if not exists providers_category_idx on omnibook.providers (category) where is_published;
create index if not exists providers_city_idx on omnibook.providers (city) where is_published;

create table if not exists omnibook.services (
  id               uuid primary key default gen_random_uuid(),
  provider_id      uuid not null references omnibook.providers(id) on delete cascade,
  name             text not null,
  description      text,
  duration_minutes integer not null check (duration_minutes between 5 and 600),
  price_cents      integer not null check (price_cents >= 0),
  currency         char(3) not null default 'USD',
  deposit_cents    integer not null default 0 check (deposit_cents >= 0),
  is_active        boolean not null default true,
  created_at       timestamptz not null default now()
);

create index if not exists services_provider_idx on omnibook.services (provider_id) where is_active;

create table if not exists omnibook.slots (
  id          uuid primary key default gen_random_uuid(),
  provider_id uuid not null references omnibook.providers(id) on delete cascade,
  service_id  uuid references omnibook.services(id) on delete set null,
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,
  is_booked   boolean not null default false,
  created_at  timestamptz not null default now(),
  constraint slots_time_order check (ends_at > starts_at),
  constraint slots_no_double_book unique (provider_id, starts_at)
);

create index if not exists slots_open_idx on omnibook.slots (provider_id, starts_at) where not is_booked;

create table if not exists omnibook.clients (
  id              uuid primary key default gen_random_uuid(),
  whatsapp_number text not null unique,
  full_name       text,
  email           text,
  created_at      timestamptz not null default now()
);

create table if not exists omnibook.bookings (
  id              uuid primary key default gen_random_uuid(),
  reference       text not null unique,
  provider_id     uuid not null references omnibook.providers(id) on delete cascade,
  service_id      uuid references omnibook.services(id) on delete set null,
  slot_id         uuid unique references omnibook.slots(id) on delete set null,
  client_id       uuid references omnibook.clients(id) on delete set null,
  status          omnibook.booking_status not null default 'pending',
  starts_at       timestamptz not null,
  price_cents     integer not null default 0 check (price_cents >= 0),
  notes           text,
  whatsapp_synced boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create index if not exists bookings_provider_idx on omnibook.bookings (provider_id, starts_at desc);
create index if not exists bookings_client_idx on omnibook.bookings (client_id, starts_at desc);

create table if not exists omnibook.whatsapp_dispatches (
  id           uuid primary key default gen_random_uuid(),
  booking_id   uuid references omnibook.bookings(id) on delete cascade,
  kind         omnibook.dispatch_kind not null,
  to_number    text not null,
  body         text,
  delivered_at timestamptz,
  created_at   timestamptz not null default now()
);

create index if not exists dispatches_booking_idx on omnibook.whatsapp_dispatches (booking_id, created_at desc);

create table if not exists omnibook.leads (
  id            uuid primary key default gen_random_uuid(),
  business_name text,
  contact_name  text,
  email         text,
  whatsapp      text,
  category      text,
  message       text,
  source        text not null default 'landing',
  created_at    timestamptz not null default now()
);

create index if not exists leads_created_idx on omnibook.leads (created_at desc);

create or replace function omnibook.touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists providers_touch on omnibook.providers;
create trigger providers_touch before update on omnibook.providers
  for each row execute function omnibook.touch_updated_at();

drop trigger if exists bookings_touch on omnibook.bookings;
create trigger bookings_touch before update on omnibook.bookings
  for each row execute function omnibook.touch_updated_at();

-- Atomic booking: claims the slot, upserts the client, writes the booking and
-- queues the WhatsApp confirmation in one transaction. The slot row is locked
-- FOR UPDATE so two concurrent callers cannot claim the same time.
--
-- NOTE: superseded by 20260910201517_omnibook_fix_booking_reference.sql —
-- gen_random_bytes() is unreachable under `set search_path = ''`.

create or replace function omnibook.create_booking(
  p_slot_id   uuid,
  p_whatsapp  text,
  p_full_name text default null,
  p_notes     text default null
)
returns table (
  booking_id  uuid,
  reference   text,
  status      omnibook.booking_status,
  starts_at   timestamptz,
  provider    text,
  service     text,
  price_cents integer
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_slot     omnibook.slots;
  v_service  omnibook.services;
  v_provider omnibook.providers;
  v_client   uuid;
  v_ref      text;
  v_status   omnibook.booking_status;
  v_booking  uuid;
  v_price    integer;
begin
  if p_whatsapp is null or length(trim(p_whatsapp)) < 7 then
    raise exception 'A valid WhatsApp number is required' using errcode = '22023';
  end if;

  -- Lock the slot so concurrent bookings serialise on it.
  select * into v_slot from omnibook.slots where id = p_slot_id for update;

  if not found then
    raise exception 'Slot not found' using errcode = 'P0002';
  end if;
  if v_slot.is_booked then
    raise exception 'That slot has just been taken' using errcode = '23505';
  end if;
  if v_slot.starts_at <= now() then
    raise exception 'That slot is in the past' using errcode = '22023';
  end if;

  select * into v_provider from omnibook.providers where id = v_slot.provider_id;
  select * into v_service  from omnibook.services  where id = v_slot.service_id;

  v_price  := coalesce(v_service.price_cents, 0);
  v_status := case
    when coalesce(v_service.deposit_cents, 0) > 0 then 'awaiting_deposit'::omnibook.booking_status
    else 'confirmed'::omnibook.booking_status
  end;

  insert into omnibook.clients (whatsapp_number, full_name)
  values (trim(p_whatsapp), nullif(trim(coalesce(p_full_name, '')), ''))
  on conflict (whatsapp_number) do update
    set full_name = coalesce(excluded.full_name, omnibook.clients.full_name)
  returning id into v_client;

  v_ref := 'OB-' || upper(substr(encode(gen_random_bytes(4), 'hex'), 1, 8));

  insert into omnibook.bookings
    (reference, provider_id, service_id, slot_id, client_id, status, starts_at, price_cents, notes, whatsapp_synced)
  values
    (v_ref, v_slot.provider_id, v_slot.service_id, v_slot.id, v_client, v_status,
     v_slot.starts_at, v_price, nullif(trim(coalesce(p_notes, '')), ''), true)
  returning id into v_booking;

  update omnibook.slots set is_booked = true where id = v_slot.id;

  insert into omnibook.whatsapp_dispatches (booking_id, kind, to_number, body, delivered_at)
  values (
    v_booking,
    case when v_status = 'awaiting_deposit' then 'deposit_request'::omnibook.dispatch_kind
         else 'confirmation'::omnibook.dispatch_kind end,
    trim(p_whatsapp),
    format(
      'OmniBook: %s with %s on %s. Reference %s. Reply 1 to confirm or 2 to reschedule.',
      coalesce(v_service.name, 'Appointment'),
      v_provider.display_name,
      to_char(v_slot.starts_at, 'Dy DD Mon at HH12:MI AM'),
      v_ref
    ),
    now()
  );

  return query
  select v_booking, v_ref, v_status, v_slot.starts_at,
         v_provider.display_name, coalesce(v_service.name, 'Appointment'), v_price;
end;
$$;

revoke all on function omnibook.create_booking(uuid, text, text, text) from public, anon, authenticated;
grant execute on function omnibook.create_booking(uuid, text, text, text) to service_role;

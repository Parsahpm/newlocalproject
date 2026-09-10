-- Seed the marketplace catalog. Idempotent: providers keyed by slug.

insert into omnibook.providers
  (slug, display_name, headline, bio, category, specialty, city, address, rating, review_count, whatsapp_number, whatsapp_verified)
values
  ('elena-vance', 'Dr. Elena Vance, MD', 'Manhattan Aesthetics & Clinical Skin Health',
   'Double board-certified clinical and cosmetic dermatologist specialising in non-invasive aesthetic harmonisation, acute acne solutions, and precision melanoma screenings.',
   'medical', 'Board-Certified Dermatology', 'New York', 'Suite 840, 1024 5th Ave, New York, NY 10028', 4.98, 342, '+15550192834', true),
  ('maison-glow', 'Maison Glow Atelier', 'SoHo Studio - Master Stylist Julian & Team',
   'Luxury colour atelier delivering signature balayage, gloss treatments and precision cutting in a calm, appointment-only studio.',
   'beauty', 'Master Colorist & Styling', 'New York', '112 Greene St, New York, NY 10012', 4.95, 520, '+15550192801', true),
  ('sterling-cole', 'Sterling & Cole Legal', 'Midtown East - Partner Legal Counsel',
   'Corporate and contract counsel for founders and established practices. Encrypted document exchange and retainer assessments.',
   'legal', 'Corporate & Contract Law', 'New York', '460 Park Ave, New York, NY 10022', 5.00, 110, '+15550192802', true),
  ('purezen-wellness', 'PureZen Wellness', 'Chelsea District - Certified PT Specialist',
   'Physiotherapy and rehabilitation suite combining manual therapy, movement screening and structured recovery programming.',
   'wellness', 'Physical Therapy & Rehab', 'New York', '245 W 17th St, New York, NY 10011', 4.92, 280, '+15550192803', true),
  ('apex-dental', 'Apex Dental Studio', 'Flatiron - Dr. Marcus Vance',
   'Preventative and cosmetic dentistry with same-week hygiene appointments and digital treatment planning.',
   'dental', 'Dentistry & Orthodontics', 'New York', '30 E 21st St, New York, NY 10010', 4.90, 198, '+15550192804', true)
on conflict (slug) do update set
  display_name    = excluded.display_name,
  headline        = excluded.headline,
  bio             = excluded.bio,
  rating          = excluded.rating,
  review_count    = excluded.review_count,
  whatsapp_number = excluded.whatsapp_number;

with p as (select id, slug from omnibook.providers)
insert into omnibook.services (provider_id, name, description, duration_minutes, price_cents, deposit_cents)
select p.id, s.name, s.description, s.duration_minutes, s.price_cents, s.deposit_cents
from p
join (values
  ('elena-vance', 'Consultation & Skin Health Exam', 'Comprehensive full-body dermoscopy, skin barrier assessment and personalised medical regimen formulation.', 30, 16000, 0),
  ('elena-vance', 'Advanced HydraFacial & Laser Tone', 'Vortex-fusion pore extraction paired with non-ablative Nd:YAG laser toning for hyperpigmentation.', 60, 24000, 5000),
  ('elena-vance', 'Pediatric & Teen Acne Management', 'Targeted hormonal and microbiological evaluation with structured follow-up.', 45, 19000, 0),
  ('elena-vance', 'Cosmetic Injectables Evaluation', '3D facial anatomy mapping, neuromodulator roadmap and safety assessment.', 45, 22000, 5000),
  ('maison-glow', 'Signature Balayage & Gloss', 'Hand-painted balayage with bespoke gloss finish by a master colourist.', 90, 14000, 4000),
  ('maison-glow', 'Precision Cut & Style', 'Consultation-led precision cut with blow-dry finish.', 60, 9500, 0),
  ('sterling-cole', 'Retainer Assessment', 'Initial corporate counsel consultation with encrypted NDA dispatched ahead of the meeting.', 45, 25000, 0),
  ('sterling-cole', 'Contract Review Session', 'Line-by-line commercial contract review with written summary.', 60, 32000, 10000),
  ('purezen-wellness', 'Initial Assessment', 'Movement screening, injury history intake and first treatment block.', 45, 12000, 0),
  ('purezen-wellness', 'Recovery & Manual Therapy', 'Targeted soft-tissue work and guided recovery protocol.', 60, 14000, 0),
  ('apex-dental', 'Preventative Hygiene & Polish', 'Full scale, polish and preventative assessment.', 45, 18000, 0)
) as s(slug, name, description, duration_minutes, price_cents, deposit_cents) on s.slug = p.slug
where not exists (
  select 1 from omnibook.services x where x.provider_id = p.id and x.name = s.name
);

-- Open slots for the next 14 days: weekday mornings and afternoons.
insert into omnibook.slots (provider_id, service_id, starts_at, ends_at)
select
  pr.id,
  (select s.id from omnibook.services s where s.provider_id = pr.id order by s.price_cents limit 1),
  slot_start,
  slot_start + interval '45 minutes'
from omnibook.providers pr
cross join lateral (
  select (date_trunc('day', now()) + (d || ' days')::interval + h)::timestamptz as slot_start
  from generate_series(0, 13) as d
  cross join unnest(array[
    interval '9 hours', interval '10 hours 30 minutes',
    interval '13 hours 30 minutes', interval '15 hours 30 minutes',
    interval '17 hours'
  ]) as h
) gen
where extract(isodow from slot_start) < 6 and slot_start > now()
on conflict (provider_id, starts_at) do nothing;

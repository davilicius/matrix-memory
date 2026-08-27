-- Sustituye este UUID solamente en una base local o proyecto educativo.
-- Debe corresponder a un usuario ficticio existente en auth.users.
\set synthetic_owner '00000000-0000-0000-0000-000000000001'

insert into public.profiles (id, display_name)
values (:'synthetic_owner'::uuid, 'Estudiante sintético')
on conflict (id) do nothing;

insert into public.life_periods (
  owner_id, name, description, starts_on, importance
)
select
  :'synthetic_owner'::uuid,
  'Etapa de aprendizaje',
  'Periodo completamente ficticio para estudiar memoria semántica.',
  current_date,
  70
where not exists (
  select 1
  from public.life_periods
  where owner_id = :'synthetic_owner'::uuid
    and name = 'Etapa de aprendizaje'
);

select public.matrix_remember(jsonb_build_object(
  'owner_id', :'synthetic_owner',
  'event_key', 'orion:project:initial-design',
  'memory_type', 'project',
  'title', 'Diseño inicial de Orion',
  'content', 'Orion es un invernadero escolar ficticio para estudiar memoria semántica.',
  'importance', 80,
  'confidence', 100,
  'truth_status', 'verified',
  'source', jsonb_build_object(
    'type', 'document',
    'title', 'Documento ficticio de arquitectura'
  ),
  'entities', jsonb_build_array(
    jsonb_build_object(
      'kind', 'project',
      'name', 'Orion',
      'role', 'subject',
      'weight', 1.0
    )
  )
));

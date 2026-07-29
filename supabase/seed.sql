-- Sustituye este UUID solamente en una base local o proyecto de prueba.
-- Debe corresponder a un usuario existente en auth.users.
\set synthetic_owner '00000000-0000-0000-0000-000000000001'

insert into public.profiles (id, display_name)
values (:'synthetic_owner'::uuid, 'Usuario sintético')
on conflict (id) do nothing;

insert into public.life_periods (
  owner_id, name, description, starts_on, importance
) values (
  :'synthetic_owner'::uuid,
  'Etapa de aprendizaje',
  'Periodo completamente ficticio para pruebas.',
  current_date,
  70
);

select public.matrix_remember(jsonb_build_object(
  'owner_id', :'synthetic_owner',
  'event_key', 'atlas:project:initial-design',
  'memory_type', 'project',
  'title', 'Diseño inicial de Atlas',
  'content', 'Atlas es un proyecto ficticio para estudiar recuperación semántica.',
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
      'name', 'Atlas',
      'role', 'subject',
      'weight', 1.0
    )
  )
));

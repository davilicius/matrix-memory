-- Laboratorio Matrix 1.2
-- Ejecuta este archivo como un usuario autenticado de un proyecto de prueba.

-- 1. Descubrir el contrato.
select public.matrix_schema_info();

-- 2. Crear un proyecto sintético.
select public.matrix_remember(jsonb_build_object(
  'event_key', 'orion:project:initial-design',
  'memory_type', 'project',
  'title', 'Diseño inicial de Orion',
  'content', 'Orion es un invernadero escolar ficticio que registra temperatura y humedad.',
  'summary', 'Proyecto educativo de monitoreo ambiental.',
  'importance', 80,
  'confidence', 100,
  'truth_status', 'verified',
  'source', jsonb_build_object(
    'type', 'document',
    'title', 'Arquitectura ficticia de Orion'
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

-- 3. Repetir exactamente la misma escritura.
-- Debe responder "existing" sin crear otra fuente ni otro nodo.
select public.matrix_remember(jsonb_build_object(
  'event_key', 'orion:project:initial-design',
  'memory_type', 'project',
  'title', 'Diseño inicial de Orion',
  'content', 'Orion es un invernadero escolar ficticio que registra temperatura y humedad.',
  'source', jsonb_build_object(
    'type', 'document',
    'title', 'Esta fuente no debe duplicarse'
  )
));

-- 4. Crear una decisión vinculada.
select public.matrix_remember(jsonb_build_object(
  'event_key', 'orion:decision:automatic-irrigation',
  'memory_type', 'decision',
  'title', 'Automatizar el riego',
  'content', 'Orion activará el riego cuando la humedad permanezca por debajo del umbral.',
  'truth_status', 'verified',
  'source', jsonb_build_object(
    'type', 'conversation',
    'title', 'Reunión ficticia del equipo Orion'
  ),
  'relations', jsonb_build_array(
    jsonb_build_object(
      'target_event_key', 'orion:project:initial-design',
      'type', 'part_of',
      'weight', 1.0,
      'confidence', 100
    )
  )
));

-- 5. Recuperación textual rastreada.
select public.matrix_recall(jsonb_build_object(
  'query', 'riego automático',
  'limit', 5,
  'hops', 1,
  'channel', 'laboratorio'
));

-- 6. Recuperación semántica asíncrona.
-- Repite la llamada después de aproximadamente un segundo si devuelve pending.
select public.matrix_semantic_recall(jsonb_build_object(
  'query', 'sistema que cuida plantas sin intervención',
  'limit', 5,
  'hops', 1,
  'channel', 'laboratorio'
));

-- 7. Inspeccionar trazabilidad y estado de embeddings.
select query_text, result_node_ids, metadata, created_at
from public.retrieval_history
order by created_at desc
limit 5;

select event_key, embedding_status, recall_count, last_recalled_at
from public.memory_nodes
where event_key like 'orion:%'
order by event_key;

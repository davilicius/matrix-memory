# Arquitectura

Matrix separa la información en seis responsabilidades:

| Componente | Responsabilidad |
| --- | --- |
| `memory_nodes` | Recuerdos atómicos y recuperables |
| `sources` | Procedencia y evidencia original |
| `entities` | Conceptos y sujetos reutilizables |
| `memory_entities` | Participación de entidades en cada recuerdo |
| `memory_edges` | Relaciones entre recuerdos |
| `memory_versions` | Estado anterior de recuerdos modificados |

## Escritura

`matrix_remember(jsonb)` es la frontera estable de escritura. Valida la identidad, deduplica por `event_key`, crea la fuente, inserta el nodo, reutiliza entidades y conecta relaciones.

La combinación `(owner_id, event_key)` es única. Repetir un evento devuelve `status: existing` sin crear efectos secundarios.

## Aislamiento

Todas las filas tienen un propietario. Las políticas RLS comparan `owner_id` con `auth.uid()`. Los vínculos del grafo incluyen validaciones adicionales para impedir conexiones entre propietarios distintos.

## Actualizaciones

Antes de modificar campos sustantivos de un nodo, un trigger guarda una instantánea sin el vector ni el índice de texto. Así se conserva la evolución sin duplicar los campos derivados.

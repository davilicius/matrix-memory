# Modelo de memoria

## Recuerdo atómico

Un nodo debe expresar una sola idea recuperable. Decisiones independientes o acontecimientos distintos utilizan nodos separados aunque provengan de la misma conversación.

Campos esenciales:

| Campo | Significado |
| --- | --- |
| `event_key` | Identidad estable e idempotente del acontecimiento |
| `memory_type` | Naturaleza de la información |
| `title` | Nombre breve y recuperable |
| `content` | Contenido completo de la idea |
| `source_id` | Procedencia del recuerdo |

## Tipos

- `episode`: evento o experiencia.
- `fact`: afirmación relativamente estable.
- `decision`: curso de acción elegido.
- `intention`: compromiso o plan futuro.
- `project`: panorama durable de un proyecto.
- `reflection`: interpretación o aprendizaje.
- `preference`: elección recurrente.
- `procedure`: método repetible.
- `identity`: hecho durable sobre una identidad.
- `hypothesis`: posibilidad todavía no verificada.

## Estado epistémico

`truth_status` puede ser `reported`, `verified`, `inferred`, `disputed` o `unknown`. No debe confundirse confianza con verdad: una memoria puede tener alta confianza y continuar siendo un reporte.

## Tiempo

- `occurred_at` y `ended_at`: cuándo ocurrió un episodio.
- `valid_from` y `valid_to`: periodo de validez de una afirmación.
- `life_period_id`: etapa vital, académica o profesional.

## Recuperación

- `importance`: relevancia durable.
- `emotional_intensity`: saliencia emocional.
- `confidence`: confianza en el registro.
- `fts`: índice de texto completo en español.
- `embedding`: vector semántico de 384 dimensiones.
- `recall_count`: número de recuperaciones directas.
- `last_recalled_at`: última recuperación directa.

## Estado del embedding

| Estado | Interpretación |
| --- | --- |
| `pending` | El contenido requiere vector nuevo |
| `processing` | Un worker está generando el vector |
| `ready` | El vector corresponde al hash vigente |
| `error` | El último intento falló y puede reintentarse |

## Relaciones

Las relaciones pueden expresar causalidad, orden temporal, pertenencia, contradicción, sustitución o soporte. Su peso controla cuánto se activa un recuerdo vecino durante la expansión asociativa.

## Procedencia

Cada escritura requiere una fuente nueva o un `source_id` existente. La procedencia permite responder no sólo “qué recuerda el sistema”, sino también “de dónde provino”.

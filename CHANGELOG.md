# Cambios

## 1.2.0 - 2026-08-27

- Se documentó el contrato canónico `matrix_remember(jsonb)` y `matrix_recall(jsonb)`.
- Se añadió generación asíncrona de embeddings con `pgmq`, `pg_net`, `pg_cron` y Edge Functions.
- Se incorporó `matrix_semantic_recall(jsonb)` con caché de consultas por 24 horas.
- Se añadió `retrieval_history` para registrar recuperaciones y actualizar contadores.
- Se separó el trigger genérico `set_updated_at()` del trigger específico de memorias.
- Se reforzó la reutilización de entidades y la validación de propietario.
- Se agregaron una guía de estudio, laboratorios sintéticos y documentación de seguridad.
- Se incluyeron cuatro Edge Functions con dependencias fijadas.

## 1.1.0

- Modelo inicial de memorias, fuentes, entidades, relaciones y versiones.
- Escritura idempotente con `event_key`.
- Búsqueda de texto completo y vectorial.
- Aislamiento por propietario mediante RLS.

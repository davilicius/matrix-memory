# Cambios

## MCP 1.3.0 - 2026-11-12

- Añade `supersede` y la RPC `matrix_supersede(jsonb)` para sustituciones completas o parciales en una transacción.
- Conserva contenidos históricos; incluye reintentos exactos, conflictos concurrentes, RLS y pruebas de reversión ante fallos.
- Mantiene los contratos anteriores y el despliegue manual.


## Sincronización de producción y MCP 1.1.1 — 2026-11-12

- Incorporado el MCP OAuth desplegado (base 1.1.0), con propietario y conexiones configurables en lugar de identificadores personales.
- Se conserva la identidad única validada por Auth, RLS, seis herramientas y rechazos de sesiones sin OAuth.
- Historial raíz alineado con las 16 versiones de producción; el historial educativo anterior se conserva íntegro en `profiles/study/`.
- Seed automático desactivado y requisitos previos al despliegue documentados.
- Pruebas de autenticación, contrato MCP y correspondencia del historial; la regresión SQL educativa conserva su alcance.
- Sin despliegue ni cambios al historial, secretos o configuración del proyecto alojado.

## Correcciones de compatibilidad - 2026-10-21

- GRANT explícitos mínimos para las RPC de servidor sin depender de defaults de Supabase.
- `matrix_recall` recupera resultados y asociaciones para el owner_id validado también sin JWT de usuario en llamadas de servidor.
- Operador de pgvector calificado para instalaciones nuevas y actualización de funciones existentes.
- RLS, firmas públicas, SECURITY INVOKER y restricciones de anon conservados.
- Regresión de permisos, aislamiento, recuperación textual/vectorial, actualización y reset en GitHub Actions.

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

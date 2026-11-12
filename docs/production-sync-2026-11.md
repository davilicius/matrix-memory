# Sincronización del código de producción — 12 noviembre 2026

El repositorio incorpora el MCP desplegado el 30 de octubre y los identificadores reales de las 16 migraciones aplicadas. Esta actualización de GitHub no despliega cambios ni modifica el historial de la base de datos.

## Dos historiales con destinos diferentes

| Ruta | Uso |
| --- | --- |
| `supabase/migrations/` | Historial de la instalación existente, con versiones y nombres extraídos de `supabase_migrations.schema_migrations`. |
| `profiles/study/supabase/migrations/` | Las cuatro migraciones educativas anteriores, conservadas sin cambios de contenido para instalaciones de laboratorio y su regresión de permisos. |

No mezclar ambos historiales ni ejecutar el perfil educativo contra producción. Los antiguos identificadores `0001`, `0002`, `20261021211445` y `20261021212808` no son las versiones registradas en producción. Las dos correcciones de octubre constan allí como `20261021215121` y `20261021215133`.

Los SQL históricos incluyen operaciones puntuales de cola, cron y comprobaciones de la definición anterior de funciones. Son historia aplicada, no scripts idempotentes para volver a ejecutar ni una instalación portátil. El perfil educativo sigue siendo el punto de partida para un proyecto nuevo. La única sanitización de los SQL históricos sustituye la URL real del proyecto por `current_setting('matrix.project_url')` en la activación del worker; una reproducción aislada de ese historial debe configurar ese parámetro antes. Nunca se exportaron valores de Vault, usuarios ni recuerdos.

## MCP

`supabase/functions/matrix-mcp/` contiene el servidor, acceso a PostgreSQL y verificador OAuth. Conserva las seis operaciones y el aislamiento por propietario del despliegue observado, versión de aplicación 1.1.0 / revisión de despliegue 5. La adaptación portátil se identifica como **MCP 1.1.1**; el contrato de datos sigue en **1.2**. Las cuatro Edge Functions anteriores conservan su código del repositorio; en la revisión no se detectaron diferencias funcionales frente a producción.

Se eliminaron el UUID del propietario, la URL del proyecto y los textos personales del código publicado. `MATRIX_OWNER_ID` es obligatorio y se comparte entre la autenticación y las consultas; el propietario jamás se toma de argumentos enviados por un cliente. La URL de descubrimiento OAuth se deriva del proyecto configurado. Sin configuración completa, el servidor falla al arrancar.

La pantalla de consentimiento OAuth y los ajustes de Auth alojados fuera de estas Edge Functions no se exportan mediante esta sincronización. Deben conservarse o configurarse en Supabase Auth al reproducir la instalación.

## Antes de habilitar GitHub → producción

1. Comparar el historial remoto con `supabase/production-history.json`: deben coincidir las 16 versiones; no marcar migraciones como aplicadas sin comprobarlas ni ejecutar SQL antiguo para corregir nombres.
2. Configurar `MATRIX_OWNER_ID` con el UUID del usuario autorizado y mantener `SUPABASE_DB_URL` en los secretos de Edge Functions. `SUPABASE_URL` y `SUPABASE_ANON_KEY` los proporciona el entorno de Supabase. No se modificaron secretos en esta actualización.
3. Mantener el proveedor OAuth, cliente y consentimiento de la instalación existente. El verificador rechaza sesiones sin `client_id`, usuarios distintos, sesiones inválidas y cuentas anónimas.
4. Revisar el diff de despliegue y ejecutar los controles del repositorio. La integración permanece pendiente de habilitación independiente; no queda activada por publicar este commit.

El perfil raíz desactiva el seed para que los ejemplos sintéticos no se apliquen en producción. El `project_id` de config.toml es un nombre local, no una credencial ni la vinculación a un proyecto alojado.

## Validación

`tests/mcp_test.ts` prueba autenticación OAuth, propietario, configuración obligatoria, entradas de herramientas y límites HTTP con datos sintéticos y backend simulado. `tests/run-permissions.sh` mantiene la regresión SQL del perfil educativo (instalación, permisos, RLS, reset y reaplicación). `tests/check-production-history.py` comprueba integridad de los archivos históricos respecto al manifiesto exportado. Ninguna de esas pruebas escribe en producción.

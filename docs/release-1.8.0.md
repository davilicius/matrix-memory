# Cierre de etapa — MCP 1.8.0

La etapa actual de mejoras en español fue aceptada el 13 de noviembre de 2026 UTC. El cierre no exige otra prueba de aceptación y no equivale a una garantía universal de recuperación. MCP queda en **1.8.0** y el contrato de memoria en **1.2**.

## Alcance implementado

| Bloque | Resultado | Evidencia de código |
| --- | --- | --- |
| Vigencia y estado actual | Fechas, reemplazos, contradicciones y consulta `resolve_current`; complemento de contexto reciente por proyecto | [PR 3](https://github.com/davilicius/matrix-memory/pull/3), [PR 9](https://github.com/davilicius/matrix-memory/pull/9) |
| Sustitución de recuerdos | Operación atómica completa/parcial, reintentos y conflictos; preservación histórica | [PR 4](https://github.com/davilicius/matrix-memory/pull/4) |
| Diagnóstico | Telemetría por operación y compatibilidad de protocolo MCP | [PR 5](https://github.com/davilicius/matrix-memory/pull/5), [PR 6](https://github.com/davilicius/matrix-memory/pull/6) |
| Permisos por aplicación | Perfiles reader, writer y manager, autorización y revocación por solicitud | [PR 7](https://github.com/davilicius/matrix-memory/pull/7) |
| Recuperación en español | Contexto reciente y candidatos ortográficos conservadores, separados de los resultados habituales | [PR 9](https://github.com/davilicius/matrix-memory/pull/9), [PR 10](https://github.com/davilicius/matrix-memory/pull/10) |

La tolerancia ortográfica utiliza `pg_trgm` existente y distancia de edición en TypeScript. No incorpora modelos, servicios, infraestructura ni migraciones nuevas. Admite una palabra con errata en consultas admitidas; revisa títulos y los primeros 1,000 caracteres de resumen dentro de límites explícitos. Consulte [el contrato y sus límites](spanish-spelling.md).

La [fusión RRF ponderada](retrieval-flow.md) ya existía. La ortografía no se añade como tercera lista a esa fusión. HNSW también existía, pero el plan de ranking examinado no lo utilizaba; no se cambió su configuración.

## Verificación de la versión

La implementación se integró mediante PR 10 en `c4870f7d26fdd1d5a23f25b012cd129d1633d492`. En ese commit de `main` finalizaron correctamente:

- [MCP, comprobación de tipos e historial de migraciones — ejecución 43370949464](https://github.com/davilicius/matrix-memory/actions/runs/43370949464): 55 pruebas sintéticas, type-check y preservación de las 16 migraciones importadas.
- [Permisos PostgreSQL — ejecución 43370949397](https://github.com/davilicius/matrix-memory/actions/runs/43370949397): modos strict y legacy, aislamiento, operaciones y regresión SQL del suplemento ortográfico.

La regresión de ortografía ejecuta el SELECT real de la aplicación sobre datos sintéticos en una base desechable. Comprueba propietario/RLS, estado y vigencia, tipos y filtros de fecha. La primera ejecución en la rama detectó una clave obligatoria ausente en los fixtures; se corrigió antes de integrar y desplegar. No se omitieron los controles.

La verificación operativa adicional comprobó versión 1.8.0, coincidencia de los 13 archivos desplegados con el paquete probado, recuperación por erratas desde `search` y `resolve_current`, consulta exacta, control negativo y omisión de correcciones para identificadores. Los datos privados y los identificadores de recuerdos no se publican en el repositorio.

La comparación antes/después conservó exactamente los IDs y el orden en 7 de 8 consultas. En la consulta protegida restante cambió sólo el sexto resultado; una llamada directa al buscador original, sin suplemento ortográfico, reprodujo los seis resultados posteriores. No se estableció una causa interna concreta. Esto no se presenta como una comparación 8/8 idéntica ni como una mejora universal de precisión.

## Límites y trabajo diferido

- E5 y consultas entre idiomas quedan para otra ampliación; la evaluación experimental de PR 8 no fue desplegada.
- La recuperación de erratas sólo presentes en el cuerpo de notas largas no está garantizada por esta versión.
- La mejora de resúmenes, fechas conocidas y relaciones históricas puede abordarse en otra etapa, sin inventar datos.
- Las cuatro propuestas históricas de filtros, ranking, contenido y claves se retiraron de las prioridades activas y se conservaron como [casos de estudio](study-cases-retrieval.md); no son pendientes de este cierre.
- Los límites de conjuntos de candidatos y las coincidencias aproximadas no garantizan un inventario exhaustivo ni certifican vigencia.

No se añadió un despliegue automático. La documentación de cierre no exige otro despliegue. La reversión técnica del suplemento consiste en restaurar el paquete completo anterior; no necesita deshacer una migración de base de datos.

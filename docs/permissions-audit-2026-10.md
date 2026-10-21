# Auditoría de permisos: 30 de octubre de 2026

Base: `1a6c1a9defd0bfbd00df98e6a8ae6bbeb56e1e23`. Alcance: repositorio
educativo. No se inspeccionaron secretos, roles efectivos ni ACL de producción.

## Resultado

`0002` concede explícitamente los permisos necesarios a `authenticated`.
`anon` no es consumidor de Matrix y no necesita permisos.

Hay una incompatibilidad en las RPC de servidor: `0002` autoriza a
`service_role` a ejecutar `matrix_remember` y `matrix_recall`, y sus cuerpos
admiten ese rol con `owner_id` explícito. Al ser SECURITY INVOKER, necesitan
también permisos de tablas. Sin defaults, `matrix_remember` falla con 42501,
`permission denied for table memory_nodes`. BYPASSRLS no sustituye un GRANT.

La nueva migración añade siete GRANT específicos. No modifica RLS, políticas,
SECURITY, otros roles ni defaults. No concede DELETE, TRUNCATE, acceso a
Vault, colas o permisos sobre todo un esquema.

La instalación limpia reveló otro fallo previo: `recall_memories` usa `<=>`
con `search_path = ''`. Se corrigen las dos definiciones históricas con
`operator(extensions.<=>)`, conservando el search_path vacío y el algoritmo.
Las correcciones históricas permiten reproducir una instalación desde cero.
La migración adicional `20261021212808_server_recall_owner_scope.sql`
reemplaza también la definición efectiva de `recall_memories`, por lo que
la corrección del operador alcanza instalaciones que ya aplicaron 0001/0002.

## Consumidores y roles comprobados en código

| Consumidor | Conexión | Rol y conclusión |
| --- | --- | --- |
| memory-write | supabase-js, ANON_KEY y Authorization del usuario; valida getUser() | authenticated; llama matrix_remember |
| memory-recall | Mismo patrón, calcula embedding en Edge | authenticated; llama matrix_recall |
| RPC de servidor | Contrato SQL explícito; las Edge Functions no usan cliente service-role | service_role admitido, faltaban permisos de tablas |
| Dos workers | postgres@3.4.7 y SUPABASE_DB_URL | Login configurado fuera de Git; no se puede deducir del nombre de variable |
| Despachadores/cron | private.process_matrix_*, SECURITY DEFINER | Propietario de función; sin EXECUTE para usuarios normales |

Los workers leen `vault.decrypted_secrets`, seleccionan/actualizan
`memory_nodes` o `matrix_recall_requests` y reconocen trabajos con
`pgmq.delete`. Su login necesita esos permisos y los requeridos por la
implementación de pgmq. No llaman Data API ni usan una clave service-role.
Un propietario/BYPASSRLS es privilegiado; un login dedicado necesita políticas
o una vía controlada para procesar trabajos de varios usuarios. No se cambia
ese diseño ni se asume que el login desplegado sea postgres.

## Matriz por tabla

S = SELECT; I = INSERT; U = UPDATE; D = DELETE. `anon` no requiere acceso
a ninguna tabla. La columna de servidor cubre RPC, no administración general.

| Tabla | authenticated (0002, RLS) | service_role (nuevo, RPC) | Worker directo |
| --- | --- | --- | --- |
| profiles | S,U | ninguno | ninguno |
| life_periods | S,I,U,D | S | ninguno |
| entities | S,I,U,D | S,I,U | ninguno |
| sources | S,I,U,D | S,I | ninguno |
| memory_nodes | S,I,U,D | S,I,U | S,U |
| memory_edges | S,I,U,D | S,I,U | ninguno |
| memory_entities | S,I,U,D | S,I,U | ninguno |
| memory_versions | S | ninguno | indirecto por trigger |
| retrieval_history | S,I,U,D | S,I | ninguno |
| matrix_recall_requests | S,I,U,D | ninguno | S,U |

SELECT cubre filtros, validaciones, RETURNING y lecturas idempotentes;
UPDATE en entidades/enlaces cubre ON CONFLICT DO UPDATE. Los IDs públicos
son UUID: no requieren permisos de secuencias. Los triggers de versionado
y cola usan el propietario; no se concede acceso directo a sus tablas internas.

El parche es aditivo: **conserva ACL amplias heredadas**. No afirma quitar
TRUNCATE u otros privilegios anteriores. Reducirlos requiere inventariar
primero los consumidores externos.

## RPC y límites existentes

| Función | Rol previsto | Control |
| --- | --- | --- |
| matrix_remember(jsonb) | authenticated, service_role | invoker; valida propietario y procedencia |
| matrix_recall(jsonb) | authenticated, service_role | invoker; historial y contadores |
| matrix_semantic_recall(jsonb) | authenticated | auth.uid(), caché y helper privado |
| matrix_schema_info() | authenticated, service_role | invoker; no lee datos personales |
| recall_memories / memory_context | authenticated, service_role | invoker; filtran por auth.uid() |
| private.enqueue_matrix_query_request(uuid) | authenticated, llamada interna | definer; comprueba identidad y propiedad |
| Otros helpers privados/trigger | propietario | EXECUTE revocado a PUBLIC/anon/authenticated |

`private` debe quedar fuera de esquemas expuestos por PostgREST.
`authenticated` sí tiene USAGE y EXECUTE en el helper de encolado: permite
la llamada interna, no una API pública del esquema.

La segunda migración corrige además los cero resultados de `matrix_recall`
con service_role sin JWT de usuario. Conserva la validación inicial: el
usuario autenticado sólo puede pedir su propietario; un rol de servidor
admitido debe indicar owner_id. Búsqueda textual/vectorial, grafo, contadores
e historial usan ese mismo propietario validado.

La consulta se ejecuta dentro de la RPC para conservar las firmas públicas
y no ampliar permisos del esquema private. No se fabrican JWT ni se cambia
el estado de sesión. El algoritmo de ranking conserva sus pesos y filtros;
los helpers públicos antiguos continúan restringidos a auth.uid(). Los
clientes deben usar el JWT del usuario; service_role queda sólo en servidores.

Para futuras funciones privadas se requieren REVOKE explícitos: el REVOKE
de defaults limitado a private no elimina el EXECUTE global de PUBLIC.
Las funciones actuales están protegidas por los REVOKE explícitos de 0002.

## Pruebas

Con Docker y Supabase CLI 2.121.0:

```bash
bash tests/run-permissions.sh strict
bash tests/run-permissions.sh legacy
```

El workflow `Matrix SQL permissions` usa contenedores desechables, sin
credenciales de Supabase. Strict revoca defaults antes de crear tablas
(incluso más restrictivo que el anuncio); legacy reproduce los anteriores.
Comprueba ambos errores previos, actualización, instalación/reset, reaplicación,
ACL, RLS en diez tablas, aislamiento de dos usuarios, rechazo de cambio de
propietario, escritura/recuperación, caché semántica, triggers, colas y SQL
de workers. Incluye recuperación de servidor sin JWT, propietarios alternados,
rechazo de propietario ausente o suplantado, búsqueda vectorial con embeddings
idénticos de varios usuarios, el contrato pgTAP y Security Advisor local.

No valida HTTP PostgREST/Edge, gte-small ni secretos/conexiones reales.
El despliegue y la comprobación del login de workers requieren autorización
separada. La configuración desplegada no se puede certificar sólo con Git.

## Fuentes

- [Anuncio oficial](https://supabase.com/changelog/45329-breaking-change-tables-not-exposed-to-data-and-graphql-api-automatically)
- [Grants, RLS y defaults](https://supabase.com/docs/guides/api/securing-your-api)
- Migraciones 0001/0002 y las cuatro Edge Functions del repositorio.

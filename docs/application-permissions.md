# Permisos por aplicación — MCP 1.6.0

Cada cliente OAuth tiene un perfil administrativo independiente, asociado al
propietario y al `client_id` verificado. No se confía en nombres de aplicación,
metadatos de usuario, cuerpos de herramientas ni permisos declarados por el cliente.

| Perfil | Consultar y estado | Guardar | Sustituir |
| --- | --- | --- | --- |
| `reader` | Sí (6 herramientas) | No | No |
| `writer` | Sí | Sí | No |
| `manager` | Sí | Sí | Sí |
| Sin registro o deshabilitado | No | No | No |

“Consultar” conserva la actualización habitual de historial y contadores de
recuperación. Estos perfiles no segmentan recuerdos por tema o proyecto. Un lector
puede consultar toda la memoria del propietario servido por esta instalación.
Los permisos por herramienta tampoco sustituyen la autorización del usuario para
realizar una tarea. No se añade borrado, SQL libre ni administración desde MCP.

## Comprobación por solicitud

1. Supabase Auth verifica el token; se exige propietario, emisor, audiencia,
   expiración y contexto OAuth.
2. El servidor consulta `matrix_private.application_role` con la identidad
   verificada. Comprueba el permiso administrativo, cliente no eliminado,
   sesión correspondiente no vencida y consentimiento no revocado.
3. Publica solo las herramientas permitidas, aplica la misma comprobación antes
   de ejecutar llamadas y devuelve los permisos efectivos en `status`.
4. Un `writer` tampoco puede crear relaciones `supersedes` mediante `remember`.
   Un lote legacy con cualquier operación prohibida se rechaza íntegramente antes
   de ejecutar su primera operación.

No se cachean permisos entre solicitudes. Los cambios de perfil o revocaciones
rigen para la siguiente solicitud; una operación ya autorizada puede terminar.
Un fallo al consultar permisos devuelve 503 `APP_AUTH_UNAVAILABLE`; un cliente sin
permiso devuelve 403 `APP_NOT_ALLOWED`; una operación prohibida devuelve 403
`PERMISSION_DENIED`. Los logs solo añaden `application_role` enumerado, no IDs de
cliente/sesión, tokens ni etiquetas privadas.

## Protección de base de datos

`matrix_private.application_grants` tiene RLS, sin permisos para anon,
authenticated o service_role. Solo la conexión administrativa del servidor puede
consultar el autorizador (SECURITY INVOKER) y administrar registros. Los clientes
OAuth no pueden concederse perfiles.

Once tablas públicas de Matrix reciben una política **restrictiva** adicional:
los JWT con `client_id` no acceden directamente a sus filas. Esto evita que una
aplicación ignore su perfil e invoque REST/RPC fuera de MCP. El conector ya usa una
transacción interna con rol authenticated e identidad del propietario, después
de validar OAuth y permisos. Las políticas de propiedad siguen activas.
Las sesiones directas del propietario sin `client_id` y los procesos confiables
con credenciales de servidor conservan su contrato; no son aplicaciones OAuth.

## Alta, cambio y revocación

Inspeccionar primero el registro OAuth, sesión y consentimiento del propietario.
No autorizar por `client_name`: es un nombre declarado, no una identidad segura.
Asignar el UUID comprobado y un perfil explícito desde mantenimiento administrativo:

```sql
-- Parámetros enlazados; no publicar IDs privados en el repositorio.
insert into matrix_private.application_grants(owner_id,client_id,app_role)
values ($1::uuid,$2::uuid,$3)
on conflict(owner_id,client_id) do update
set app_role=excluded.app_role,enabled=true;
-- Revocar la siguiente solicitud sin esperar a que caduque su JWT:
update matrix_private.application_grants set enabled=false
where owner_id=$1::uuid and client_id=$2::uuid;
```

Una nueva conexión o registro dinámico que cambie de client_id requiere revisar
su identidad y asignar permiso otra vez. Las skills que comparten un mismo cliente
OAuth comparten perfil; diferenciarlas requiere clientes OAuth independientes.
La migración no concede permisos automáticamente ni contiene IDs de producción.

## Despliegue manual y validación

Aplicar las migraciones, registrar el cliente actual revisado con sus capacidades
existentes y desplegar MCP 1.6.0. Conservar el binding privado del propietario
del paquete desplegado; comprobar MATRIX_OWNER_ID antes de activar el endpoint. Verificar `status`, búsqueda y guardado desde el
cliente conectado. El despliegue automático continúa desactivado.

Pruebas Deno cubren ambos protocolos, tres perfiles, denegación predeterminada,
revocación, concurrencia, suplantación por cuerpo, lotes y guardado con sustitución
encubierta. Las pruebas SQL transaccionales verifican el autorizador real, sesión,
consentimiento, revocación, aislamiento y ausencia de bypass REST/RPC, sin residuos.
Se ejecutan en CI con permisos predeterminados estrictos y heredados.

Para revertir una incidencia, conservar el paquete anterior y evaluar sus permisos:
volver a MCP 1.5.0 elimina la restricción por aplicación en el conector. No hacerlo
como solución permanente. Las políticas restrictivas añadidas son independientes
y pueden conservarse durante esa reversión. No se borran recuerdos ni perfiles.

Referencia: [Supabase OAuth token security](https://supabase.com/docs/guides/auth/oauth-server/token-security).

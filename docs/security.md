# Seguridad y privacidad

Matrix puede almacenar información sensible. Este repositorio es educativo y debe probarse únicamente con datos ficticios.

## Fronteras de confianza

| Capa | Protección |
| --- | --- |
| Cliente | JWT de un usuario autenticado |
| Tablas públicas | RLS por `owner_id = auth.uid()` |
| RPC de usuario | `security invoker` y validación del propietario |
| Esquema `private` | Sin acceso directo para `anon` o `authenticated` |
| Workers | Secreto dedicado y comparación constante |
| Git | Sólo configuración de ejemplo y datos sintéticos |

## Reglas obligatorias

- Nunca publiques `service_role`, claves secretas, contraseñas o URLs con tokens.
- No uses `user_metadata` para autorizar filas.
- No desactives RLS para corregir un problema de permisos.
- No conviertas un RPC en `security definer` sin una necesidad documentada.
- Cuando una función privilegiada sea necesaria, colócala en `private`, fija `search_path` y revoca su ejecución pública.
- Los workers con `verify_jwt = false` deben validar otro mecanismo de autenticación antes de leer datos.
- Mantén fijadas las versiones de dependencias.
- Revisa Security Advisor después de desplegar migraciones.

## Datos que no deben almacenarse

- Contraseñas, tokens, claves privadas o códigos de recuperación.
- Números completos de tarjetas bancarias.
- Secretos operativos copiados desde archivos `.env`.
- Datos personales sin una finalidad y autorización claras.

## Publicación del repositorio

Antes de cambiar la visibilidad a pública:

1. busca UUID, correos, teléfonos, dominios privados y claves;
2. revisa todo el historial de Git, no sólo el último commit;
3. confirma que `.env` y `.supabase/` continúan ignorados;
4. usa únicamente identidades, recuerdos y proyectos ficticios;
5. ejecuta los tests y los asesores de seguridad.

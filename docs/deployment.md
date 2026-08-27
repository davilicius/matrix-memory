# Despliegue educativo

Usa un proyecto de Supabase destinado exclusivamente al laboratorio. La instalación tiene dos niveles: contrato de datos y embeddings automáticos.

## 1. Preparar el proyecto

```bash
supabase login
supabase link --project-ref TU_PROJECT_REF
supabase db push
```

Crea un usuario de prueba mediante Supabase Auth. Sustituye el UUID de `supabase/seed.sql` únicamente por el UUID de ese usuario ficticio y ejecuta el seed.

## 2. Desplegar API autenticada

```bash
supabase functions deploy memory-write
supabase functions deploy memory-recall
```

Estas funciones requieren un JWT válido. No desactives `verify_jwt`.

## 3. Desplegar workers

```bash
supabase functions deploy matrix-embedding-worker
supabase functions deploy matrix-query-embedding-worker
```

Los workers reciben llamadas internas de `pg_net`. Por ello usan `verify_jwt = false`, pero rechazan toda petición que no incluya el secreto configurado en `x-matrix-worker-secret`.

Configura `SUPABASE_DB_URL` como secreto de las Edge Functions. No lo agregues a `.env.example`, commits, capturas o documentación pública.

## 4. Activar Vault y cron

Abre `supabase/snippets/activate-workers.sql`, sustituye únicamente los marcadores y ejecútalo manualmente en SQL Editor.

Necesitas:

- la URL pública del proyecto;
- un secreto aleatorio largo exclusivo para los workers.

El valor guardado en Vault y el valor enviado por `pg_net` son el mismo. Nunca publiques ese secreto.

## 5. Verificar

```sql
select public.matrix_schema_info();

select embedding_status, count(*)
from public.memory_nodes
group by embedding_status
order by embedding_status;

select jobname, schedule, active
from cron.job
where jobname like 'matrix-%';
```

Después llama dos veces `matrix_semantic_recall` con la misma consulta. La primera respuesta puede ser `pending`; cuando el worker termine, la siguiente debe ser `ready`.

## 6. Revisar seguridad

Ejecuta Security Advisor desde Supabase. Confirma además:

- RLS activo en todas las tablas públicas;
- ningún secreto en Git;
- funciones públicas sin `security definer`;
- funciones privilegiadas aisladas en `private`;
- workers inaccesibles sin el secreto correcto.

## Desactivación

Antes de modificar workers o secretos, desactiva ambos crones:

```sql
select cron.unschedule(jobid)
from cron.job
where jobname in (
  'matrix-process-embeddings',
  'matrix-process-query-embeddings'
);
```

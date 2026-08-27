# Roadmap de recuperación semántica

Este roadmap reúne mejoras detectadas al auditar búsquedas semánticas reales contra el contrato Matrix 1.2. Los ejemplos y criterios están sanitizados: no contienen recuerdos, identidades ni identificadores de una instalación privada.

## Línea base confirmada

Antes de ampliar el contrato, la implementación ya conserva estas garantías:

- Escritura atómica e idempotente mediante `matrix_remember(jsonb)`.
- Aislamiento por propietario con autenticación y Row Level Security.
- Embeddings de 384 dimensiones generados de forma asíncrona.
- Caché de embeddings de consulta durante 24 horas.
- Recuperación híbrida de texto completo, similitud vectorial y señales de calidad.
- Registro de cada recuperación lista en `retrieval_history`.
- Incremento de contadores únicamente para resultados directos; las asociaciones no cuentan como recuperaciones directas.
- Expansión limitada de asociaciones para aportar contexto sin recorrer el grafo sin control.

## Hallazgo principal

Las consultas específicas recuperan correctamente memorias atómicas. En cambio, una consulta genérica con exclusiones escritas en lenguaje natural puede mezclar dominios: términos como nombres de proyectos o tecnologías terminan convertidos en señales positivas por la búsqueda de texto completo, aunque la intención de la frase sea excluirlos.

El problema no está en la generación del embedding ni en la atomicidad de escritura. Está en el contrato de recuperación: hoy no expresa de forma estructurada el dominio deseado ni las exclusiones.

## Mejoras previstas

### P0 — Alcance y exclusiones estructuradas

- Añadir filtros explícitos de alcance o dominio, por ejemplo `personal`, `profesional` y `tecnico`.
- Añadir exclusiones estructuradas por dominio, entidad o etiqueta.
- Compilar las exclusiones léxicas de forma segura en vez de insertar palabras como términos positivos.
- Aplicar los filtros dentro del RPC, siempre bajo las políticas RLS del propietario.
- Definir compatibilidad hacia atrás para clientes que no envíen los campos nuevos.

### P1 — Ranking consciente del dominio

- Reequilibrar importancia, confianza e intensidad emocional cuando el dominio solicitado no coincide con el recuerdo.
- Evitar que memorias técnicas de alta importancia desplacen resultados personales pertinentes en consultas amplias.
- Sustituir el bono por coincidencia del texto completo de la consulta en el título por señales útiles: coincidencia de términos normalizados, cobertura del título o frases clave.
- Mantener explicables los pesos y documentar cualquier cambio del ranking.

### P1 — Atomicidad del contenido personal

- Favorecer memorias independientes para episodios, recetas, preferencias, salud, familia y viajes.
- Evitar recuerdos paraguas que agrupen múltiples experiencias sin detalle recuperable.
- Mantener cada procedimiento autocontenido para que pueda recuperarse sin depender de la conversación original.

### P2 — Convenciones y migración

- Usar prospectivamente `scope:type:short-slug[:yyyy-mm-dd]` para `event_key`.
- No reescribir claves históricas de forma automática.
- Si se requiere normalización, diseñar una migración controlada que preserve idempotencia, relaciones y procedencia.

## Pruebas de regresión

El contrato ampliado debe cubrir, como mínimo:

1. Una consulta personal genérica excluye resultados técnicos y profesionales cuando el filtro lo solicita.
2. Una consulta específica de procedimiento devuelve la memoria atómica esperada en primer lugar.
3. La transición `pending → ready` genera exactamente un registro de recuperación por llamada lista.
4. Las asociaciones no incrementan el contador de recuperación directa.
5. Una consulta repetida reutiliza el embedding en caché y registra cada recuperación lista.
6. Un usuario no puede leer, recuperar ni excluir usando datos de otro propietario.
7. Los clientes 1.2 sin filtros nuevos mantienen su comportamiento actual.

## Criterio de salida

La mejora estará lista cuando las búsquedas genéricas respeten el alcance solicitado sin depender de negaciones en lenguaje natural, las búsquedas específicas mantengan su precisión y todas las garantías de autenticación, idempotencia, trazabilidad y aislamiento continúen verificadas.

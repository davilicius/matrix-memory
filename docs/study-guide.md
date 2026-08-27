# Guía de estudio

Esta guía convierte Matrix en un recorrido práctico para estudiantes de ingeniería. El objetivo no es memorizar SQL, sino entender las decisiones de arquitectura que permiten que un agente conserve contexto de forma segura y verificable.

## Módulo 1: del historial al recuerdo atómico

Una conversación completa mezcla hechos, opiniones, decisiones y preguntas. Matrix divide ese contenido en unidades recuperables.

Ejemplo:

```text
Conversación: "Ayer decidimos usar PostgreSQL porque necesitamos relaciones y vectores".

Memoria:
- tipo: decision
- contenido: usar PostgreSQL
- fecha: ayer
- fuente: conversación de arquitectura
- entidad: PostgreSQL
```

Pregunta: ¿qué información se perdería si solamente guardáramos un resumen de la conversación?

## Módulo 2: verdad, confianza y procedencia

`truth_status` indica si algo fue reportado, verificado, inferido, disputado o continúa desconocido. `confidence` expresa la confianza en el registro, pero no transforma una opinión en un hecho.

Ejercicio: clasifica cada frase.

1. “El sensor registró 31 °C”.
2. “Una persona dijo que la sala estaba caliente”.
3. “Probablemente falló el aire acondicionado”.

## Módulo 3: idempotencia

Un agente puede reintentar una operación después de un error de red. `event_key` evita que el mismo acontecimiento se guarde dos veces.

Ejecuta dos veces el mismo ejemplo del laboratorio y compara los estados `created` y `existing`.

## Módulo 4: recuperación híbrida

La búsqueda textual encuentra palabras. Los embeddings encuentran significados aproximados. Matrix combina ambos rankings con importancia, confianza y saliencia.

Compara estas consultas:

- `automatización de invernadero`
- `sistema que riega plantas sin intervención`

La segunda puede no repetir las palabras originales y aun así recuperar recuerdos cercanos por significado.

## Módulo 5: memoria asociativa

Una recuperación inicial produce recuerdos semilla. `memory_context()` recorre relaciones hasta dos saltos para encontrar decisiones, causas o proyectos asociados sin expandir todo el grafo.

Pregunta: ¿por qué limitar la expansión en lugar de devolver todas las relaciones?

## Módulo 6: seguridad

RLS hace que dos usuarios compartan las mismas tablas sin poder consultar las filas del otro. Las relaciones también validan que ambos nodos pertenezcan al mismo propietario.

Prueba recomendada: crea dos usuarios de laboratorio e intenta consultar una memoria ajena con el cliente autenticado.

## Módulo 7: responsabilidad humana

Una memoria técnica puede ser coherente y aun estar equivocada. El sistema conserva procedencia y estado epistémico para que el agente no confunda recuerdo con verdad absoluta.

Discusión final: ¿qué decisiones no debería tomar un agente únicamente a partir de recuerdos almacenados?

## Producto final sugerido

Construye una demostración con cinco recuerdos sintéticos, tres entidades y cuatro relaciones. Explica:

1. cómo evitas duplicados;
2. cómo proteges a cada usuario;
3. cómo recuperas por significado;
4. cómo distingues evidencia de inferencia;
5. qué riesgos éticos permanecen.

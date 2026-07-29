# Modelo de memoria

## Tipos

- `episode`: evento o experiencia.
- `fact`: afirmación relativamente estable.
- `decision`: curso de acción elegido.
- `intention`: compromiso o plan futuro.
- `project`: panorama durable de un proyecto.
- `reflection`: interpretación o aprendizaje.
- `preference`: elección recurrente.
- `procedure`: método repetible.
- `identity`: hecho durable sobre una identidad.
- `hypothesis`: posibilidad todavía no verificada.

## Estado epistémico

`truth_status` distingue información reportada, verificada, inferida, disputada o desconocida. No debe confundirse confianza con verdad: una memoria puede tener alta confianza y continuar siendo un reporte.

## Tiempo

- `occurred_at` y `ended_at`: cuándo ocurrió el episodio.
- `valid_from` y `valid_to`: cuándo fue válida la afirmación.
- `life_period_id`: periodo vital o profesional.

## Señales de recuperación

- `importance`: relevancia durable.
- `emotional_intensity`: saliencia emocional.
- `confidence`: confianza en el contenido.
- `fts`: representación para texto completo en español.
- `embedding`: vector semántico de 384 dimensiones.

## Procedencia

Cada escritura requiere una `source` nueva o un `source_id` existente. Una fuente puede ser conversación, documento, correo, foto, audio, video, nota, base de datos, web, sensor, testimonio u otro.

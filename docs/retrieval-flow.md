# Flujo de recuperación

1. El agente formula una consulta textual.
2. Opcionalmente genera un embedding de 384 dimensiones.
3. `recall_memories` filtra por propietario, estado, tipo y rango temporal.
4. Se crean rankings independientes de texto completo y similitud vectorial.
5. Los candidatos se fusionan y ponderan con importancia, confianza y saliencia.
6. El agente selecciona recuerdos semilla.
7. `memory_context` expande relaciones relevantes hasta dos saltos.
8. El agente distingue hechos almacenados de inferencias nuevas.

La recuperación no debe utilizar un rol que omita RLS. El contexto asociativo complementa el ranking inicial; no lo sustituye.

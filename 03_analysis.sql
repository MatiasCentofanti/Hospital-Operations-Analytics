/* =============================================================================
   03_analysis.sql  -  Hospital Operations Analytics
   10 consultas analiticas. Cada bloque es independiente: se puede seleccionar
   y ejecutar por separado (F5 sobre la seleccion).
   ============================================================================= */

USE HospitalAnalytics;
GO

/* -----------------------------------------------------------------------------
   Q1. Tablero ejecutivo: los numeros del año en una sola fila.
   Responde: cuanta demanda hubo, cuanta pudimos absorber y como nos fue.
----------------------------------------------------------------------------- */
SELECT
    SUM(f.patients_request)                                            AS solicitudes,
    SUM(f.patients_admitted)                                           AS admitidos,
    SUM(f.patients_refused)                                            AS rechazados,
    CAST(100.0 * SUM(f.patients_refused) / SUM(f.patients_request) AS DECIMAL(5,2)) AS tasa_rechazo_pct,
    CAST(100.0 * SUM(f.patients_admitted) / SUM(f.available_beds) AS DECIMAL(5,2))  AS ocupacion_pct,
    CAST(AVG(1.0 * f.patient_satisfaction) AS DECIMAL(5,2))            AS satisfaccion_operativa,
    CAST(AVG(1.0 * f.staff_morale)         AS DECIMAL(5,2))            AS moral_equipo,
    SUM(CAST(f.is_critical_week AS INT))                               AS semanas_servicio_criticas
FROM dw.fact_service_weekly AS f;
GO


/* -----------------------------------------------------------------------------
   Q2. Ranking de servicios. Cual es el cuello de botella real del hospital.
----------------------------------------------------------------------------- */
SELECT
    s.service_label                                                     AS servicio,
    SUM(f.patients_request)                                             AS solicitudes,
    SUM(f.patients_admitted)                                            AS admitidos,
    SUM(f.patients_refused)                                             AS rechazados,
    CAST(100.0 * SUM(f.patients_refused) / SUM(f.patients_request) AS DECIMAL(5,2)) AS tasa_rechazo_pct,
    CAST(100.0 * SUM(f.patients_admitted) / SUM(f.available_beds)  AS DECIMAL(5,2)) AS ocupacion_pct,
    CAST(AVG(1.0 * f.patient_satisfaction) AS DECIMAL(5,2))             AS satisfaccion,
    CAST(AVG(1.0 * f.staff_morale)         AS DECIMAL(5,2))             AS moral,
    RANK() OVER (ORDER BY SUM(f.patients_refused) DESC)                 AS ranking_rechazo
FROM dw.fact_service_weekly AS f
JOIN dw.dim_service         AS s ON s.service_id = f.service_id
GROUP BY s.service_label
ORDER BY rechazados DESC;
GO


/* -----------------------------------------------------------------------------
   Q3. Evolucion mensual con variacion contra el mes anterior (LAG).
   Sirve para el grafico de linea del reporte y para detectar los picos.
----------------------------------------------------------------------------- */
WITH mensual AS (
    SELECT
        w.month                                        AS mes,
        MIN(w.month_short)                             AS mes_nombre,
        SUM(f.patients_request)                        AS solicitudes,
        SUM(f.patients_admitted)                       AS admitidos,
        SUM(f.patients_refused)                        AS rechazados,
        CAST(AVG(1.0 * f.staff_morale) AS DECIMAL(5,2)) AS moral
    FROM dw.fact_service_weekly AS f
    JOIN dw.dim_week            AS w ON w.week_id = f.week_id
    GROUP BY w.month
)
SELECT
    mes,
    mes_nombre,
    solicitudes,
    admitidos,
    rechazados,
    moral,
    LAG(solicitudes) OVER (ORDER BY mes)                AS solicitudes_mes_previo,
    CAST(100.0 * (solicitudes - LAG(solicitudes) OVER (ORDER BY mes))
         / NULLIF(LAG(solicitudes) OVER (ORDER BY mes), 0) AS DECIMAL(6,2)) AS var_solicitudes_pct,
    CAST(100.0 * (rechazados - LAG(rechazados) OVER (ORDER BY mes))
         / NULLIF(LAG(rechazados) OVER (ORDER BY mes), 0) AS DECIMAL(6,2)) AS var_rechazos_pct
FROM mensual
ORDER BY mes;
GO


/* -----------------------------------------------------------------------------
   Q4. Impacto de los eventos externos. Se compara cada evento contra la
   linea de base de las semanas sin evento.
----------------------------------------------------------------------------- */
WITH por_evento AS (
    SELECT
        f.event,
        MIN(f.event_label)                                  AS evento,
        COUNT(*)                                            AS semanas_servicio,
        CAST(AVG(1.0 * f.patients_request)      AS DECIMAL(7,2)) AS solicitudes_prom,
        CAST(AVG(100.0 * f.refusal_rate)        AS DECIMAL(5,2)) AS tasa_rechazo_pct,
        CAST(AVG(1.0 * f.patient_satisfaction)  AS DECIMAL(5,2)) AS satisfaccion,
        CAST(AVG(1.0 * f.staff_morale)          AS DECIMAL(5,2)) AS moral
    FROM dw.fact_service_weekly AS f
    GROUP BY f.event
),
base AS (
    SELECT tasa_rechazo_pct AS base_rechazo, moral AS base_moral, satisfaccion AS base_satis
    FROM por_evento WHERE event = 'none'
)
SELECT
    e.evento,
    e.semanas_servicio,
    e.solicitudes_prom,
    e.tasa_rechazo_pct,
    e.satisfaccion,
    e.moral,
    CAST(e.tasa_rechazo_pct - b.base_rechazo AS DECIMAL(6,2)) AS delta_rechazo_pp,
    CAST(e.moral            - b.base_moral   AS DECIMAL(6,2)) AS delta_moral_pp,
    CAST(e.satisfaccion     - b.base_satis   AS DECIMAL(6,2)) AS delta_satisfaccion_pp
FROM por_evento AS e
CROSS JOIN base AS b
ORDER BY delta_rechazo_pp DESC;
GO


/* -----------------------------------------------------------------------------
   Q5. Las 10 semanas-servicio mas criticas del año.
   Criterio: mayor cantidad de pacientes rechazados.
----------------------------------------------------------------------------- */
SELECT TOP (10)
    w.week_label                                        AS semana,
    w.month_short                                       AS mes,
    s.service_label                                     AS servicio,
    f.available_beds                                    AS camas,
    f.patients_request                                  AS solicitudes,
    f.patients_admitted                                 AS admitidos,
    f.patients_refused                                  AS rechazados,
    CAST(100.0 * f.refusal_rate AS DECIMAL(5,2))        AS tasa_rechazo_pct,
    f.event_label                                       AS evento,
    f.staff_morale                                      AS moral,
    DENSE_RANK() OVER (ORDER BY f.patients_refused DESC) AS ranking
FROM dw.fact_service_weekly AS f
JOIN dw.dim_week            AS w ON w.week_id    = f.week_id
JOIN dw.dim_service         AS s ON s.service_id = f.service_id
ORDER BY f.patients_refused DESC;
GO


/* -----------------------------------------------------------------------------
   Q6. Ausentismo del personal por servicio y rol.
   Nota: se excluyen las 17 semanas donde el archivo de origen trae al hospital
   entero con present = 0 (patron del sistema, no ausentismo real). El ETL las
   deja marcadas con has_attendance_record = 0.
----------------------------------------------------------------------------- */
SELECT
    s.service_label                                                   AS servicio,
    st.role_label                                                     AS rol,
    COUNT(DISTINCT st.staff_id)                                       AS dotacion,
    COUNT(*)                                                          AS turnos_planificados,
    SUM(CAST(a.present AS INT))                                       AS turnos_cubiertos,
    SUM(CAST(a.absent  AS INT))                                       AS ausencias,
    CAST(100.0 * SUM(CAST(a.absent AS INT)) / COUNT(*) AS DECIMAL(5,2)) AS ausentismo_pct
FROM dw.fact_staff_attendance AS a
JOIN dw.dim_staff             AS st ON st.staff_id   = a.staff_id
JOIN dw.dim_service           AS s  ON s.service_id  = st.service_id
WHERE a.has_attendance_record = 1
GROUP BY s.service_label, st.role_label
ORDER BY ausentismo_pct DESC;
GO


/* -----------------------------------------------------------------------------
   Q7. La pregunta del millon: cuando falta gente, se rechazan mas pacientes?
   Se parte el año en cuartiles de ausentismo semanal y se compara.
----------------------------------------------------------------------------- */
WITH ausentismo_semanal AS (
    SELECT
        a.week_id,
        a.service_id,
        CAST(100.0 * SUM(CAST(a.absent AS INT)) / COUNT(*) AS DECIMAL(5,2)) AS ausentismo_pct
    FROM dw.fact_staff_attendance AS a
    WHERE a.has_attendance_record = 1
    GROUP BY a.week_id, a.service_id
),
combinado AS (
    SELECT
        f.week_id,
        f.service_id,
        au.ausentismo_pct,
        100.0 * f.refusal_rate AS tasa_rechazo_pct,
        f.staff_morale,
        f.patients_refused,
        NTILE(4) OVER (ORDER BY au.ausentismo_pct) AS cuartil_ausentismo
    FROM dw.fact_service_weekly AS f
    JOIN ausentismo_semanal     AS au
      ON au.week_id = f.week_id AND au.service_id = f.service_id
)
SELECT
    cuartil_ausentismo,
    COUNT(*)                                                    AS semanas_servicio,
    CAST(MIN(ausentismo_pct) AS DECIMAL(5,2))                   AS ausentismo_min_pct,
    CAST(MAX(ausentismo_pct) AS DECIMAL(5,2))                   AS ausentismo_max_pct,
    CAST(AVG(tasa_rechazo_pct) AS DECIMAL(5,2))                 AS tasa_rechazo_prom_pct,
    CAST(AVG(1.0 * patients_refused) AS DECIMAL(7,2))           AS rechazados_prom,
    CAST(AVG(1.0 * staff_morale) AS DECIMAL(5,2))               AS moral_prom
FROM combinado
GROUP BY cuartil_ausentismo
ORDER BY cuartil_ausentismo;
GO


/* -----------------------------------------------------------------------------
   Q8. Perfil de los pacientes internados por grupo etario.
----------------------------------------------------------------------------- */
SELECT
    p.age_group                                          AS grupo_etario,
    COUNT(*)                                             AS pacientes,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2)) AS participacion_pct,
    CAST(AVG(1.0 * fa.length_of_stay) AS DECIMAL(5,2))   AS estadia_prom_dias,
    MAX(fa.length_of_stay)                               AS estadia_max_dias,
    CAST(AVG(1.0 * fa.satisfaction)   AS DECIMAL(5,2))   AS satisfaccion_prom,
    SUM(CASE WHEN fa.satisfaction < 70 THEN 1 ELSE 0 END) AS casos_criticos
FROM dw.fact_admissions AS fa
JOIN dw.dim_patient     AS p ON p.patient_id = fa.patient_id
GROUP BY p.age_group
ORDER BY estadia_prom_dias DESC;
GO


/* -----------------------------------------------------------------------------
   Q9. Media movil de 4 semanas de pacientes rechazados, por servicio.
   Suaviza el ruido semanal y deja ver la tendencia real.
----------------------------------------------------------------------------- */
SELECT
    w.week_label                                        AS semana,
    s.service_label                                     AS servicio,
    f.patients_refused                                  AS rechazados,
    CAST(AVG(1.0 * f.patients_refused) OVER (
            PARTITION BY f.service_id
            ORDER BY f.week_id
            ROWS BETWEEN 3 PRECEDING AND CURRENT ROW
         ) AS DECIMAL(7,2))                             AS media_movil_4s,
    SUM(f.patients_refused) OVER (
            PARTITION BY f.service_id
            ORDER BY f.week_id
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
         )                                              AS rechazados_acumulado
FROM dw.fact_service_weekly AS f
JOIN dw.dim_week            AS w ON w.week_id    = f.week_id
JOIN dw.dim_service         AS s ON s.service_id = f.service_id
ORDER BY s.service_label, f.week_id;
GO


/* -----------------------------------------------------------------------------
   Q10. Brecha entre la satisfaccion que reporta el servicio y la que declaran
   los pacientes internados. Si la brecha es grande, el termometro operativo
   no esta midiendo lo que le pasa a la gente.
----------------------------------------------------------------------------- */
WITH operativa AS (
    SELECT
        w.month                                          AS mes,
        f.service_id,
        CAST(AVG(1.0 * f.patient_satisfaction) AS DECIMAL(5,2)) AS satis_operativa
    FROM dw.fact_service_weekly AS f
    JOIN dw.dim_week            AS w ON w.week_id = f.week_id
    GROUP BY w.month, f.service_id
),
declarada AS (
    SELECT
        w.month                                          AS mes,
        fa.service_id,
        COUNT(*)                                         AS pacientes,
        CAST(AVG(1.0 * fa.satisfaction) AS DECIMAL(5,2)) AS satis_pacientes
    FROM dw.fact_admissions AS fa
    JOIN dw.dim_week        AS w ON w.week_id = fa.arrival_week_id
    GROUP BY w.month, fa.service_id
)
SELECT
    o.mes,
    s.service_label                                       AS servicio,
    d.pacientes,
    o.satis_operativa,
    d.satis_pacientes,
    CAST(o.satis_operativa - d.satis_pacientes AS DECIMAL(6,2)) AS brecha
FROM operativa   AS o
JOIN declarada   AS d ON d.mes = o.mes AND d.service_id = o.service_id
JOIN dw.dim_service AS s ON s.service_id = o.service_id
ORDER BY ABS(o.satis_operativa - d.satis_pacientes) DESC;
GO
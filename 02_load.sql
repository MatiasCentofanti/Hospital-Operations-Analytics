/* =============================================================================
   02_load.sql  -  Carga de los CSV limpios que genera el ETL de Python
   -----------------------------------------------------------------------------
   OPCION A (la que uso): BULK INSERT.
     Requisito: los CSV tienen que estar en una carpeta accesible por el SERVICIO
     de SQL Server, no por tu usuario. Si SQL Server corre en tu propia maquina,
     C:\hospital\clean\ funciona. Ajusta @ruta abajo.

   OPCION B (si BULK INSERT te da error de permisos):
     Click derecho sobre la base > Tasks > Import Flat File, y repetir para cada
     CSV. Elegir "Unicode UTF-8 (65001)" como codificacion y la primera fila
     como encabezado. El orden de carga tiene que ser el mismo que el de abajo.
   ============================================================================= */

USE HospitalAnalytics;
GO

/* Vaciado en orden inverso a las FK, por si se recarga */
DELETE FROM dw.fact_staff_attendance;
DELETE FROM dw.fact_service_weekly;
DELETE FROM dw.fact_admissions;
DELETE FROM dw.rejects_staff_schedule;
DELETE FROM dw.dq_report;
DELETE FROM dw.dim_staff;
DELETE FROM dw.dim_patient;
DELETE FROM dw.dim_calendar;
DELETE FROM dw.dim_week;
DELETE FROM dw.dim_role;
DELETE FROM dw.dim_service;
GO

/* ------------------------------------------------------------------ DIMS -- */

BULK INSERT dw.dim_service
FROM 'C:\hospital\clean\dim_service.csv'
WITH (FORMAT='CSV', FIRSTROW=2, FIELDTERMINATOR=',', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK);

BULK INSERT dw.dim_role
FROM 'C:\hospital\clean\dim_role.csv'
WITH (FORMAT='CSV', FIRSTROW=2, FIELDTERMINATOR=',', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK);

BULK INSERT dw.dim_week
FROM 'C:\hospital\clean\dim_week.csv'
WITH (FORMAT='CSV', FIRSTROW=2, FIELDTERMINATOR=',', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK);

BULK INSERT dw.dim_calendar
FROM 'C:\hospital\clean\dim_calendar.csv'
WITH (FORMAT='CSV', FIRSTROW=2, FIELDTERMINATOR=',', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK);

BULK INSERT dw.dim_patient
FROM 'C:\hospital\clean\dim_patient.csv'
WITH (FORMAT='CSV', FIRSTROW=2, FIELDTERMINATOR=',', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK);

BULK INSERT dw.dim_staff
FROM 'C:\hospital\clean\dim_staff.csv'
WITH (FORMAT='CSV', FIRSTROW=2, FIELDTERMINATOR=',', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK);

/* ----------------------------------------------------------------- FACTS -- */

BULK INSERT dw.fact_admissions
FROM 'C:\hospital\clean\fact_admissions.csv'
WITH (FORMAT='CSV', FIRSTROW=2, FIELDTERMINATOR=',', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK);

BULK INSERT dw.fact_service_weekly
FROM 'C:\hospital\clean\fact_service_weekly.csv'
WITH (FORMAT='CSV', FIRSTROW=2, FIELDTERMINATOR=',', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK);

BULK INSERT dw.fact_staff_attendance
FROM 'C:\hospital\clean\fact_staff_attendance.csv'
WITH (FORMAT='CSV', FIRSTROW=2, FIELDTERMINATOR=',', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK);

/* ---------------------------------------------------------------- CONTROL - */

BULK INSERT dw.rejects_staff_schedule
FROM 'C:\hospital\clean\rejects_staff_schedule.csv'
WITH (FORMAT='CSV', FIRSTROW=2, FIELDTERMINATOR=',', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK);

BULK INSERT dw.dq_report
FROM 'C:\hospital\clean\dq_report.csv'
WITH (FORMAT='CSV', FIRSTROW=2, FIELDTERMINATOR=',', ROWTERMINATOR='0x0a', CODEPAGE='65001', TABLOCK);
GO

/* ========================= CONTROL POST-CARGA ============================= */
/* Los valores esperados son los que devuelve el ETL. Si alguno no coincide,
   la carga quedo incompleta. */

SELECT 'dim_service'           AS tabla, COUNT(*) AS filas, 4    AS esperado FROM dw.dim_service
UNION ALL SELECT 'dim_role',            COUNT(*), 3    FROM dw.dim_role
UNION ALL SELECT 'dim_week',            COUNT(*), 52   FROM dw.dim_week
UNION ALL SELECT 'dim_calendar',        COUNT(*), 730  FROM dw.dim_calendar
UNION ALL SELECT 'dim_patient',         COUNT(*), 1000 FROM dw.dim_patient
UNION ALL SELECT 'dim_staff',           COUNT(*), 110  FROM dw.dim_staff
UNION ALL SELECT 'fact_admissions',     COUNT(*), 1000 FROM dw.fact_admissions
UNION ALL SELECT 'fact_service_weekly', COUNT(*), 208  FROM dw.fact_service_weekly
UNION ALL SELECT 'fact_staff_attendance', COUNT(*), 5720 FROM dw.fact_staff_attendance
UNION ALL SELECT 'rejects_staff_schedule', COUNT(*), 832 FROM dw.rejects_staff_schedule;
GO
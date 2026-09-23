/* =============================================================================
   01_schema.sql  -  Hospital Operations Analytics
   Motor: SQL Server 2019+  |  Ejecutar en SSMS de arriba a abajo
   Crea la base, el esquema estrella, las claves y los indices.
   ============================================================================= */

IF DB_ID('HospitalAnalytics') IS NULL
    CREATE DATABASE HospitalAnalytics;
GO

USE HospitalAnalytics;
GO

IF SCHEMA_ID('dw') IS NULL EXEC('CREATE SCHEMA dw');
GO

/* --- Se borra en orden inverso a las dependencias ------------------------- */
DROP TABLE IF EXISTS dw.fact_staff_attendance;
DROP TABLE IF EXISTS dw.fact_service_weekly;
DROP TABLE IF EXISTS dw.fact_admissions;
DROP TABLE IF EXISTS dw.rejects_staff_schedule;
DROP TABLE IF EXISTS dw.dq_report;
DROP TABLE IF EXISTS dw.dim_staff;
DROP TABLE IF EXISTS dw.dim_patient;
DROP TABLE IF EXISTS dw.dim_calendar;
DROP TABLE IF EXISTS dw.dim_week;
DROP TABLE IF EXISTS dw.dim_role;
DROP TABLE IF EXISTS dw.dim_service;
GO

/* =============================== DIMENSIONES ============================== */

CREATE TABLE dw.dim_service (
    service_id      TINYINT       NOT NULL PRIMARY KEY,
    service_name    VARCHAR(30)   NOT NULL,
    service_label   NVARCHAR(40)  NOT NULL
);

CREATE TABLE dw.dim_role (
    role_id         TINYINT       NOT NULL PRIMARY KEY,
    role_name       VARCHAR(30)   NOT NULL,
    role_label      NVARCHAR(40)  NOT NULL
);

CREATE TABLE dw.dim_week (
    week_id         TINYINT       NOT NULL PRIMARY KEY,
    month           TINYINT       NOT NULL,
    month_name      NVARCHAR(15)  NOT NULL,
    month_short     NVARCHAR(5)   NOT NULL,
    quarter         TINYINT       NOT NULL,
    quarter_label   VARCHAR(2)    NOT NULL,
    week_label      VARCHAR(4)    NOT NULL,
    year_month      VARCHAR(7)    NOT NULL,
    has_attendance_record BIT     NOT NULL   -- 0 = semana sin registro de presencia
);

CREATE TABLE dw.dim_calendar (
    date_id         INT           NOT NULL PRIMARY KEY,
    [date]          DATE          NOT NULL,
    [year]          SMALLINT      NOT NULL,
    quarter         TINYINT       NOT NULL,
    quarter_label   VARCHAR(2)    NOT NULL,
    [month]         TINYINT       NOT NULL,
    month_name      NVARCHAR(15)  NOT NULL,
    month_short     NVARCHAR(5)   NOT NULL,
    year_month      VARCHAR(7)    NOT NULL,
    [day]           TINYINT       NOT NULL,
    day_of_week     TINYINT       NOT NULL,
    day_name        NVARCHAR(12)  NOT NULL,
    is_weekend      BIT           NOT NULL,
    week_id         TINYINT       NULL
);

CREATE TABLE dw.dim_patient (
    patient_id      VARCHAR(20)   NOT NULL PRIMARY KEY,
    patient_name    NVARCHAR(80)  NOT NULL,
    age             TINYINT       NOT NULL,
    age_group       NVARCHAR(30)  NOT NULL
);

CREATE TABLE dw.dim_staff (
    staff_id        VARCHAR(20)   NOT NULL PRIMARY KEY,
    staff_name      NVARCHAR(80)  NOT NULL,
    role_id         TINYINT       NOT NULL,
    role_name       VARCHAR(30)   NOT NULL,
    role_label      NVARCHAR(40)  NOT NULL,
    service_id      TINYINT       NOT NULL
);

/* ================================= HECHOS ================================= */

CREATE TABLE dw.fact_admissions (
    admission_id        INT           NOT NULL PRIMARY KEY,
    patient_id          VARCHAR(20)   NOT NULL,
    service_id          TINYINT       NOT NULL,
    arrival_week_id     TINYINT       NOT NULL,
    arrival_date        DATE          NOT NULL,
    departure_date      DATE          NOT NULL,
    length_of_stay      SMALLINT      NOT NULL,
    stay_band           NVARCHAR(20)  NOT NULL,
    satisfaction        TINYINT       NOT NULL,
    satisfaction_band   NVARCHAR(25)  NOT NULL,
    crosses_year        BIT           NOT NULL
);

CREATE TABLE dw.fact_service_weekly (
    service_week_id       SMALLINT      NOT NULL PRIMARY KEY,
    week_id               TINYINT       NOT NULL,
    service_id            TINYINT       NOT NULL,
    available_beds        SMALLINT      NOT NULL,
    patients_request      SMALLINT      NOT NULL,
    patients_admitted     SMALLINT      NOT NULL,
    patients_refused      SMALLINT      NOT NULL,
    patient_satisfaction  TINYINT       NOT NULL,
    staff_morale          TINYINT       NOT NULL,
    event                 VARCHAR(20)   NOT NULL,
    event_label           NVARCHAR(30)  NOT NULL,
    occupancy_rate        DECIMAL(9,4)  NOT NULL,
    refusal_rate          DECIMAL(9,4)  NULL,
    demand_pressure       DECIMAL(9,4)  NOT NULL,
    flag_over_capacity    BIT           NOT NULL,
    is_critical_week      BIT           NOT NULL
);

CREATE TABLE dw.fact_staff_attendance (
    attendance_id   INT           NOT NULL PRIMARY KEY,
    week_id         TINYINT       NOT NULL,
    staff_id        VARCHAR(20)   NOT NULL,
    service_id      TINYINT       NOT NULL,
    present         BIT           NOT NULL,
    absent          BIT           NOT NULL,
    has_attendance_record BIT     NOT NULL
);

/* ============================ TABLAS DE CONTROL =========================== */

CREATE TABLE dw.rejects_staff_schedule (
    week_id           TINYINT       NULL,
    staff_id_archivo  VARCHAR(20)   NULL,
    staff_name        NVARCHAR(80)  NULL,
    role_archivo      VARCHAR(30)   NULL,
    service_archivo   VARCHAR(30)   NULL,
    present           TINYINT       NULL,
    motivo_rechazo    NVARCHAR(120) NULL
);

CREATE TABLE dw.dq_report (
    tabla             VARCHAR(40)   NOT NULL,
    control           NVARCHAR(120) NOT NULL,
    filas_afectadas   INT           NOT NULL,
    accion            NVARCHAR(120) NOT NULL
);
GO

/* ============================= CLAVES FORANEAS ============================ */

ALTER TABLE dw.dim_staff
    ADD CONSTRAINT FK_staff_service  FOREIGN KEY (service_id) REFERENCES dw.dim_service(service_id),
        CONSTRAINT FK_staff_role     FOREIGN KEY (role_id)    REFERENCES dw.dim_role(role_id);

ALTER TABLE dw.fact_admissions
    ADD CONSTRAINT FK_adm_patient    FOREIGN KEY (patient_id)      REFERENCES dw.dim_patient(patient_id),
        CONSTRAINT FK_adm_service    FOREIGN KEY (service_id)      REFERENCES dw.dim_service(service_id),
        CONSTRAINT FK_adm_week       FOREIGN KEY (arrival_week_id) REFERENCES dw.dim_week(week_id);

ALTER TABLE dw.fact_service_weekly
    ADD CONSTRAINT FK_svc_service    FOREIGN KEY (service_id) REFERENCES dw.dim_service(service_id),
        CONSTRAINT FK_svc_week       FOREIGN KEY (week_id)    REFERENCES dw.dim_week(week_id);

ALTER TABLE dw.fact_staff_attendance
    ADD CONSTRAINT FK_att_staff      FOREIGN KEY (staff_id)   REFERENCES dw.dim_staff(staff_id),
        CONSTRAINT FK_att_service    FOREIGN KEY (service_id) REFERENCES dw.dim_service(service_id),
        CONSTRAINT FK_att_week       FOREIGN KEY (week_id)    REFERENCES dw.dim_week(week_id);
GO

/* ================================ INDICES ================================= */

CREATE INDEX IX_adm_service_week  ON dw.fact_admissions(service_id, arrival_week_id) INCLUDE (length_of_stay, satisfaction);
CREATE INDEX IX_adm_arrival       ON dw.fact_admissions(arrival_date);
CREATE UNIQUE INDEX UX_svc_week   ON dw.fact_service_weekly(week_id, service_id);
CREATE INDEX IX_att_week_service  ON dw.fact_staff_attendance(week_id, service_id) INCLUDE (present, absent);
GO

/* ============================ RESTRICCIONES DE NEGOCIO ==================== */

ALTER TABLE dw.fact_service_weekly
    ADD CONSTRAINT CK_svc_demanda CHECK (patients_admitted + patients_refused = patients_request),
        CONSTRAINT CK_svc_satis   CHECK (patient_satisfaction BETWEEN 0 AND 100),
        CONSTRAINT CK_svc_moral   CHECK (staff_morale BETWEEN 0 AND 100);

ALTER TABLE dw.fact_admissions
    ADD CONSTRAINT CK_adm_fechas  CHECK (departure_date >= arrival_date),
        CONSTRAINT CK_adm_los     CHECK (length_of_stay >= 0);
GO

PRINT 'Esquema dw creado correctamente.';

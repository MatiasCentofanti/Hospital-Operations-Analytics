"""
================================================================================
 ETL - Hospital Operations Analytics
================================================================================
 Entrada : 4 CSV crudos (patients, services_weekly, staff, staff_schedule)
 Salida  : modelo estrella en CSV limpio, listo para SQL Server y Power BI

 Uso en Google Colab
 -------------------
   1. Subir los 4 CSV crudos (panel izquierdo > Archivos > Subir).
   2. Dejar RAW_DIR = "/content" y CLEAN_DIR = "/content/clean".
   3. Ejecutar todo (Ctrl+F9).
   4. Descargar la carpeta /content/clean (o usar el bloque de descarga final).
================================================================================
"""

from __future__ import annotations

import os
import re
import unicodedata
from datetime import date

import numpy as np
import pandas as pd

# ------------------------------------------------------------------------------
# 0. CONFIGURACION
# ------------------------------------------------------------------------------

RAW_DIR = "/content"                 # en local: "data/raw"
CLEAN_DIR = "/content/clean"         # en local: "data/clean"

ANIO_OPERATIVO = 2025

# Mapa de servicios: clave canonica -> (id, etiqueta para el reporte)
SERVICIOS = {
    "emergency":        (1, "Guardia"),
    "surgery":          (2, "Cirugía"),
    "general_medicine": (3, "Clínica Médica"),
    "ICU":              (4, "UTI"),
}

# Mapa de roles: clave canonica -> (id, etiqueta para el reporte)
ROLES = {
    "doctor":            (1, "Médico/a"),
    "nurse":             (2, "Enfermero/a"),
    "nursing_assistant": (3, "Auxiliar de Enfermería"),
}

# Mapa de eventos externos
EVENTOS = {
    "none":     "Sin evento",
    "flu":      "Brote de gripe",
    "strike":   "Paro / huelga",
    "donation": "Donación",
}

MESES_ES = {
    1: "Enero", 2: "Febrero", 3: "Marzo", 4: "Abril", 5: "Mayo", 6: "Junio",
    7: "Julio", 8: "Agosto", 9: "Septiembre", 10: "Octubre",
    11: "Noviembre", 12: "Diciembre",
}

os.makedirs(CLEAN_DIR, exist_ok=True)

# Acumulador del reporte de calidad de datos
DQ_LOG: list[dict] = []


def log_dq(tabla: str, control: str, filas: int, accion: str) -> None:
    """Registra un hallazgo de calidad de datos y lo imprime."""
    DQ_LOG.append(
        {"tabla": tabla, "control": control, "filas_afectadas": int(filas), "accion": accion}
    )
    estado = "OK  " if filas == 0 else "AVISO"
    print(f"  [{estado}] {tabla:<20} | {control:<45} | {filas:>5} | {accion}")


# ------------------------------------------------------------------------------
# 1. HELPERS DE LIMPIEZA
# ------------------------------------------------------------------------------

def normalizar_columnas(df: pd.DataFrame) -> pd.DataFrame:
    """Pasa los nombres de columna a snake_case sin acentos ni espacios."""
    nuevas = []
    for c in df.columns:
        c = unicodedata.normalize("NFKD", str(c)).encode("ascii", "ignore").decode()
        c = re.sub(r"[^0-9a-zA-Z]+", "_", c).strip("_").lower()
        nuevas.append(c)
    df.columns = nuevas
    return df


def limpiar_texto(serie: pd.Series) -> pd.Series:
    """Quita espacios sobrantes y unifica espacios internos. No cambia el case."""
    return (
        serie.astype("string")
        .str.strip()
        .str.replace(r"\s+", " ", regex=True)
        .replace({"": pd.NA, "nan": pd.NA, "None": pd.NA, "NULL": pd.NA})
    )


def canonizar_servicio(serie: pd.Series) -> pd.Series:
    """Unifica variantes de escritura (icu, Icu, ICU / EMERGENCY, emergency...)."""
    base = limpiar_texto(serie).str.lower().str.replace(" ", "_", regex=False)
    equivalencias = {
        "icu": "ICU", "uti": "ICU", "intensive_care": "ICU",
        "emergency": "emergency", "er": "emergency", "guardia": "emergency",
        "surgery": "surgery", "cirugia": "surgery",
        "general_medicine": "general_medicine", "generalmedicine": "general_medicine",
        "clinica_medica": "general_medicine",
    }
    return base.map(equivalencias).astype("string")


def canonizar_rol(serie: pd.Series) -> pd.Series:
    base = limpiar_texto(serie).str.lower().str.replace(" ", "_", regex=False)
    equivalencias = {
        "doctor": "doctor", "physician": "doctor", "medico": "doctor",
        "nurse": "nurse", "enfermero": "nurse",
        "nursing_assistant": "nursing_assistant", "assistant": "nursing_assistant",
        "auxiliar": "nursing_assistant",
    }
    return base.map(equivalencias).astype("string")


def semana_operativa(fecha: pd.Series) -> pd.Series:
    """
    Convierte una fecha a la semana operativa 1..52 que usa el hospital.
    Bloques fijos de 7 dias desde el 1 de enero; los dias sobrantes caen en la 52.
    """
    doy = fecha.dt.dayofyear
    return np.minimum(((doy - 1) // 7) + 1, 52).astype("Int64")


# ------------------------------------------------------------------------------
# 2. EXTRACT
# ------------------------------------------------------------------------------

print("\n" + "=" * 90)
print("1) EXTRACT - lectura de archivos crudos")
print("=" * 90)

raw_patients = normalizar_columnas(pd.read_csv(f"{RAW_DIR}/patients.csv", dtype=str))
raw_services = normalizar_columnas(pd.read_csv(f"{RAW_DIR}/services_weekly.csv", dtype=str))
raw_staff = normalizar_columnas(pd.read_csv(f"{RAW_DIR}/staff.csv", dtype=str))
raw_sched = normalizar_columnas(pd.read_csv(f"{RAW_DIR}/staff_schedule.csv", dtype=str))

for nombre, df in [
    ("patients", raw_patients), ("services_weekly", raw_services),
    ("staff", raw_staff), ("staff_schedule", raw_sched),
]:
    print(f"  {nombre:<18} {df.shape[0]:>6} filas x {df.shape[1]} columnas")


# ------------------------------------------------------------------------------
# 3. DIMENSIONES DE CATALOGO
# ------------------------------------------------------------------------------

print("\n" + "=" * 90)
print("2) TRANSFORM - dimensiones de catálogo")
print("=" * 90)

dim_service = pd.DataFrame(
    [{"service_id": v[0], "service_name": k, "service_label": v[1]} for k, v in SERVICIOS.items()]
).sort_values("service_id").reset_index(drop=True)

dim_role = pd.DataFrame(
    [{"role_id": v[0], "role_name": k, "role_label": v[1]} for k, v in ROLES.items()]
).sort_values("role_id").reset_index(drop=True)

MAP_SERVICE_ID = dict(zip(dim_service.service_name, dim_service.service_id))
MAP_ROLE_ID = dict(zip(dim_role.role_name, dim_role.role_id))

print(f"  dim_service: {len(dim_service)} filas | dim_role: {len(dim_role)} filas")


# ------------------------------------------------------------------------------
# 4. SERVICES_WEEKLY -> fact_service_weekly + dim_week
# ------------------------------------------------------------------------------

print("\n" + "=" * 90)
print("3) TRANSFORM - services_weekly")
print("=" * 90)

sw = raw_services.copy()

num_cols = [
    "week", "month", "available_beds", "patients_request",
    "patients_admitted", "patients_refused", "patient_satisfaction", "staff_morale",
]
for c in num_cols:
    sw[c] = pd.to_numeric(sw[c], errors="coerce").astype("Int64")

sw["service_name"] = canonizar_servicio(sw["service"])
sw["event"] = limpiar_texto(sw["event"]).str.lower().fillna("none")

log_dq("services_weekly", "Servicio no reconocido", sw.service_name.isna().sum(), "Se descarta la fila")
sw = sw[sw.service_name.notna()].copy()

log_dq("services_weekly", "Métrica numérica nula tras el casteo",
       sw[num_cols].isna().any(axis=1).sum(), "Se descarta la fila")
sw = sw.dropna(subset=num_cols).copy()

dups = sw.duplicated(subset=["week", "service_name"]).sum()
log_dq("services_weekly", "Duplicados por (semana, servicio)", dups, "Se conserva la última ocurrencia")
sw = sw.drop_duplicates(subset=["week", "service_name"], keep="last").copy()

# Coherencia de la ecuacion de demanda
incoherentes = (sw.patients_admitted + sw.patients_refused != sw.patients_request).sum()
log_dq("services_weekly", "admitidos + rechazados <> solicitudes", incoherentes,
       "Se recalcula rechazados = solicitudes - admitidos")
sw["patients_refused"] = (sw.patients_request - sw.patients_admitted).clip(lower=0)

sobre_capacidad = (sw.patients_admitted > sw.available_beds).sum()
log_dq("services_weekly", "Admitidos por encima de camas disponibles", sobre_capacidad,
       "Se marca con la bandera flag_over_capacity")
sw["flag_over_capacity"] = (sw.patients_admitted > sw.available_beds).astype(int)

fuera_rango = (~sw.week.between(1, 52)).sum()
log_dq("services_weekly", "Semana fuera del rango 1-52", fuera_rango, "Se descarta la fila")
sw = sw[sw.week.between(1, 52)].copy()

# Metricas derivadas
sw["service_id"] = sw.service_name.map(MAP_SERVICE_ID).astype(int)
sw["occupancy_rate"] = (sw.patients_admitted / sw.available_beds).round(4)
sw["refusal_rate"] = (sw.patients_refused / sw.patients_request.replace(0, pd.NA)).astype(float).round(4)
sw["demand_pressure"] = (sw.patients_request / sw.available_beds).round(4)
sw["event_label"] = sw.event.map(EVENTOS).fillna("Sin evento")
sw["is_critical_week"] = ((sw.refusal_rate > 0.50) & (sw.occupancy_rate >= 0.90)).astype(int)

fact_service_weekly = (
    sw[["week", "service_id", "available_beds", "patients_request", "patients_admitted",
        "patients_refused", "patient_satisfaction", "staff_morale", "event", "event_label",
        "occupancy_rate", "refusal_rate", "demand_pressure",
        "flag_over_capacity", "is_critical_week"]]
    .rename(columns={"week": "week_id"})
    .sort_values(["week_id", "service_id"]).reset_index(drop=True)
)

fact_service_weekly.insert(0, "service_week_id", range(1, len(fact_service_weekly) + 1))

# dim_week se deriva del propio archivo (mapa semana -> mes que usa el hospital)
dim_week = (
    sw[["week", "month"]].drop_duplicates()
    .sort_values("week").reset_index(drop=True)
)
dim_week["month_name"] = dim_week.month.map(MESES_ES)
dim_week["month_short"] = dim_week.month_name.str[:3]
dim_week["quarter"] = ((dim_week.month - 1) // 3 + 1).astype(int)
dim_week["quarter_label"] = "Q" + dim_week["quarter"].astype(str)
dim_week["week_label"] = "S" + dim_week.week.astype(str).str.zfill(2)
dim_week["year_month"] = f"{ANIO_OPERATIVO}-" + dim_week.month.astype(str).str.zfill(2)
dim_week = dim_week.rename(columns={"week": "week_id"})

print(f"  fact_service_weekly: {len(fact_service_weekly)} filas | dim_week: {len(dim_week)} filas")


# ------------------------------------------------------------------------------
# 5. PATIENTS -> dim_patient + fact_admissions
# ------------------------------------------------------------------------------

print("\n" + "=" * 90)
print("4) TRANSFORM - patients")
print("=" * 90)

pa = raw_patients.copy()

pa["patient_id"] = limpiar_texto(pa["patient_id"]).str.upper()
pa["name"] = limpiar_texto(pa["name"]).str.title()
pa["age"] = pd.to_numeric(pa["age"], errors="coerce").astype("Int64")
pa["satisfaction"] = pd.to_numeric(pa["satisfaction"], errors="coerce").astype("Int64")
pa["arrival_date"] = pd.to_datetime(pa["arrival_date"], errors="coerce")
pa["departure_date"] = pd.to_datetime(pa["departure_date"], errors="coerce")
pa["service_name"] = canonizar_servicio(pa["service"])

log_dq("patients", "patient_id nulo", pa.patient_id.isna().sum(), "Se descarta la fila")
pa = pa[pa.patient_id.notna()].copy()

dups = pa.duplicated(subset=["patient_id"]).sum()
log_dq("patients", "patient_id duplicado", dups, "Se conserva el primer registro")
pa = pa.drop_duplicates(subset=["patient_id"], keep="first").copy()

log_dq("patients", "Fecha de ingreso o egreso inválida",
       pa[["arrival_date", "departure_date"]].isna().any(axis=1).sum(), "Se descarta la fila")
pa = pa.dropna(subset=["arrival_date", "departure_date"]).copy()

log_dq("patients", "Egreso anterior al ingreso", (pa.departure_date < pa.arrival_date).sum(),
       "Se descarta la fila")
pa = pa[pa.departure_date >= pa.arrival_date].copy()

log_dq("patients", "Edad fuera del rango 0-120", (~pa.age.between(0, 120)).sum(), "Se descarta la fila")
pa = pa[pa.age.between(0, 120)].copy()

log_dq("patients", "Satisfacción fuera del rango 0-100",
       (~pa.satisfaction.between(0, 100)).sum(), "Se descarta la fila")
pa = pa[pa.satisfaction.between(0, 100)].copy()

log_dq("patients", "Servicio no reconocido", pa.service_name.isna().sum(), "Se descarta la fila")
pa = pa[pa.service_name.notna()].copy()

# Derivadas
pa["service_id"] = pa.service_name.map(MAP_SERVICE_ID).astype(int)
pa["length_of_stay"] = (pa.departure_date - pa.arrival_date).dt.days.astype(int)
pa["arrival_week_id"] = semana_operativa(pa.arrival_date)
pa["arrival_month"] = pa.arrival_date.dt.month
pa["crosses_year"] = (pa.departure_date.dt.year != pa.arrival_date.dt.year).astype(int)

bins_edad = [-1, 12, 17, 39, 64, 120]
labels_edad = ["0-12 Pediatría", "13-17 Adolescente", "18-39 Adulto joven",
               "40-64 Adulto", "65+ Adulto mayor"]
pa["age_group"] = pd.cut(pa.age.astype(int), bins=bins_edad, labels=labels_edad).astype("string")

pa["satisfaction_band"] = pd.cut(
    pa.satisfaction.astype(int),
    bins=[-1, 69, 79, 89, 100],
    labels=["Crítico (<70)", "Bajo (70-79)", "Bueno (80-89)", "Excelente (90+)"],
).astype("string")

pa["stay_band"] = pd.cut(
    pa.length_of_stay,
    bins=[-1, 2, 6, 13, 10_000],
    labels=["Corta (0-2)", "Media (3-6)", "Larga (7-13)", "Prolongada (14+)"],
).astype("string")

dim_patient = (
    pa[["patient_id", "name", "age", "age_group"]]
    .rename(columns={"name": "patient_name"})
    .sort_values("patient_id").reset_index(drop=True)
)

fact_admissions = (
    pa[["patient_id", "service_id", "arrival_week_id", "arrival_date", "departure_date",
        "length_of_stay", "stay_band", "satisfaction", "satisfaction_band", "crosses_year"]]
    .sort_values(["arrival_date", "patient_id"]).reset_index(drop=True)
)
fact_admissions.insert(0, "admission_id", range(1, len(fact_admissions) + 1))

print(f"  dim_patient: {len(dim_patient)} filas | fact_admissions: {len(fact_admissions)} filas")


# ------------------------------------------------------------------------------
# 6. STAFF + STAFF_SCHEDULE -> dim_staff + fact_staff_attendance
# ------------------------------------------------------------------------------

print("\n" + "=" * 90)
print("5) TRANSFORM - staff y staff_schedule")
print("=" * 90)

# 6.1 dimension maestra de personal ---------------------------------------------
sf = raw_staff.copy()
sf["staff_id"] = limpiar_texto(sf["staff_id"]).str.upper()
sf["staff_name"] = limpiar_texto(sf["staff_name"]).str.title()
sf["role_name"] = canonizar_rol(sf["role"])
sf["service_name"] = canonizar_servicio(sf["service"])

log_dq("staff", "staff_id nulo", sf.staff_id.isna().sum(), "Se descarta la fila")
sf = sf[sf.staff_id.notna()].copy()

dups = sf.duplicated(subset=["staff_id"]).sum()
log_dq("staff", "staff_id duplicado", dups, "Se conserva el primer registro")
sf = sf.drop_duplicates(subset=["staff_id"], keep="first").copy()

log_dq("staff", "Rol o servicio no reconocido",
       sf[["role_name", "service_name"]].isna().any(axis=1).sum(), "Se descarta la fila")
sf = sf.dropna(subset=["role_name", "service_name"]).copy()

dups_nombre = sf.staff_name.duplicated().sum()
log_dq("staff", "Nombre repetido (clave natural del cruce)", dups_nombre,
       "Se conserva el primero para poder reconciliar la agenda")
sf = sf.drop_duplicates(subset=["staff_name"], keep="first").copy()

sf["role_id"] = sf.role_name.map(MAP_ROLE_ID).astype(int)
sf["service_id"] = sf.service_name.map(MAP_SERVICE_ID).astype(int)

dim_staff = sf[["staff_id", "staff_name", "role_id", "role_name", "service_id"]].copy()
dim_staff["role_label"] = dim_staff.role_name.map({k: v[1] for k, v in ROLES.items()})
dim_staff = dim_staff[["staff_id", "staff_name", "role_id", "role_name", "role_label", "service_id"]]
dim_staff = dim_staff.sort_values(["service_id", "role_id", "staff_name"]).reset_index(drop=True)

# 6.2 agenda semanal -------------------------------------------------------------
# PROBLEMA DETECTADO: staff_schedule.staff_id NO coincide con ningun staff_id de
# staff.csv (0 coincidencias sobre 6.552 filas). Ademas rol y servicio de la agenda
# contradicen al maestro en varios casos.
# DECISION: se reconstruye la clave foranea usando staff_name como clave natural y
# se toman rol y servicio SIEMPRE del maestro. Lo que no matchea va a cuarentena.

sc = raw_sched.copy()
sc["week_id"] = pd.to_numeric(sc["week"], errors="coerce").astype("Int64")
sc["present"] = pd.to_numeric(sc["present"], errors="coerce").astype("Int64")
sc["staff_name"] = limpiar_texto(sc["staff_name"]).str.title()
sc["staff_id_origen"] = limpiar_texto(sc["staff_id"]).str.upper()
sc["role_origen"] = canonizar_rol(sc["role"])
sc["service_origen"] = canonizar_servicio(sc["service"])

ids_rotos = (~sc.staff_id_origen.isin(dim_staff.staff_id)).sum()
log_dq("staff_schedule", "staff_id inexistente en el maestro", ids_rotos,
       "Se re-mapea la FK por staff_name")

log_dq("staff_schedule", "Semana fuera del rango 1-52",
       (~sc.week_id.between(1, 52)).sum(), "Se descarta la fila")
sc = sc[sc.week_id.between(1, 52)].copy()

log_dq("staff_schedule", "present distinto de 0/1", (~sc.present.isin([0, 1])).sum(),
       "Se descarta la fila")
sc = sc[sc.present.isin([0, 1])].copy()

dups = sc.duplicated(subset=["week_id", "staff_name"]).sum()
log_dq("staff_schedule", "Duplicados por (semana, agente)", dups, "Se conserva la última ocurrencia")
sc = sc.drop_duplicates(subset=["week_id", "staff_name"], keep="last").copy()

# Se descartan las columnas crudas para que el merge no colisione con el maestro
sc = sc[["week_id", "staff_name", "staff_id_origen", "role_origen", "service_origen", "present"]]

sc = sc.merge(
    dim_staff[["staff_id", "staff_name", "role_name", "service_id"]],
    on="staff_name", how="left",
)

huerfanos = sc[sc.staff_id.isna()].copy()
log_dq("staff_schedule", "Agente sin correspondencia en el maestro", len(huerfanos),
       "Va al archivo de cuarentena rejects_staff_schedule.csv")

conflicto_rol = ((sc.staff_id.notna()) & (sc.role_origen != sc.role_name)).sum()
log_dq("staff_schedule", "Rol de la agenda distinto al del maestro", conflicto_rol,
       "Prevalece el maestro (dim_staff)")

conflicto_serv = ((sc.staff_id.notna()) & (sc.service_origen.map(MAP_SERVICE_ID) != sc.service_id)).sum()
log_dq("staff_schedule", "Servicio de la agenda distinto al del maestro", conflicto_serv,
       "Prevalece el maestro (dim_staff)")

rejects_staff_schedule = huerfanos[[
    "week_id", "staff_id_origen", "staff_name", "role_origen", "service_origen", "present"
]].rename(columns={
    "staff_id_origen": "staff_id_archivo",
    "role_origen": "role_archivo",
    "service_origen": "service_archivo",
}).reset_index(drop=True)
rejects_staff_schedule["motivo_rechazo"] = "staff_name inexistente en staff.csv"

sc_ok = sc[sc.staff_id.notna()].copy()

fact_staff_attendance = (
    sc_ok[["week_id", "staff_id", "service_id", "present"]]
    .assign(present=lambda d: d.present.astype(int),
            service_id=lambda d: d.service_id.astype(int))
    .sort_values(["week_id", "staff_id"]).reset_index(drop=True)
)
fact_staff_attendance.insert(0, "attendance_id", range(1, len(fact_staff_attendance) + 1))
fact_staff_attendance["absent"] = 1 - fact_staff_attendance.present

# ANOMALIA DETECTADA: hay semanas donde el hospital entero figura con present = 0
# (las 110 personas, en los 4 servicios). Se repite cada 3 semanas, o sea que es un
# patron del sistema de origen y no ausentismo real. Se marcan para poder excluirlas
# del analisis de ausentismo sin borrar el dato.
presencia_semanal = fact_staff_attendance.groupby("week_id").present.mean()
semanas_sin_registro = sorted(presencia_semanal[presencia_semanal == 0].index.tolist())

log_dq("staff_schedule", "Semana con el 100% del plantel ausente", len(semanas_sin_registro),
       "Se marca has_attendance_record = 0 en dim_week")

fact_staff_attendance["has_attendance_record"] = (
    ~fact_staff_attendance.week_id.isin(semanas_sin_registro)
).astype(int)

dim_week["has_attendance_record"] = (~dim_week.week_id.isin(semanas_sin_registro)).astype(int)

print(f"  Semanas sin registro de presencia: {semanas_sin_registro}")
print(f"  Ausentismo real (excluyendo esas semanas): "
      f"{100 * fact_staff_attendance.loc[fact_staff_attendance.has_attendance_record == 1, 'absent'].mean():.2f}%")

print(f"  dim_staff: {len(dim_staff)} filas | fact_staff_attendance: {len(fact_staff_attendance)} filas"
      f" | cuarentena: {len(rejects_staff_schedule)} filas")


# ------------------------------------------------------------------------------
# 7. DIM_CALENDAR
# ------------------------------------------------------------------------------

print("\n" + "=" * 90)
print("6) TRANSFORM - calendario")
print("=" * 90)

fecha_min = fact_admissions.arrival_date.min()
fecha_max = fact_admissions.departure_date.max()
rango = pd.date_range(
    start=pd.Timestamp(year=fecha_min.year, month=1, day=1),
    end=pd.Timestamp(year=fecha_max.year, month=12, day=31),
    freq="D",
)

dim_calendar = pd.DataFrame({"date": rango})
dim_calendar["date_id"] = dim_calendar.date.dt.strftime("%Y%m%d").astype(int)
dim_calendar["year"] = dim_calendar.date.dt.year
dim_calendar["month"] = dim_calendar.date.dt.month
dim_calendar["month_name"] = dim_calendar.month.map(MESES_ES)
dim_calendar["month_short"] = dim_calendar.month_name.str[:3]
dim_calendar["year_month"] = dim_calendar.date.dt.strftime("%Y-%m")
dim_calendar["quarter"] = dim_calendar.date.dt.quarter
dim_calendar["quarter_label"] = "Q" + dim_calendar["quarter"].astype(str)
dim_calendar["day"] = dim_calendar.date.dt.day
dim_calendar["day_of_week"] = dim_calendar.date.dt.dayofweek + 1
dim_calendar["day_name"] = dim_calendar.day_of_week.map(
    {1: "Lunes", 2: "Martes", 3: "Miércoles", 4: "Jueves", 5: "Viernes", 6: "Sábado", 7: "Domingo"}
)
dim_calendar["is_weekend"] = dim_calendar.day_of_week.isin([6, 7]).astype(int)
dim_calendar["week_id"] = np.where(
    dim_calendar.year == ANIO_OPERATIVO, semana_operativa(dim_calendar.date), pd.NA
)
dim_calendar["date"] = dim_calendar.date.dt.strftime("%Y-%m-%d")
dim_calendar = dim_calendar[[
    "date_id", "date", "year", "quarter", "quarter_label", "month", "month_name",
    "month_short", "year_month", "day", "day_of_week", "day_name", "is_weekend", "week_id",
]]

print(f"  dim_calendar: {len(dim_calendar)} filas ({dim_calendar.date.min()} a {dim_calendar.date.max()})")


# ------------------------------------------------------------------------------
# 8. VALIDACIONES DE INTEGRIDAD DEL MODELO
# ------------------------------------------------------------------------------

print("\n" + "=" * 90)
print("7) VALIDACIÓN DE INTEGRIDAD REFERENCIAL")
print("=" * 90)

log_dq("fact_admissions", "FK service_id huérfana",
       (~fact_admissions.service_id.isin(dim_service.service_id)).sum(), "Bloqueante")
log_dq("fact_admissions", "FK patient_id huérfana",
       (~fact_admissions.patient_id.isin(dim_patient.patient_id)).sum(), "Bloqueante")
log_dq("fact_admissions", "FK week_id huérfana",
       (~fact_admissions.arrival_week_id.isin(dim_week.week_id)).sum(), "Bloqueante")
log_dq("fact_service_weekly", "FK service_id huérfana",
       (~fact_service_weekly.service_id.isin(dim_service.service_id)).sum(), "Bloqueante")
log_dq("fact_service_weekly", "FK week_id huérfana",
       (~fact_service_weekly.week_id.isin(dim_week.week_id)).sum(), "Bloqueante")
log_dq("fact_staff_attendance", "FK staff_id huérfana",
       (~fact_staff_attendance.staff_id.isin(dim_staff.staff_id)).sum(), "Bloqueante")
log_dq("fact_staff_attendance", "FK week_id huérfana",
       (~fact_staff_attendance.week_id.isin(dim_week.week_id)).sum(), "Bloqueante")

dq_report = pd.DataFrame(DQ_LOG)


# ------------------------------------------------------------------------------
# 9. LOAD - escritura de los CSV limpios
# ------------------------------------------------------------------------------

print("\n" + "=" * 90)
print("8) LOAD - escritura de archivos limpios")
print("=" * 90)

salidas = {
    "dim_calendar.csv": dim_calendar,
    "dim_week.csv": dim_week,
    "dim_service.csv": dim_service,
    "dim_role.csv": dim_role,
    "dim_staff.csv": dim_staff,
    "dim_patient.csv": dim_patient,
    "fact_admissions.csv": fact_admissions,
    "fact_service_weekly.csv": fact_service_weekly,
    "fact_staff_attendance.csv": fact_staff_attendance,
    "rejects_staff_schedule.csv": rejects_staff_schedule,
    "dq_report.csv": dq_report,
}

for archivo, df in salidas.items():
    ruta = os.path.join(CLEAN_DIR, archivo)
    df.to_csv(ruta, index=False, encoding="utf-8-sig")
    print(f"  {archivo:<32} {len(df):>6} filas -> {ruta}")

print("\n" + "=" * 90)
print("RESUMEN DE CALIDAD DE DATOS")
print("=" * 90)
print(dq_report[dq_report.filas_afectadas > 0].to_string(index=False))

print("\nETL finalizado sin errores.")

# ------------------------------------------------------------------------------
# 10. DESCARGA (solo Google Colab) - descomentar para bajar todo en un zip
# ------------------------------------------------------------------------------
# import shutil
# from google.colab import files
# shutil.make_archive("/content/hospital_clean", "zip", CLEAN_DIR)
# files.download("/content/hospital_clean.zip")

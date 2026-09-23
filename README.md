# Análisis operativo de un hospital

Proyecto de análisis de datos de punta a punta sobre la operación de un hospital durante 2025:
limpieza en Python, modelo dimensional en SQL Server y un tablero en Power BI.

Arranqué con cuatro CSV sueltos que no cruzaban entre sí y terminé con un modelo estrella de seis
dimensiones y tres tablas de hechos. La parte interesante del proyecto no fue el tablero, fue
darme cuenta de que uno de los archivos estaba roto y decidir qué hacer con eso.

![Dashboard de Hospital-Operations-Analytics](hospital_dashboard_background.png)


## Qué hay en los datos

| Archivo | Filas | Grano | Qué trae |
|---|---|---|---|
| `patients.csv` | 1.000 | Una internación | Fechas de ingreso y egreso, edad, servicio, satisfacción |
| `services_weekly.csv` | 208 | Semana × servicio | Camas, solicitudes, admisiones, rechazos, moral, eventos externos |
| `staff.csv` | 110 | Un agente | Rol y servicio de cada persona |
| `staff_schedule.csv` | 6.552 | Semana × agente | Presencia semanal durante 52 semanas |

## Los tres problemas que aparecieron

**Las claves del personal no cruzaban.** Cero coincidencias entre `staff_schedule.staff_id` y
`staff.staff_id` sobre 6.552 filas. Los identificadores estaban generados de forma independiente
en cada archivo. Reconstruí la clave foránea usando el nombre como clave natural, que sí cruza
para 110 de las 126 personas de la agenda.

**Hay 16 personas en la agenda que no existen en el maestro.** Al mirarlas de cerca resultó que
sus nombres son los primeros 16 nombres del archivo de pacientes, todas cargadas como enfermeras
o auxiliares de UTI. Es contaminación del generador de datos. Las 832 filas correspondientes van
a `rejects_staff_schedule.csv` en lugar de desaparecer sin dejar rastro.

**Hay 17 semanas con el hospital entero ausente.** Las semanas 3, 6, 9 y así hasta la 51, o sea
una de cada tres, tienen a las 110 personas con `present = 0`. Es un patrón del sistema de origen,
no ausentismo real. Si no se filtran, el ausentismo del año da 40 %. Filtrándolas da 10,8 %, que
es un número creíble para un hospital. Preferí marcarlas con una bandera antes que borrarlas,
así el dato original queda trazable y la decisión queda a la vista.

También encontré que rol y servicio de la agenda contradicen al maestro en 3.744 y 1.924 filas
respectivamente. Ahí la regla fue simple: la agenda es un hecho, el maestro es la dimensión, gana
el maestro.

## Lo que salió del análisis

El hospital rechazó el 56,6 % de las solicitudes de ingreso del año. No es un problema de
personal, es un problema de camas.

- **Guardia es el cuello de botella.** Concentra el 46 % de la demanda y rechaza al 80,9 % de
  quien golpea la puerta. La ocupación de sus camas fue del 100 % todo el año. En UTI, con la
  misma dotación relativa, el rechazo es del 17,9 %.
- **Los brotes de gripe duplican el rechazo.** Las semanas con brote promedian 65,7 % de rechazo
  contra 31,9 % de las semanas normales, y la demanda promedio pasa de 56 a 161 solicitudes.
- **Los paros pegan en el clima, no en la capacidad.** La moral cae 19,4 puntos, pero el rechazo
  baja porque la demanda también cae. Es el único evento que mejora la satisfacción reportada.
- **El ausentismo no explica los rechazos.** Partí el año en cuartiles de ausentismo semanal y la
  tasa de rechazo no sigue ninguna tendencia: 26 %, 42,8 %, 36,5 %, 32,1 %. La nube de dispersión
  es plana. Lo que predice el rechazo es la presión de demanda sobre las camas disponibles.
- **Diciembre concentró el 19 % de la demanda anual.** Las solicitudes crecieron 147 % contra
  noviembre. En el mapa de calor mensual se ve como una franja roja al final del año.

## Cómo está armado

```
CSV crudos  →  ETL en Python  →  CSV limpios  →  SQL Server  →  Power BI
                                       ↓
                              dq_report.csv + cuarentena
```

El ETL corre en Google Colab sin instalar nada. Lee los cuatro archivos, ejecuta 31 controles de
calidad, arma el modelo estrella y escribe once CSV. Cada control queda registrado en
`dq_report.csv` con la cantidad de filas afectadas y la decisión tomada, así que el proceso se
puede auditar sin leer el código.

El modelo dimensional tiene tres tablas de hechos con granos distintos que comparten dimensiones:
internaciones a nivel paciente, operación a nivel semana por servicio, y asistencia a nivel
semana por agente. Las dos dimensiones de tiempo (`dim_calendar` diaria y `dim_week` operativa)
están deliberadamente desconectadas entre sí para no armar un ciclo en el modelo.

## Cómo correrlo

**El ETL**

```bash
pip install pandas numpy
python etl/etl_hospital.py
```

En Colab: subir los cuatro CSV crudos a `/content`, pegar el script en una celda y ejecutar. Al
final hay un bloque comentado que descarga todo en un zip.

**La base**

Ejecutar en SSMS, en orden:

1. `sql/01_schema.sql` crea la base, el esquema `dw`, las once tablas, las claves foráneas, los
   índices y las restricciones de negocio.
2. `sql/02_load.sql` carga los CSV limpios con `BULK INSERT`. Hay que ajustar la ruta de la
   carpeta. Si el servicio de SQL Server no tiene permiso sobre esa carpeta, el asistente de
   importación de archivos planos hace lo mismo.
3. `sql/03_analysis.sql` tiene las diez consultas del análisis. Cada bloque es independiente.

Las consultas usan funciones de ventana en serio, no de adorno: `LAG` para la variación mensual,
`NTILE` para los cuartiles de ausentismo, `DENSE_RANK` para el ranking de semanas críticas y
frames `ROWS BETWEEN` para la media móvil de cuatro semanas y el acumulado.

**El tablero**

`powerbi/hospital_dashboard.pbix` levanta los CSV de `data/processed`. Si se mueven de lugar hay
que actualizar la ruta en Transformar datos → Configuración del origen de datos.

## Decisiones que tomé y por qué

Podría haber cruzado las cuatro tablas por servicio y armar una sola tabla ancha. No lo hice
porque los granos son incompatibles: 1.000 internaciones no tienen nada que ver con 5.851
admisiones semanales, y mezclarlas produce números que parecen correctos y no lo son. El modelo
estrella con dimensiones compartidas mantiene cada hecho en su grano y deja que las medidas
resuelvan el cruce.

Las bandas de edad, de estadía y de satisfacción están calculadas en el ETL y no en DAX. Son
reglas de negocio estables y prefiero que vivan en un solo lugar, versionado, en vez de repetirlas
en cada medida.

El campo `event` está a nivel semana por servicio, no a nivel semana. Tardé un rato en darme
cuenta, y cambia el análisis: una misma semana puede tener brote de gripe en Cirugía y nada en
Guardia.

## Limitaciones

Los datos son sintéticos y se nota en algunos lugares. La satisfacción del archivo de pacientes
no correlaciona con la del archivo semanal, la moral del equipo se mueve casi al azar, y no hay
forma de reconciliar las 5.851 admisiones semanales con las 1.000 internaciones individuales.
El análisis trata cada tabla de hechos por separado y evita conclusiones que crucen esos dos
mundos.

Tampoco hay costos, ni diagnósticos, ni reingresos, que es lo que uno querría para hablar en
serio de eficiencia hospitalaria. Lo que hay alcanza para un análisis de capacidad y de flujo.

## Stack

Python 3.11 con pandas y numpy · SQL Server 2019 · Power BI Desktop · Google Colab

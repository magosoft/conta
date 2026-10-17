-- =============================================================================
-- Contabilidad · 004 · Reportes
-- -----------------------------------------------------------------------------
-- libro_diario, libro_mayor, balance_sumas_saldos, balance_general,
-- estado_resultados y asientos_descuadrados (control).
--
-- Se calculan sobre los asientos (no anulados), así sirven también para meses
-- abiertos. Los importes por nivel acumulan las cuentas inferiores.
--
-- Requiere 001 a 003. PostgreSQL 9.5 o superior. Estado: PROPUESTA, NO APLICADA.
-- =============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION contabilidad.libro_diario(p_desde date, p_hasta date, p_incluir_anulados boolean DEFAULT false)
RETURNS TABLE (
    fecha_contable         date,
    gestion                smallint,
    periodo                smallint,
    numero_asiento         integer,
    id_asiento             bigint,
    tipo_documento         varchar,
    modulo                 varchar,
    glosa_asiento          text,
    estado                 varchar,
    numero_linea           integer,
    codigo_cuenta          varchar,
    nombre_cuenta          varchar,
    codigo_unidad_negocio  smallint,
    codigo_centro_costo    smallint,
    glosa_linea            text,
    debe_bs                numeric,
    haber_bs               numeric,
    debe_usd               numeric,
    haber_usd              numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = contabilidad, pg_temp
AS $$
    SELECT v.fecha_contable, v.gestion, v.periodo, v.numero_asiento, v.id_asiento, t.nombre, m.nombre, v.glosa_asiento, v.estado,
           v.numero_linea, v.codigo_cuenta, v.nombre_cuenta, v.codigo_unidad_negocio, v.codigo_centro_costo, v.glosa_linea,
           v.debe_bs, v.haber_bs, v.debe_usd, v.haber_usd
    FROM v_asiento_detalle v
    JOIN tipo_documento t ON t.codigo_tipo_documento = v.codigo_tipo_documento
    JOIN modulo_origen m ON m.codigo_modulo = v.codigo_modulo
    WHERE v.fecha_contable BETWEEN p_desde AND p_hasta
      AND (p_incluir_anulados OR v.estado <> 'ANULADO')
    ORDER BY v.fecha_contable, v.periodo, v.numero_asiento, v.numero_linea;
$$;
COMMENT ON FUNCTION contabilidad.libro_diario(date, date, boolean) IS 'Libro diario: asientos y líneas entre dos fechas, con debe y haber en Bs y USD';

CREATE OR REPLACE FUNCTION contabilidad.libro_mayor(
    p_codigo_cuenta          text,
    p_desde                  date,
    p_hasta                  date,
    p_codigo_unidad_negocio  integer DEFAULT NULL)
RETURNS TABLE (
    fecha_contable   date,
    periodo          smallint,
    numero_asiento   integer,
    numero_linea     integer,
    id_asiento       bigint,
    codigo_cuenta    varchar,
    glosa            text,
    debe_bs          numeric,
    haber_bs         numeric,
    saldo_bs         numeric,
    debe_usd         numeric,
    haber_usd        numeric,
    saldo_usd        numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = contabilidad, pg_temp
AS $$
    WITH gestion_consulta AS (
        SELECT g.gestion FROM gestion g WHERE p_desde BETWEEN g.fecha_inicio AND g.fecha_fin
    ), cuentas AS (
        SELECT x.codigo_cuenta FROM v_cuenta_contable_ancestro x WHERE x.codigo_cuenta_ancestro = p_codigo_cuenta
    ), lineas AS (
        SELECT v.*
        FROM v_asiento_detalle v
        JOIN gestion_consulta gc ON gc.gestion = v.gestion
        WHERE v.codigo_cuenta IN (SELECT c.codigo_cuenta FROM cuentas c)
          AND v.estado <> 'ANULADO'
          AND v.fecha_contable <= p_hasta
          AND (p_codigo_unidad_negocio IS NULL OR v.codigo_unidad_negocio = p_codigo_unidad_negocio)
    ), anterior AS (
        SELECT coalesce(sum(l.importe_bs) FILTER (WHERE l.fecha_contable < p_desde), 0) AS saldo_bs,
               coalesce(sum(l.importe_usd) FILTER (WHERE l.fecha_contable < p_desde), 0) AS saldo_usd
        FROM gestion_consulta gc
        LEFT JOIN lineas l ON true
    )
    SELECT NULL::date, NULL::smallint, NULL::integer, NULL::integer, NULL::bigint, p_codigo_cuenta::varchar, 'SALDO ANTERIOR'::text,
           NULL::numeric, NULL::numeric, an.saldo_bs, NULL::numeric, NULL::numeric, an.saldo_usd
    FROM anterior an
    UNION ALL
    SELECT l.fecha_contable, l.periodo, l.numero_asiento, l.numero_linea, l.id_asiento, l.codigo_cuenta,
           coalesce(l.glosa_linea, l.glosa_asiento),
           l.debe_bs, l.haber_bs, an.saldo_bs + sum(l.importe_bs) OVER w,
           l.debe_usd, l.haber_usd, an.saldo_usd + sum(l.importe_usd) OVER w
    FROM lineas l
    CROSS JOIN anterior an
    WHERE l.fecha_contable >= p_desde
    WINDOW w AS (ORDER BY l.fecha_contable, l.periodo, l.numero_asiento, l.numero_linea ROWS UNBOUNDED PRECEDING)
    ORDER BY 1 NULLS FIRST, 2, 3, 4;
$$;
COMMENT ON FUNCTION contabilidad.libro_mayor(text, date, date, integer) IS
'Libro mayor de una cuenta (si no es imputable, de todas sus subcuentas) dentro de la gestión de p_desde: saldo anterior y movimientos con saldo acumulado';

CREATE OR REPLACE FUNCTION contabilidad.balance_sumas_saldos(
    p_gestion                integer,
    p_periodo_hasta          integer DEFAULT 12,
    p_codigo_unidad_negocio  integer DEFAULT NULL,
    p_nivel_maximo           integer DEFAULT NULL)
RETURNS TABLE (
    codigo_cuenta        varchar,
    nombre_cuenta        varchar,
    nivel                smallint,
    es_imputable         boolean,
    debe_bs              numeric,
    haber_bs             numeric,
    saldo_deudor_bs      numeric,
    saldo_acreedor_bs    numeric,
    debe_usd             numeric,
    haber_usd            numeric,
    saldo_deudor_usd     numeric,
    saldo_acreedor_usd   numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = contabilidad, pg_temp
AS $$
    WITH movimiento AS (
        SELECT d.codigo_cuenta,
               sum(greatest(d.importe_bs, 0)) AS debe_bs, sum(greatest(-d.importe_bs, 0)) AS haber_bs,
               sum(greatest(d.importe_usd, 0)) AS debe_usd, sum(greatest(-d.importe_usd, 0)) AS haber_usd
        FROM asiento a
        JOIN asiento_detalle d ON d.id_asiento = a.id_asiento
        WHERE a.gestion = p_gestion
          AND a.periodo <= p_periodo_hasta
          AND a.estado <> 'ANULADO'
          AND (p_codigo_unidad_negocio IS NULL OR d.codigo_unidad_negocio = p_codigo_unidad_negocio)
        GROUP BY d.codigo_cuenta
    ), acumulado AS (
        SELECT x.codigo_cuenta_ancestro AS codigo_cuenta,
               sum(m.debe_bs) AS debe_bs, sum(m.haber_bs) AS haber_bs,
               sum(m.debe_usd) AS debe_usd, sum(m.haber_usd) AS haber_usd
        FROM movimiento m
        JOIN v_cuenta_contable_ancestro x ON x.codigo_cuenta = m.codigo_cuenta
        GROUP BY x.codigo_cuenta_ancestro
    )
    SELECT c.codigo_cuenta, c.nombre, c.nivel, c.es_imputable,
           ac.debe_bs, ac.haber_bs, greatest(ac.debe_bs - ac.haber_bs, 0), greatest(ac.haber_bs - ac.debe_bs, 0),
           ac.debe_usd, ac.haber_usd, greatest(ac.debe_usd - ac.haber_usd, 0), greatest(ac.haber_usd - ac.debe_usd, 0)
    FROM acumulado ac
    JOIN cuenta_contable c ON c.codigo_cuenta = ac.codigo_cuenta
    WHERE p_nivel_maximo IS NULL OR c.nivel <= p_nivel_maximo
    ORDER BY c.codigo_cuenta;
$$;
COMMENT ON FUNCTION contabilidad.balance_sumas_saldos(integer, integer, integer, integer) IS
'Balance de comprobación de sumas y saldos de la gestión hasta un período (0 a 13), por cuenta y nivel. En el nivel 1 la suma del debe es igual a la del haber';

CREATE OR REPLACE FUNCTION contabilidad.balance_general(
    p_gestion                integer,
    p_periodo_hasta          integer DEFAULT 12,
    p_codigo_unidad_negocio  integer DEFAULT NULL,
    p_nivel_maximo           integer DEFAULT NULL)
RETURNS TABLE (
    naturaleza      varchar,
    codigo_cuenta   varchar,
    nombre_cuenta   varchar,
    nivel           smallint,
    saldo_bs        numeric,
    saldo_usd       numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = contabilidad, pg_temp
AS $$
    WITH saldo AS (
        SELECT d.codigo_cuenta, sum(d.importe_bs) AS saldo_bs, sum(d.importe_usd) AS saldo_usd
        FROM asiento a
        JOIN asiento_detalle d ON d.id_asiento = a.id_asiento
        WHERE a.gestion = p_gestion
          AND a.periodo <= p_periodo_hasta
          AND a.estado <> 'ANULADO'
          AND (p_codigo_unidad_negocio IS NULL OR d.codigo_unidad_negocio = p_codigo_unidad_negocio)
        GROUP BY d.codigo_cuenta
    ), acumulado AS (
        SELECT x.codigo_cuenta_ancestro AS codigo_cuenta, sum(s.saldo_bs) AS saldo_bs, sum(s.saldo_usd) AS saldo_usd
        FROM saldo s
        JOIN v_cuenta_contable_ancestro x ON x.codigo_cuenta = s.codigo_cuenta
        GROUP BY x.codigo_cuenta_ancestro
    ), resultado_abierto AS (
        -- Resultado de las cuentas de ingreso y gasto que todavía no se cerraron
        SELECT -sum(s.saldo_bs) AS saldo_bs, -sum(s.saldo_usd) AS saldo_usd
        FROM saldo s
        JOIN cuenta_contable c ON c.codigo_cuenta = s.codigo_cuenta
        JOIN grupo_cuenta gr ON gr.codigo_grupo = c.codigo_grupo
        WHERE gr.es_cuenta_resultado
    )
    SELECT x.naturaleza, x.codigo_cuenta, x.nombre_cuenta, x.nivel, x.saldo_bs, x.saldo_usd
    FROM (
        SELECT gr.naturaleza, c.codigo_cuenta, c.nombre AS nombre_cuenta, c.nivel,
               CASE WHEN gr.saldo_normal = 'DEUDOR' THEN ac.saldo_bs ELSE -ac.saldo_bs END AS saldo_bs,
               CASE WHEN gr.saldo_normal = 'DEUDOR' THEN ac.saldo_usd ELSE -ac.saldo_usd END AS saldo_usd,
               CASE gr.naturaleza WHEN 'ACTIVO' THEN 1 WHEN 'PASIVO' THEN 2 ELSE 3 END AS orden
        FROM acumulado ac
        JOIN cuenta_contable c ON c.codigo_cuenta = ac.codigo_cuenta
        JOIN grupo_cuenta gr ON gr.codigo_grupo = c.codigo_grupo
        WHERE gr.naturaleza IN ('ACTIVO', 'PASIVO', 'PATRIMONIO')
          AND (p_nivel_maximo IS NULL OR c.nivel <= p_nivel_maximo)
          AND (ac.saldo_bs <> 0 OR ac.saldo_usd <> 0)
        UNION ALL
        SELECT 'PATRIMONIO'::varchar, NULL::varchar, 'RESULTADO DE LA GESTION SIN CERRAR'::varchar, 1::smallint, r.saldo_bs, r.saldo_usd, 4
        FROM resultado_abierto r
        WHERE r.saldo_bs <> 0 OR r.saldo_usd <> 0
    ) x
    ORDER BY x.orden, x.codigo_cuenta;
$$;
COMMENT ON FUNCTION contabilidad.balance_general(integer, integer, integer, integer) IS
'Balance general: activo, pasivo y patrimonio con su saldo normal en positivo. Si las cuentas de resultado no están cerradas, su resultado aparece como RESULTADO DE LA GESTION SIN CERRAR';

CREATE OR REPLACE FUNCTION contabilidad.estado_resultados(
    p_gestion                integer,
    p_periodo_desde          integer DEFAULT 1,
    p_periodo_hasta          integer DEFAULT 12,
    p_codigo_unidad_negocio  integer DEFAULT NULL,
    p_nivel_maximo           integer DEFAULT NULL)
RETURNS TABLE (
    naturaleza      varchar,
    codigo_cuenta   varchar,
    nombre_cuenta   varchar,
    nivel           smallint,
    importe_bs      numeric,
    importe_usd     numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = contabilidad, pg_temp
AS $$
    WITH movimiento AS (
        -- Sin el período 13: el asiento de cierre deja las cuentas de resultado en cero
        SELECT d.codigo_cuenta, sum(d.importe_bs) AS importe_bs, sum(d.importe_usd) AS importe_usd
        FROM asiento a
        JOIN asiento_detalle d ON d.id_asiento = a.id_asiento
        JOIN cuenta_contable c ON c.codigo_cuenta = d.codigo_cuenta
        JOIN grupo_cuenta gr ON gr.codigo_grupo = c.codigo_grupo
        WHERE a.gestion = p_gestion
          AND a.periodo BETWEEN p_periodo_desde AND least(p_periodo_hasta, 12)
          AND a.estado <> 'ANULADO'
          AND gr.es_cuenta_resultado
          AND (p_codigo_unidad_negocio IS NULL OR d.codigo_unidad_negocio = p_codigo_unidad_negocio)
        GROUP BY d.codigo_cuenta
    ), acumulado AS (
        SELECT x.codigo_cuenta_ancestro AS codigo_cuenta, sum(m.importe_bs) AS importe_bs, sum(m.importe_usd) AS importe_usd
        FROM movimiento m
        JOIN v_cuenta_contable_ancestro x ON x.codigo_cuenta = m.codigo_cuenta
        GROUP BY x.codigo_cuenta_ancestro
    )
    SELECT y.naturaleza, y.codigo_cuenta, y.nombre_cuenta, y.nivel, y.importe_bs, y.importe_usd
    FROM (
        SELECT gr.naturaleza, c.codigo_cuenta, c.nombre AS nombre_cuenta, c.nivel,
               CASE WHEN gr.naturaleza = 'INGRESO' THEN -ac.importe_bs ELSE ac.importe_bs END AS importe_bs,
               CASE WHEN gr.naturaleza = 'INGRESO' THEN -ac.importe_usd ELSE ac.importe_usd END AS importe_usd,
               CASE WHEN gr.naturaleza = 'INGRESO' THEN 1 ELSE 2 END AS orden
        FROM acumulado ac
        JOIN cuenta_contable c ON c.codigo_cuenta = ac.codigo_cuenta
        JOIN grupo_cuenta gr ON gr.codigo_grupo = c.codigo_grupo
        WHERE p_nivel_maximo IS NULL OR c.nivel <= p_nivel_maximo
        UNION ALL
        SELECT 'RESULTADO'::varchar, NULL::varchar, 'RESULTADO DEL PERIODO (INGRESOS - GASTOS)'::varchar, NULL::smallint,
               -coalesce(sum(m.importe_bs), 0), -coalesce(sum(m.importe_usd), 0), 3
        FROM movimiento m
    ) y
    ORDER BY y.orden, y.codigo_cuenta;
$$;
COMMENT ON FUNCTION contabilidad.estado_resultados(integer, integer, integer, integer, integer) IS
'Estado de resultados entre dos meses: ingresos y gastos en positivo y el resultado del período (positivo = utilidad)';

CREATE OR REPLACE FUNCTION contabilidad.asientos_descuadrados(p_gestion integer DEFAULT NULL)
RETURNS TABLE (
    id_asiento       bigint,
    gestion          smallint,
    periodo          smallint,
    numero_asiento   integer,
    fecha_contable   date,
    origen           varchar,
    diferencia_bs    numeric,
    diferencia_usd   numeric)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = contabilidad, pg_temp
AS $$
    SELECT a.id_asiento, a.gestion, a.periodo, a.numero_asiento, a.fecha_contable, a.origen,
           sum(d.importe_bs), sum(d.importe_usd)
    FROM asiento a
    JOIN asiento_detalle d ON d.id_asiento = a.id_asiento
    WHERE a.estado <> 'ANULADO'
      AND (p_gestion IS NULL OR a.gestion = p_gestion)
    GROUP BY a.id_asiento, a.gestion, a.periodo, a.numero_asiento, a.fecha_contable, a.origen
    HAVING sum(d.importe_bs) <> 0 OR sum(d.importe_usd) <> 0
    ORDER BY a.gestion, a.numero_asiento;
$$;
COMMENT ON FUNCTION contabilidad.asientos_descuadrados(integer) IS
'Control: asientos vigentes cuya suma no da cero. Solo puede haber migrados del SAI; hay que corregirlos antes del cierre anual porque la apertura no cuadraría';

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA contabilidad FROM PUBLIC;

COMMIT;

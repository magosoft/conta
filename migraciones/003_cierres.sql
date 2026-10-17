-- =============================================================================
-- Contabilidad · 003 · Calendario y cierres diario, mensual y anual
-- -----------------------------------------------------------------------------
-- crear_gestion            gestión con sus períodos 0 (apertura), 1-12 y 13 (cierre)
-- cerrar_dia               contabiliza la interfaz del día, controla el cuadre,
--                          calcula el saldo diario y bloquea el día
-- cerrar_dias_pendientes   cierra en orden los días abiertos hasta una fecha (proceso nocturno)
-- cerrar_periodo           exige los días cerrados, revalúa la moneda extranjera
--                          (opcional), calcula el saldo mensual y bloquea el mes
-- cerrar_gestion           cierra las cuentas de resultado contra el resultado de
--                          la gestión y genera la apertura de la gestión siguiente
-- reabrir_dia / reabrir_periodo / reabrir_gestion   deshacen cada cierre con motivo
--
-- Todos los cierres quedan en contabilidad.bitacora_cierre. Dos cierres de la
-- misma gestión no corren a la vez (pg_advisory_xact_lock).
--
-- Requiere 001 y 002. PostgreSQL 9.5 o superior. Estado: PROPUESTA, NO APLICADA.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Auxiliares
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.bloquear_cierres(p_gestion integer)
RETURNS void
LANGUAGE sql
AS $$
    SELECT pg_advisory_xact_lock(hashtext('contabilidad.cierre'), p_gestion);
$$;
COMMENT ON FUNCTION contabilidad.bloquear_cierres(integer) IS 'Serializa los cierres y reaperturas de una gestión hasta el fin de la transacción';

CREATE OR REPLACE FUNCTION contabilidad.registrar_bitacora_cierre(
    p_tipo_cierre     text,
    p_accion          text,
    p_gestion         integer,
    p_periodo         integer,
    p_fecha_contable  date,
    p_motivo          text,
    p_resultado       jsonb,
    p_usuario         text)
RETURNS void
LANGUAGE sql
AS $$
    INSERT INTO contabilidad.bitacora_cierre (tipo_cierre, accion, gestion, periodo, fecha_contable, motivo, resultado, usuario)
    VALUES (p_tipo_cierre, p_accion, p_gestion, p_periodo, p_fecha_contable, p_motivo, p_resultado, p_usuario);
$$;

CREATE OR REPLACE FUNCTION contabilidad.exigir_motivo(p_motivo text)
RETURNS void
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
    IF p_motivo IS NULL OR length(btrim(p_motivo)) < 5 THEN
        RAISE EXCEPTION 'Indique el motivo de la reapertura (al menos 5 caracteres)';
    END IF;
END;
$$;

-- -----------------------------------------------------------------------------
-- Gestión
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.crear_gestion(
    p_gestion                            integer,
    p_usuario                            text,
    p_codigo_cuenta_resultado            text DEFAULT NULL,
    p_codigo_cuenta_resultado_acumulado  text DEFAULT NULL,
    p_codigo_cuenta_redondeo             text DEFAULT NULL,
    p_codigo_cuenta_diferencia_cambio    text DEFAULT NULL,
    p_mes_inicio                         integer DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = contabilidad, pg_temp
AS $$
DECLARE
    c_meses     CONSTANT text[] := ARRAY['ENERO', 'FEBRERO', 'MARZO', 'ABRIL', 'MAYO', 'JUNIO', 'JULIO',
                                         'AGOSTO', 'SEPTIEMBRE', 'OCTUBRE', 'NOVIEMBRE', 'DICIEMBRE'];
    v_anterior  gestion%ROWTYPE;
    v_mes       integer;
    v_inicio    date;
    v_fin       date;
BEGIN
    IF EXISTS (SELECT 1 FROM gestion g WHERE g.gestion = p_gestion) THEN
        RAISE EXCEPTION 'La gestión % ya existe', p_gestion;
    END IF;

    -- Los parámetros que no se indican se copian de la gestión anterior
    SELECT * INTO v_anterior FROM gestion g WHERE g.gestion = p_gestion - 1;
    v_mes := coalesce(p_mes_inicio, extract(month FROM v_anterior.fecha_inicio)::integer, 1);
    IF v_mes NOT BETWEEN 1 AND 12 THEN
        RAISE EXCEPTION 'p_mes_inicio tiene que estar entre 1 y 12';
    END IF;
    -- Gestión calendario (enero a diciembre) o fiscal que termina en el año p_gestion
    v_inicio := CASE WHEN v_mes = 1 THEN make_date(p_gestion, 1, 1) ELSE make_date(p_gestion - 1, v_mes, 1) END;
    v_fin := (v_inicio + interval '1 year' - interval '1 day')::date;

    IF coalesce(p_codigo_cuenta_resultado, v_anterior.codigo_cuenta_resultado) IS NULL
       OR coalesce(p_codigo_cuenta_resultado_acumulado, v_anterior.codigo_cuenta_resultado_acumulado) IS NULL THEN
        RAISE EXCEPTION 'Indique las cuentas de resultado y de resultados acumulados (no hay gestión % para copiarlas)', p_gestion - 1;
    END IF;

    INSERT INTO gestion (gestion, fecha_inicio, fecha_fin, codigo_cuenta_resultado, codigo_cuenta_resultado_acumulado,
                         codigo_cuenta_redondeo, codigo_cuenta_diferencia_cambio, codigo_centro_costo_defecto,
                         revaluar_moneda_extranjera, tolerancia_redondeo, exigir_cierre_dias_en_orden, usuario_creacion)
    VALUES (p_gestion, v_inicio, v_fin,
            coalesce(p_codigo_cuenta_resultado, v_anterior.codigo_cuenta_resultado),
            coalesce(p_codigo_cuenta_resultado_acumulado, v_anterior.codigo_cuenta_resultado_acumulado),
            coalesce(p_codigo_cuenta_redondeo, v_anterior.codigo_cuenta_redondeo),
            coalesce(p_codigo_cuenta_diferencia_cambio, v_anterior.codigo_cuenta_diferencia_cambio),
            coalesce(v_anterior.codigo_centro_costo_defecto, 0),
            coalesce(v_anterior.revaluar_moneda_extranjera, false),
            coalesce(v_anterior.tolerancia_redondeo, 0.80),
            coalesce(v_anterior.exigir_cierre_dias_en_orden, true),
            p_usuario);

    INSERT INTO periodo_contable (gestion, periodo, nombre, fecha_inicio, fecha_fin)
    SELECT p_gestion, 0, 'APERTURA', v_inicio, v_inicio
    UNION ALL
    SELECT p_gestion, m.numero,
           format('%s %s', c_meses[extract(month FROM m.inicio)::integer], extract(year FROM m.inicio)),
           m.inicio, (m.inicio + interval '1 month' - interval '1 day')::date
    FROM (SELECT n AS numero, (v_inicio + (n - 1) * interval '1 month')::date AS inicio FROM generate_series(1, 12) n) m
    UNION ALL
    SELECT p_gestion, 13, 'CIERRE', v_fin, v_fin;

    INSERT INTO correlativo_asiento (gestion, ultimo_numero) VALUES (p_gestion, 0);
END;
$$;
COMMENT ON FUNCTION contabilidad.crear_gestion(integer, text, text, text, text, text, integer) IS
'Crea la gestión con sus 14 períodos (0 apertura, 1-12, 13 cierre). Las cuentas y opciones que no se indican se copian de la gestión anterior. p_mes_inicio <> 1: gestión fiscal que termina en el año p_gestion';

-- -----------------------------------------------------------------------------
-- Saldos
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.calcular_saldo_diario(p_fecha_contable date)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_filas integer;
BEGIN
    DELETE FROM contabilidad.saldo_diario s WHERE s.fecha_contable = p_fecha_contable;

    INSERT INTO contabilidad.saldo_diario (fecha_contable, codigo_cuenta, codigo_unidad_negocio, codigo_centro_costo,
                                           debe_bs, haber_bs, debe_usd, haber_usd, cantidad_lineas)
    SELECT a.fecha_contable, d.codigo_cuenta, d.codigo_unidad_negocio, d.codigo_centro_costo,
           sum(greatest(d.importe_bs, 0)), sum(greatest(-d.importe_bs, 0)),
           sum(greatest(d.importe_usd, 0)), sum(greatest(-d.importe_usd, 0)),
           count(*)
    FROM contabilidad.asiento a
    JOIN contabilidad.asiento_detalle d ON d.id_asiento = a.id_asiento
    WHERE a.fecha_contable = p_fecha_contable
      AND a.periodo BETWEEN 1 AND 12
      AND a.estado <> 'ANULADO'
    GROUP BY a.fecha_contable, d.codigo_cuenta, d.codigo_unidad_negocio, d.codigo_centro_costo;

    GET DIAGNOSTICS v_filas = ROW_COUNT;

    UPDATE contabilidad.dia_contable dc
    SET cantidad_asientos = (SELECT count(*) FROM contabilidad.asiento a
                             WHERE a.fecha_contable = p_fecha_contable AND a.periodo BETWEEN 1 AND 12 AND a.estado <> 'ANULADO'),
        total_debe_bs = (SELECT coalesce(sum(s.debe_bs), 0) FROM contabilidad.saldo_diario s WHERE s.fecha_contable = p_fecha_contable),
        total_debe_usd = (SELECT coalesce(sum(s.debe_usd), 0) FROM contabilidad.saldo_diario s WHERE s.fecha_contable = p_fecha_contable)
    WHERE dc.fecha_contable = p_fecha_contable;

    RETURN v_filas;
END;
$$;
COMMENT ON FUNCTION contabilidad.calcular_saldo_diario(date) IS 'Recalcula el movimiento del día (meses 1 a 12, sin anulados) y los totales de control del día';

CREATE OR REPLACE FUNCTION contabilidad.calcular_saldo_mensual(p_gestion integer, p_periodo integer)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_filas integer;
BEGIN
    DELETE FROM contabilidad.saldo_mensual s WHERE s.gestion = p_gestion AND s.periodo = p_periodo;

    -- El saldo inicial se acumula desde el período 0 de la gestión: no depende de que los meses anteriores tengan su saldo guardado
    WITH movimiento AS (
        SELECT d.codigo_cuenta, d.codigo_unidad_negocio, d.codigo_centro_costo,
               sum(CASE WHEN a.periodo < p_periodo THEN d.importe_bs ELSE 0 END) AS saldo_inicial_bs,
               sum(CASE WHEN a.periodo = p_periodo THEN greatest(d.importe_bs, 0) ELSE 0 END) AS debe_bs,
               sum(CASE WHEN a.periodo = p_periodo THEN greatest(-d.importe_bs, 0) ELSE 0 END) AS haber_bs,
               sum(CASE WHEN a.periodo < p_periodo THEN d.importe_usd ELSE 0 END) AS saldo_inicial_usd,
               sum(CASE WHEN a.periodo = p_periodo THEN greatest(d.importe_usd, 0) ELSE 0 END) AS debe_usd,
               sum(CASE WHEN a.periodo = p_periodo THEN greatest(-d.importe_usd, 0) ELSE 0 END) AS haber_usd
        FROM contabilidad.asiento a
        JOIN contabilidad.asiento_detalle d ON d.id_asiento = a.id_asiento
        WHERE a.gestion = p_gestion
          AND a.periodo <= p_periodo
          AND a.estado <> 'ANULADO'
        GROUP BY d.codigo_cuenta, d.codigo_unidad_negocio, d.codigo_centro_costo
    )
    INSERT INTO contabilidad.saldo_mensual (gestion, periodo, codigo_cuenta, codigo_unidad_negocio, codigo_centro_costo,
                                            saldo_inicial_bs, debe_bs, haber_bs, saldo_final_bs,
                                            saldo_inicial_usd, debe_usd, haber_usd, saldo_final_usd)
    SELECT p_gestion, p_periodo, m.codigo_cuenta, m.codigo_unidad_negocio, m.codigo_centro_costo,
           m.saldo_inicial_bs, m.debe_bs, m.haber_bs, m.saldo_inicial_bs + m.debe_bs - m.haber_bs,
           m.saldo_inicial_usd, m.debe_usd, m.haber_usd, m.saldo_inicial_usd + m.debe_usd - m.haber_usd
    FROM movimiento m
    WHERE m.saldo_inicial_bs <> 0 OR m.debe_bs <> 0 OR m.haber_bs <> 0
       OR m.saldo_inicial_usd <> 0 OR m.debe_usd <> 0 OR m.haber_usd <> 0;

    GET DIAGNOSTICS v_filas = ROW_COUNT;
    RETURN v_filas;
END;
$$;
COMMENT ON FUNCTION contabilidad.calcular_saldo_mensual(integer, integer) IS 'Recalcula el saldo del período por cuenta, unidad y centro: inicial acumulado desde la apertura, debe, haber y final';

CREATE OR REPLACE FUNCTION contabilidad.recalcular_saldos_gestion(p_gestion integer)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = contabilidad, pg_temp
AS $$
DECLARE
    v_periodo    integer;
    v_cantidad   integer := 0;
BEGIN
    FOR v_periodo IN
        SELECT p.periodo FROM periodo_contable p WHERE p.gestion = p_gestion AND p.estado = 'CERRADO' ORDER BY p.periodo
    LOOP
        PERFORM calcular_saldo_mensual(p_gestion, v_periodo);
        v_cantidad := v_cantidad + 1;
    END LOOP;
    RETURN v_cantidad;
END;
$$;
COMMENT ON FUNCTION contabilidad.recalcular_saldos_gestion(integer) IS 'Recalcula el saldo mensual de todos los períodos cerrados de la gestión (después de generar o anular una apertura). Devuelve cuántos períodos recalculó';

-- -----------------------------------------------------------------------------
-- Cierre diario
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.cerrar_dia(
    p_fecha_contable          date,
    p_usuario                 text,
    p_contabilizar_interfaz   boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = contabilidad, pg_temp
AS $$
DECLARE
    v_gestion           gestion%ROWTYPE;
    v_numero_gestion    integer;
    v_periodo           integer;
    v_dia               dia_contable%ROWTYPE;
    v_fecha_pendiente   date;
    v_documento         record;
    v_contabilizados    integer := 0;
    v_con_error         integer := 0;
    v_lineas_pendientes integer;
    v_descuadrados      text;
    v_resultado         jsonb;
BEGIN
    SELECT f.gestion, f.periodo INTO v_numero_gestion, v_periodo FROM periodo_de_fecha(p_fecha_contable) f;
    PERFORM bloquear_cierres(v_numero_gestion);
    SELECT * INTO v_gestion FROM gestion g WHERE g.gestion = v_numero_gestion;

    IF v_gestion.estado = 'CERRADA' THEN
        RAISE EXCEPTION 'La gestión % está cerrada', v_numero_gestion;
    END IF;
    IF EXISTS (SELECT 1 FROM periodo_contable p WHERE p.gestion = v_numero_gestion AND p.periodo = v_periodo AND p.estado = 'CERRADO') THEN
        RAISE EXCEPTION 'El período % de la gestión % ya está cerrado', v_periodo, v_numero_gestion;
    END IF;

    INSERT INTO dia_contable (fecha_contable, gestion, periodo) VALUES (p_fecha_contable, v_numero_gestion, v_periodo)
    ON CONFLICT (fecha_contable) DO NOTHING;
    SELECT * INTO v_dia FROM dia_contable d WHERE d.fecha_contable = p_fecha_contable FOR UPDATE;
    IF v_dia.estado = 'CERRADO' THEN
        RAISE EXCEPTION 'El día % ya está cerrado', p_fecha_contable;
    END IF;

    -- Orden: no quedan días anteriores de la gestión abiertos ni con interfaz pendiente
    IF v_gestion.exigir_cierre_dias_en_orden THEN
        SELECT min(x.fecha) INTO v_fecha_pendiente
        FROM (SELECT d.fecha_contable AS fecha FROM dia_contable d
              WHERE d.gestion = v_numero_gestion AND d.fecha_contable < p_fecha_contable AND d.estado = 'ABIERTO'
              UNION ALL
              SELECT i.fecha_contable FROM interfaz_comprobante i
              WHERE i.fecha_contable BETWEEN v_gestion.fecha_inicio AND p_fecha_contable - 1
                AND i.estado IN ('PENDIENTE', 'ERROR')) x;
        IF v_fecha_pendiente IS NOT NULL THEN
            RAISE EXCEPTION 'Primero cierre el día % (los días se cierran en orden)', v_fecha_pendiente
                USING HINT = 'contabilidad.cerrar_dias_pendientes cierra en orden todos los días hasta una fecha';
        END IF;
    END IF;

    -- 1. Contabilizar lo que dejaron los módulos
    IF p_contabilizar_interfaz THEN
        FOR v_documento IN SELECT * FROM contabilizar_interfaz(p_fecha_contable, p_usuario) LOOP
            IF v_documento.estado = 'CONTABILIZADO' THEN
                v_contabilizados := v_contabilizados + 1;
            ELSE
                v_con_error := v_con_error + 1;
            END IF;
        END LOOP;
    END IF;

    SELECT count(*) INTO v_lineas_pendientes
    FROM interfaz_comprobante i
    WHERE i.fecha_contable = p_fecha_contable AND i.estado IN ('PENDIENTE', 'ERROR');

    IF v_lineas_pendientes > 0 THEN
        -- No se lanza error: lo contabilizado y los mensajes de error quedan grabados para corregirlos
        RETURN jsonb_build_object(
            'fecha_contable', p_fecha_contable,
            'cerrado', false,
            'motivo', 'Hay líneas de interfaz pendientes o con error (ver interfaz_comprobante.mensaje_error)',
            'lineas_pendientes', v_lineas_pendientes,
            'documentos_contabilizados', v_contabilizados,
            'documentos_con_error', v_con_error);
    END IF;

    -- 2. Control de cuadre de todos los asientos del día
    SELECT string_agg(x.id_asiento::text, ', ') INTO v_descuadrados
    FROM (SELECT a.id_asiento
          FROM asiento a
          JOIN asiento_detalle d ON d.id_asiento = a.id_asiento
          WHERE a.fecha_contable = p_fecha_contable AND a.periodo BETWEEN 1 AND 12
            AND a.estado <> 'ANULADO' AND a.origen <> 'MIGRACION'
          GROUP BY a.id_asiento
          HAVING sum(d.importe_bs) <> 0 OR sum(d.importe_usd) <> 0) x;
    IF v_descuadrados IS NOT NULL THEN
        RAISE EXCEPTION 'El día % tiene asientos descuadrados: %', p_fecha_contable, v_descuadrados;
    END IF;

    -- 3. Saldo diario y bloqueo
    PERFORM calcular_saldo_diario(p_fecha_contable);
    UPDATE dia_contable
    SET estado = 'CERRADO', usuario_cierre = p_usuario, fecha_cierre = now()
    WHERE fecha_contable = p_fecha_contable
    RETURNING jsonb_build_object(
        'fecha_contable', fecha_contable,
        'cerrado', true,
        'asientos', cantidad_asientos,
        'total_debe_bs', total_debe_bs,
        'total_debe_usd', total_debe_usd,
        'documentos_contabilizados', v_contabilizados)
    INTO v_resultado;

    PERFORM registrar_bitacora_cierre('DIA', 'CIERRE', v_numero_gestion, v_periodo, p_fecha_contable, NULL, v_resultado, p_usuario);
    RETURN v_resultado;
END;
$$;
COMMENT ON FUNCTION contabilidad.cerrar_dia(date, text, boolean) IS
'Cierre diario: contabiliza la interfaz del día, controla el cuadre, calcula saldo_diario y bloquea el día. Si quedan líneas de interfaz con error devuelve cerrado = false sin deshacer lo contabilizado';

CREATE OR REPLACE FUNCTION contabilidad.reabrir_dia(p_fecha_contable date, p_usuario text, p_motivo text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = contabilidad, pg_temp
AS $$
DECLARE
    v_dia dia_contable%ROWTYPE;
BEGIN
    PERFORM exigir_motivo(p_motivo);
    SELECT * INTO v_dia FROM dia_contable d WHERE d.fecha_contable = p_fecha_contable;
    IF NOT FOUND OR v_dia.estado <> 'CERRADO' THEN
        RAISE EXCEPTION 'El día % no está cerrado', p_fecha_contable;
    END IF;
    PERFORM bloquear_cierres(v_dia.gestion);
    SELECT * INTO v_dia FROM dia_contable d WHERE d.fecha_contable = p_fecha_contable FOR UPDATE;

    IF EXISTS (SELECT 1 FROM gestion g WHERE g.gestion = v_dia.gestion AND g.estado = 'CERRADA')
       OR EXISTS (SELECT 1 FROM periodo_contable p WHERE p.gestion = v_dia.gestion AND p.periodo = v_dia.periodo AND p.estado = 'CERRADO') THEN
        RAISE EXCEPTION 'El período % de la gestión % está cerrado: reábralo antes de reabrir el día', v_dia.periodo, v_dia.gestion;
    END IF;

    DELETE FROM saldo_diario s WHERE s.fecha_contable = p_fecha_contable;
    UPDATE dia_contable
    SET estado = 'ABIERTO', usuario_cierre = NULL, fecha_cierre = NULL,
        cantidad_asientos = NULL, total_debe_bs = NULL, total_debe_usd = NULL
    WHERE fecha_contable = p_fecha_contable;

    PERFORM registrar_bitacora_cierre('DIA', 'REAPERTURA', v_dia.gestion, v_dia.periodo, p_fecha_contable, p_motivo, NULL, p_usuario);
END;
$$;
COMMENT ON FUNCTION contabilidad.reabrir_dia(date, text, text) IS 'Reabre un día cerrado de un período abierto (borra su saldo diario y deja constancia del motivo)';

CREATE OR REPLACE FUNCTION contabilidad.cerrar_dias_pendientes(p_hasta date, p_usuario text)
RETURNS TABLE (fecha_contable date, resultado jsonb)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = contabilidad, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_fecha      date;
    v_resultado  jsonb;
    v_mensaje    text;
BEGIN
    FOR v_fecha IN
        SELECT x.fecha
        FROM (SELECT d.fecha_contable AS fecha
              FROM dia_contable d
              JOIN periodo_contable p ON p.gestion = d.gestion AND p.periodo = d.periodo
              JOIN gestion g ON g.gestion = d.gestion
              WHERE d.estado = 'ABIERTO' AND d.fecha_contable <= p_hasta
                AND p.estado = 'ABIERTO' AND g.estado = 'ABIERTA'
              UNION
              SELECT i.fecha_contable
              FROM interfaz_comprobante i
              JOIN periodo_contable p ON p.periodo BETWEEN 1 AND 12 AND i.fecha_contable BETWEEN p.fecha_inicio AND p.fecha_fin
              JOIN gestion g ON g.gestion = p.gestion
              WHERE i.estado IN ('PENDIENTE', 'ERROR') AND i.fecha_contable <= p_hasta
                AND p.estado = 'ABIERTO' AND g.estado = 'ABIERTA') x
        ORDER BY x.fecha
    LOOP
        BEGIN
            v_resultado := cerrar_dia(v_fecha, p_usuario, true);
        EXCEPTION
            WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS v_mensaje = MESSAGE_TEXT;
                v_resultado := jsonb_build_object('fecha_contable', v_fecha, 'cerrado', false, 'motivo', v_mensaje);
        END;
        fecha_contable := v_fecha;
        resultado := v_resultado;
        RETURN NEXT;
        -- Se detiene en el primer día que no cierra: los siguientes dependen de él
        EXIT WHEN NOT (v_resultado->>'cerrado')::boolean;
    END LOOP;
END;
$$;
COMMENT ON FUNCTION contabilidad.cerrar_dias_pendientes(date, text) IS
'Proceso nocturno: cierra en orden los días abiertos (o con interfaz pendiente) hasta p_hasta y se detiene en el primero que no cierra. Ej.: SELECT * FROM contabilidad.cerrar_dias_pendientes(current_date - 1, ''etl'')';

-- -----------------------------------------------------------------------------
-- Cierre mensual
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.generar_revaluacion_moneda_extranjera(p_gestion integer, p_periodo integer, p_usuario text)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    v_gestion        contabilidad.gestion%ROWTYPE;
    v_periodo        contabilidad.periodo_contable%ROWTYPE;
    v_tipo_cambio    numeric;
    v_detalle        jsonb;
    v_id_asiento     bigint;
    v_valor_previo   boolean;
BEGIN
    SELECT * INTO v_gestion FROM contabilidad.gestion g WHERE g.gestion = p_gestion;
    SELECT * INTO v_periodo FROM contabilidad.periodo_contable p WHERE p.gestion = p_gestion AND p.periodo = p_periodo;
    IF v_gestion.codigo_cuenta_diferencia_cambio IS NULL THEN
        RAISE EXCEPTION 'La gestión % revalúa la moneda extranjera pero no tiene codigo_cuenta_diferencia_cambio', p_gestion;
    END IF;
    v_tipo_cambio := contabilidad.tipo_cambio_vigente(v_periodo.fecha_fin, 2);

    -- Cuentas de activo y pasivo en USD: el saldo en Bs tiene que ser el saldo en USD por el tipo de cambio de cierre
    WITH saldo AS (
        SELECT d.codigo_cuenta, d.codigo_unidad_negocio, d.codigo_centro_costo,
               sum(d.importe_bs) AS saldo_bs, sum(d.importe_usd) AS saldo_usd
        FROM contabilidad.asiento a
        JOIN contabilidad.asiento_detalle d ON d.id_asiento = a.id_asiento
        JOIN contabilidad.cuenta_contable c ON c.codigo_cuenta = d.codigo_cuenta
        JOIN contabilidad.grupo_cuenta gr ON gr.codigo_grupo = c.codigo_grupo
        WHERE a.gestion = p_gestion AND a.periodo <= p_periodo AND a.estado <> 'ANULADO'
          AND c.codigo_moneda = 2 AND gr.naturaleza IN ('ACTIVO', 'PASIVO')
        GROUP BY d.codigo_cuenta, d.codigo_unidad_negocio, d.codigo_centro_costo
    ), diferencia AS (
        SELECT s.*, round(s.saldo_usd * v_tipo_cambio, 2) - s.saldo_bs AS diferencia_bs
        FROM saldo s
        WHERE round(s.saldo_usd * v_tipo_cambio, 2) - s.saldo_bs <> 0
    ), linea AS (
        SELECT 1 AS orden, d.codigo_unidad_negocio, d.codigo_cuenta,
               jsonb_build_object('codigo_cuenta', d.codigo_cuenta, 'glosa', format('REVALUACION A TC %s', v_tipo_cambio),
                                  'importe_bs', d.diferencia_bs, 'importe_usd', 0, 'codigo_moneda', 2, 'tipo_cambio', v_tipo_cambio,
                                  'codigo_unidad_negocio', d.codigo_unidad_negocio, 'codigo_centro_costo', d.codigo_centro_costo) AS linea
        FROM diferencia d
        UNION ALL
        SELECT 2, d.codigo_unidad_negocio, v_gestion.codigo_cuenta_diferencia_cambio,
               jsonb_build_object('codigo_cuenta', v_gestion.codigo_cuenta_diferencia_cambio, 'glosa', 'DIFERENCIA DE CAMBIO',
                                  'importe_bs', -sum(d.diferencia_bs), 'importe_usd', 0, 'codigo_moneda', 1, 'tipo_cambio', v_tipo_cambio,
                                  'codigo_unidad_negocio', d.codigo_unidad_negocio, 'codigo_centro_costo', v_gestion.codigo_centro_costo_defecto)
        FROM diferencia d
        GROUP BY d.codigo_unidad_negocio
        HAVING sum(d.diferencia_bs) <> 0
    )
    SELECT jsonb_agg(l.linea ORDER BY l.codigo_unidad_negocio, l.orden, l.codigo_cuenta) INTO v_detalle FROM linea l;

    IF v_detalle IS NULL THEN
        RETURN NULL;
    END IF;

    -- Va al último día del mes, que normalmente ya está cerrado
    v_valor_previo := contabilidad.establecer_modificacion_cerrado(true);
    v_id_asiento := contabilidad.insertar_asiento(v_periodo.fecha_fin, p_gestion, p_periodo, 98, 2, NULL,
                                                  format('REVALUACION DE MONEDA EXTRANJERA AL %s (TC %s)', to_char(v_periodo.fecha_fin, 'DD/MM/YYYY'), v_tipo_cambio),
                                                  'SISTEMA', 'REVALUACION', NULL, 1, v_detalle, p_usuario);
    -- Se llama al cerrar el mes, con todos sus días cerrados: el último día queda cerrado con su saldo recalculado
    PERFORM contabilidad.calcular_saldo_diario(v_periodo.fecha_fin);
    UPDATE contabilidad.dia_contable d
    SET estado = 'CERRADO', usuario_cierre = p_usuario, fecha_cierre = now()
    WHERE d.fecha_contable = v_periodo.fecha_fin AND d.estado = 'ABIERTO';
    PERFORM contabilidad.establecer_modificacion_cerrado(v_valor_previo);
    RETURN v_id_asiento;
END;
$$;
COMMENT ON FUNCTION contabilidad.generar_revaluacion_moneda_extranjera(integer, integer, text) IS
'Ajusta el saldo en Bs de las cuentas de activo y pasivo en USD al tipo de cambio del último día del mes, contra la cuenta de diferencia de cambio. NULL si no hay diferencias';

CREATE OR REPLACE FUNCTION contabilidad.cerrar_periodo(p_gestion integer, p_periodo integer, p_usuario text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = contabilidad, pg_temp
AS $$
DECLARE
    v_gestion          gestion%ROWTYPE;
    v_periodo          periodo_contable%ROWTYPE;
    v_dias_abiertos    text;
    v_pendientes       integer;
    v_id_revaluacion   bigint;
    v_cuentas          integer;
    v_resultado        jsonb;
BEGIN
    IF p_periodo NOT BETWEEN 0 AND 12 THEN
        RAISE EXCEPTION 'El período 13 se cierra con contabilidad.cerrar_gestion';
    END IF;
    PERFORM bloquear_cierres(p_gestion);

    SELECT * INTO v_gestion FROM gestion g WHERE g.gestion = p_gestion;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe la gestión %', p_gestion;
    END IF;
    IF v_gestion.estado = 'CERRADA' THEN
        RAISE EXCEPTION 'La gestión % está cerrada', p_gestion;
    END IF;
    SELECT * INTO v_periodo FROM periodo_contable p WHERE p.gestion = p_gestion AND p.periodo = p_periodo FOR UPDATE;
    IF v_periodo.estado = 'CERRADO' THEN
        RAISE EXCEPTION 'El período % de la gestión % ya está cerrado', p_periodo, p_gestion;
    END IF;

    -- Los meses se cierran en orden (enero no espera a la apertura: el período 0 se cierra con la gestión anterior)
    IF p_periodo >= 2 AND EXISTS (SELECT 1 FROM periodo_contable p WHERE p.gestion = p_gestion AND p.periodo = p_periodo - 1 AND p.estado = 'ABIERTO') THEN
        RAISE EXCEPTION 'Primero cierre el período % de la gestión %', p_periodo - 1, p_gestion;
    END IF;

    IF p_periodo BETWEEN 1 AND 12 THEN
        SELECT string_agg(to_char(x.fecha_contable, 'DD/MM/YYYY'), ', ') INTO v_dias_abiertos
        FROM (SELECT d.fecha_contable FROM dia_contable d
              WHERE d.gestion = p_gestion AND d.periodo = p_periodo AND d.estado = 'ABIERTO'
              ORDER BY d.fecha_contable LIMIT 10) x;
        IF v_dias_abiertos IS NOT NULL THEN
            RAISE EXCEPTION 'El período % de la gestión % tiene días abiertos: %', p_periodo, p_gestion, v_dias_abiertos
                USING HINT = 'Ciérrelos con contabilidad.cerrar_dias_pendientes';
        END IF;

        SELECT count(*) INTO v_pendientes
        FROM interfaz_comprobante i
        WHERE i.fecha_contable BETWEEN v_periodo.fecha_inicio AND v_periodo.fecha_fin
          AND i.estado IN ('PENDIENTE', 'ERROR');
        IF v_pendientes > 0 THEN
            RAISE EXCEPTION 'El período % de la gestión % tiene % líneas de interfaz pendientes o con error', p_periodo, p_gestion, v_pendientes;
        END IF;

        IF v_gestion.revaluar_moneda_extranjera THEN
            v_id_revaluacion := generar_revaluacion_moneda_extranjera(p_gestion, p_periodo, p_usuario);
        END IF;
    END IF;

    v_cuentas := calcular_saldo_mensual(p_gestion, p_periodo);

    UPDATE periodo_contable
    SET estado = 'CERRADO', usuario_cierre = p_usuario, fecha_cierre = now()
    WHERE gestion = p_gestion AND periodo = p_periodo;

    SELECT jsonb_build_object(
               'gestion', p_gestion,
               'periodo', p_periodo,
               'cerrado', true,
               'filas_saldo', v_cuentas,
               'debe_bs', coalesce(sum(s.debe_bs), 0),
               'haber_bs', coalesce(sum(s.haber_bs), 0),
               'id_asiento_revaluacion', v_id_revaluacion)
    INTO v_resultado
    FROM saldo_mensual s
    WHERE s.gestion = p_gestion AND s.periodo = p_periodo;

    PERFORM registrar_bitacora_cierre('PERIODO', 'CIERRE', p_gestion, p_periodo, NULL, NULL, v_resultado, p_usuario);
    RETURN v_resultado;
END;
$$;
COMMENT ON FUNCTION contabilidad.cerrar_periodo(integer, integer, text) IS
'Cierre mensual: exige el mes anterior cerrado, todos los días cerrados y la interfaz contabilizada; revalúa la moneda extranjera si la gestión lo indica, calcula saldo_mensual y bloquea el mes';

CREATE OR REPLACE FUNCTION contabilidad.reabrir_periodo(p_gestion integer, p_periodo integer, p_usuario text, p_motivo text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = contabilidad, pg_temp
AS $$
DECLARE
    v_valor_previo   boolean;
    v_fecha          date;
BEGIN
    PERFORM exigir_motivo(p_motivo);
    IF p_periodo NOT BETWEEN 0 AND 12 THEN
        RAISE EXCEPTION 'El período 13 se reabre con contabilidad.reabrir_gestion';
    END IF;
    PERFORM bloquear_cierres(p_gestion);

    IF EXISTS (SELECT 1 FROM gestion g WHERE g.gestion = p_gestion AND g.estado = 'CERRADA') THEN
        RAISE EXCEPTION 'La gestión % está cerrada: reábrala con contabilidad.reabrir_gestion', p_gestion;
    END IF;
    PERFORM 1 FROM periodo_contable p WHERE p.gestion = p_gestion AND p.periodo = p_periodo AND p.estado = 'CERRADO' FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El período % de la gestión % no está cerrado', p_periodo, p_gestion;
    END IF;
    IF p_periodo BETWEEN 1 AND 11
       AND EXISTS (SELECT 1 FROM periodo_contable p WHERE p.gestion = p_gestion AND p.periodo = p_periodo + 1 AND p.estado = 'CERRADO') THEN
        RAISE EXCEPTION 'Primero reabra el período % de la gestión %', p_periodo + 1, p_gestion;
    END IF;

    -- La revaluación del mes se anula: se vuelve a generar al cerrar otra vez
    v_valor_previo := establecer_modificacion_cerrado(true);
    FOR v_fecha IN
        UPDATE asiento a
        SET estado = 'ANULADO', usuario_anulacion = p_usuario, fecha_anulacion = now(),
            motivo_anulacion = 'REAPERTURA DEL PERIODO: ' || p_motivo
        WHERE a.gestion = p_gestion AND a.periodo = p_periodo
          AND a.tipo_asiento_sistema = 'REVALUACION' AND a.estado = 'VIGENTE'
        RETURNING a.fecha_contable
    LOOP
        IF EXISTS (SELECT 1 FROM dia_contable d WHERE d.fecha_contable = v_fecha AND d.estado = 'CERRADO') THEN
            PERFORM calcular_saldo_diario(v_fecha);
        END IF;
    END LOOP;

    DELETE FROM saldo_mensual s WHERE s.gestion = p_gestion AND s.periodo = p_periodo;
    UPDATE periodo_contable
    SET estado = 'ABIERTO', usuario_cierre = NULL, fecha_cierre = NULL
    WHERE gestion = p_gestion AND periodo = p_periodo;
    PERFORM establecer_modificacion_cerrado(v_valor_previo);

    PERFORM registrar_bitacora_cierre('PERIODO', 'REAPERTURA', p_gestion, p_periodo, NULL, p_motivo, NULL, p_usuario);
END;
$$;
COMMENT ON FUNCTION contabilidad.reabrir_periodo(integer, integer, text, text) IS
'Reabre un mes cerrado (el siguiente tiene que estar abierto): anula su revaluación y borra su saldo mensual. Los días siguen cerrados; se reabren con reabrir_dia';

-- -----------------------------------------------------------------------------
-- Cierre anual
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.cerrar_gestion(
    p_gestion               integer,
    p_usuario               text,
    p_traspasar_resultado   boolean DEFAULT true)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = contabilidad, pg_temp
AS $$
DECLARE
    v_gestion            gestion%ROWTYPE;
    v_siguiente          gestion%ROWTYPE;
    v_abiertos           text;
    v_detalle            jsonb;
    v_id_cierre          bigint;
    v_id_apertura        bigint;
    v_resultado_bs       numeric := 0;
    v_resultado_usd      numeric := 0;
    v_resultado          jsonb;
BEGIN
    PERFORM bloquear_cierres(p_gestion);
    PERFORM bloquear_cierres(p_gestion + 1);

    SELECT * INTO v_gestion FROM gestion g WHERE g.gestion = p_gestion FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe la gestión %', p_gestion;
    END IF;
    IF v_gestion.estado = 'CERRADA' THEN
        RAISE EXCEPTION 'La gestión % ya está cerrada', p_gestion;
    END IF;

    SELECT string_agg(p.periodo::text, ', ' ORDER BY p.periodo) INTO v_abiertos
    FROM periodo_contable p
    WHERE p.gestion = p_gestion AND p.periodo BETWEEN 1 AND 12 AND p.estado = 'ABIERTO';
    IF v_abiertos IS NOT NULL THEN
        RAISE EXCEPTION 'La gestión % tiene períodos abiertos: %', p_gestion, v_abiertos;
    END IF;

    -- El período 0 de esta gestión (apertura) se cierra si quedó abierto
    IF EXISTS (SELECT 1 FROM periodo_contable p WHERE p.gestion = p_gestion AND p.periodo = 0 AND p.estado = 'ABIERTO') THEN
        PERFORM cerrar_periodo(p_gestion, 0, p_usuario);
    END IF;

    -- 1. Asiento de cierre (período 13): cada cuenta de resultado queda en cero contra el resultado de la gestión, por unidad de negocio
    WITH saldo AS (
        SELECT d.codigo_cuenta, d.codigo_unidad_negocio, d.codigo_centro_costo,
               sum(d.importe_bs) AS saldo_bs, sum(d.importe_usd) AS saldo_usd
        FROM asiento a
        JOIN asiento_detalle d ON d.id_asiento = a.id_asiento
        JOIN cuenta_contable c ON c.codigo_cuenta = d.codigo_cuenta
        JOIN grupo_cuenta gr ON gr.codigo_grupo = c.codigo_grupo
        WHERE a.gestion = p_gestion AND a.periodo BETWEEN 0 AND 12 AND a.estado <> 'ANULADO'
          AND gr.es_cuenta_resultado
        GROUP BY d.codigo_cuenta, d.codigo_unidad_negocio, d.codigo_centro_costo
        HAVING sum(d.importe_bs) <> 0 OR sum(d.importe_usd) <> 0
    ), linea AS (
        SELECT 1 AS orden, s.codigo_unidad_negocio, s.codigo_cuenta,
               jsonb_build_object('codigo_cuenta', s.codigo_cuenta, 'glosa', 'CIERRE DE RESULTADOS',
                                  'importe_bs', -s.saldo_bs, 'importe_usd', -s.saldo_usd, 'codigo_moneda', 1,
                                  'codigo_unidad_negocio', s.codigo_unidad_negocio, 'codigo_centro_costo', s.codigo_centro_costo) AS linea
        FROM saldo s
        UNION ALL
        SELECT 2, s.codigo_unidad_negocio, v_gestion.codigo_cuenta_resultado,
               jsonb_build_object('codigo_cuenta', v_gestion.codigo_cuenta_resultado, 'glosa', 'RESULTADO DE LA GESTION',
                                  'importe_bs', sum(s.saldo_bs), 'importe_usd', sum(s.saldo_usd), 'codigo_moneda', 1,
                                  'codigo_unidad_negocio', s.codigo_unidad_negocio, 'codigo_centro_costo', v_gestion.codigo_centro_costo_defecto)
        FROM saldo s
        GROUP BY s.codigo_unidad_negocio
        HAVING sum(s.saldo_bs) <> 0 OR sum(s.saldo_usd) <> 0
    )
    SELECT jsonb_agg(l.linea ORDER BY l.codigo_unidad_negocio, l.orden, l.codigo_cuenta) INTO v_detalle FROM linea l;

    IF v_detalle IS NOT NULL THEN
        v_id_cierre := insertar_asiento(v_gestion.fecha_fin, p_gestion, 13, 97, 2, NULL,
                                        format('CIERRE DE RESULTADOS DE LA GESTION %s', p_gestion),
                                        'SISTEMA', 'CIERRE', NULL, 1, v_detalle, p_usuario);
        -- Resultado positivo = utilidad (la cuenta de resultado queda acreedora)
        SELECT -coalesce(sum(d.importe_bs), 0), -coalesce(sum(d.importe_usd), 0) INTO v_resultado_bs, v_resultado_usd
        FROM asiento_detalle d
        WHERE d.id_asiento = v_id_cierre AND d.codigo_cuenta = v_gestion.codigo_cuenta_resultado;
    END IF;

    -- 2. Período 13: saldo final de la gestión
    PERFORM calcular_saldo_mensual(p_gestion, 13);
    UPDATE periodo_contable
    SET estado = 'CERRADO', usuario_cierre = p_usuario, fecha_cierre = now()
    WHERE gestion = p_gestion AND periodo = 13;

    -- 3. Foto del plan de cuentas (SAI: cnpch)
    DELETE FROM cuenta_contable_gestion x WHERE x.gestion = p_gestion;
    INSERT INTO cuenta_contable_gestion (gestion, codigo_cuenta, nombre, codigo_grupo, nivel, codigo_cuenta_padre, es_imputable,
                                         codigo_moneda, exige_centro_costo, codigo_tipo_auxiliar, activo)
    SELECT p_gestion, c.codigo_cuenta, c.nombre, c.codigo_grupo, c.nivel, c.codigo_cuenta_padre, c.es_imputable,
           c.codigo_moneda, c.exige_centro_costo, c.codigo_tipo_auxiliar, c.activo
    FROM cuenta_contable c;

    -- 4. Apertura de la gestión siguiente (período 0) con los saldos de balance y de orden
    IF NOT EXISTS (SELECT 1 FROM gestion g WHERE g.gestion = p_gestion + 1) THEN
        PERFORM crear_gestion(p_gestion + 1, p_usuario);
    END IF;
    SELECT * INTO v_siguiente FROM gestion g WHERE g.gestion = p_gestion + 1 FOR UPDATE;
    IF v_siguiente.estado = 'CERRADA' THEN
        RAISE EXCEPTION 'La gestión % está cerrada: no se puede generar su apertura', p_gestion + 1;
    END IF;
    IF EXISTS (SELECT 1 FROM periodo_contable p WHERE p.gestion = p_gestion + 1 AND p.periodo = 0 AND p.estado = 'CERRADO') THEN
        RAISE EXCEPTION 'El período 0 (apertura) de la gestión % está cerrado', p_gestion + 1
            USING HINT = 'Reábralo con contabilidad.reabrir_periodo para generar la apertura';
    END IF;

    WITH saldo AS (
        SELECT CASE WHEN p_traspasar_resultado AND s.codigo_cuenta = v_gestion.codigo_cuenta_resultado
                    THEN v_gestion.codigo_cuenta_resultado_acumulado ELSE s.codigo_cuenta END AS codigo_cuenta,
               s.codigo_unidad_negocio, s.codigo_centro_costo,
               sum(s.saldo_final_bs) AS saldo_bs, sum(s.saldo_final_usd) AS saldo_usd
        FROM saldo_mensual s
        JOIN cuenta_contable c ON c.codigo_cuenta = s.codigo_cuenta
        JOIN grupo_cuenta gr ON gr.codigo_grupo = c.codigo_grupo
        WHERE s.gestion = p_gestion AND s.periodo = 13 AND NOT gr.es_cuenta_resultado
        GROUP BY 1, 2, 3
        HAVING sum(s.saldo_final_bs) <> 0 OR sum(s.saldo_final_usd) <> 0
    )
    SELECT jsonb_agg(jsonb_build_object(
               'codigo_cuenta', s.codigo_cuenta, 'glosa', format('SALDO AL %s', to_char(v_gestion.fecha_fin, 'DD/MM/YYYY')),
               'importe_bs', s.saldo_bs, 'importe_usd', s.saldo_usd, 'codigo_moneda', coalesce(c.codigo_moneda, 1),
               'codigo_unidad_negocio', s.codigo_unidad_negocio, 'codigo_centro_costo', s.codigo_centro_costo)
           ORDER BY s.codigo_cuenta, s.codigo_unidad_negocio, s.codigo_centro_costo)
    INTO v_detalle
    FROM saldo s
    JOIN cuenta_contable c ON c.codigo_cuenta = s.codigo_cuenta;

    IF v_detalle IS NOT NULL THEN
        v_id_apertura := insertar_asiento(v_siguiente.fecha_inicio, p_gestion + 1, 0, 88, 2, NULL,
                                          format('APERTURA DE LA GESTION %s', p_gestion + 1),
                                          'SISTEMA', 'APERTURA', NULL, 1, v_detalle, p_usuario);
    END IF;

    -- La apertura queda cerrada y los meses ya cerrados de la gestión siguiente se recalculan con ella
    PERFORM calcular_saldo_mensual(p_gestion + 1, 0);
    UPDATE periodo_contable
    SET estado = 'CERRADO', usuario_cierre = p_usuario, fecha_cierre = now()
    WHERE gestion = p_gestion + 1 AND periodo = 0;
    PERFORM recalcular_saldos_gestion(p_gestion + 1);

    -- 5. Gestión cerrada
    UPDATE gestion SET estado = 'CERRADA', usuario_cierre = p_usuario, fecha_cierre = now() WHERE gestion = p_gestion;

    v_resultado := jsonb_build_object(
        'gestion', p_gestion,
        'cerrada', true,
        'resultado_bs', v_resultado_bs,
        'resultado_usd', v_resultado_usd,
        'id_asiento_cierre', v_id_cierre,
        'id_asiento_apertura', v_id_apertura,
        'gestion_siguiente', p_gestion + 1,
        'resultado_traspasado_a', CASE WHEN p_traspasar_resultado THEN v_gestion.codigo_cuenta_resultado_acumulado ELSE v_gestion.codigo_cuenta_resultado END);
    PERFORM registrar_bitacora_cierre('GESTION', 'CIERRE', p_gestion, NULL, NULL, NULL, v_resultado, p_usuario);
    RETURN v_resultado;
END;
$$;
COMMENT ON FUNCTION contabilidad.cerrar_gestion(integer, text, boolean) IS
'Cierre anual: exige los 12 meses cerrados; lleva las cuentas de resultado a cero contra la cuenta de resultado (asiento de cierre, período 13), guarda la foto del plan de cuentas '
'y genera la apertura de la gestión siguiente (período 0). Con p_traspasar_resultado el resultado abre en la cuenta de resultados acumulados';

CREATE OR REPLACE FUNCTION contabilidad.reabrir_gestion(p_gestion integer, p_usuario text, p_motivo text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = contabilidad, pg_temp
AS $$
DECLARE
    v_valor_previo boolean;
BEGIN
    PERFORM exigir_motivo(p_motivo);
    PERFORM bloquear_cierres(p_gestion);
    PERFORM bloquear_cierres(p_gestion + 1);

    PERFORM 1 FROM gestion g WHERE g.gestion = p_gestion AND g.estado = 'CERRADA' FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La gestión % no está cerrada', p_gestion;
    END IF;
    IF EXISTS (SELECT 1 FROM gestion g WHERE g.gestion = p_gestion + 1 AND g.estado = 'CERRADA') THEN
        RAISE EXCEPTION 'Primero reabra la gestión %', p_gestion + 1;
    END IF;

    v_valor_previo := establecer_modificacion_cerrado(true);

    -- Apertura de la gestión siguiente
    UPDATE asiento a
    SET estado = 'ANULADO', usuario_anulacion = p_usuario, fecha_anulacion = now(),
        motivo_anulacion = format('REAPERTURA DE LA GESTION %s: %s', p_gestion, p_motivo)
    WHERE a.gestion = p_gestion + 1 AND a.periodo = 0 AND a.tipo_asiento_sistema = 'APERTURA' AND a.estado = 'VIGENTE';
    DELETE FROM saldo_mensual s WHERE s.gestion = p_gestion + 1 AND s.periodo = 0;
    UPDATE periodo_contable
    SET estado = 'ABIERTO', usuario_cierre = NULL, fecha_cierre = NULL
    WHERE gestion = p_gestion + 1 AND periodo = 0 AND estado = 'CERRADO';
    PERFORM recalcular_saldos_gestion(p_gestion + 1);

    -- Cierre de esta gestión
    UPDATE asiento a
    SET estado = 'ANULADO', usuario_anulacion = p_usuario, fecha_anulacion = now(),
        motivo_anulacion = format('REAPERTURA DE LA GESTION %s: %s', p_gestion, p_motivo)
    WHERE a.gestion = p_gestion AND a.periodo = 13 AND a.tipo_asiento_sistema = 'CIERRE' AND a.estado = 'VIGENTE';
    DELETE FROM saldo_mensual s WHERE s.gestion = p_gestion AND s.periodo = 13;
    DELETE FROM cuenta_contable_gestion x WHERE x.gestion = p_gestion;
    UPDATE periodo_contable
    SET estado = 'ABIERTO', usuario_cierre = NULL, fecha_cierre = NULL
    WHERE gestion = p_gestion AND periodo = 13;
    UPDATE gestion SET estado = 'ABIERTA', usuario_cierre = NULL, fecha_cierre = NULL WHERE gestion = p_gestion;

    PERFORM establecer_modificacion_cerrado(v_valor_previo);
    PERFORM registrar_bitacora_cierre('GESTION', 'REAPERTURA', p_gestion, NULL, NULL, p_motivo, NULL, p_usuario);
END;
$$;
COMMENT ON FUNCTION contabilidad.reabrir_gestion(integer, text, text) IS
'Deshace el cierre anual: anula la apertura de la gestión siguiente y el asiento de cierre, y deja la gestión abierta con sus 12 meses cerrados (se reabren con reabrir_periodo)';

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA contabilidad FROM PUBLIC;

COMMIT;

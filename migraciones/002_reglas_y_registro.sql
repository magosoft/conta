-- =============================================================================
-- Contabilidad · 002 · Reglas de integridad y registro de asientos
-- -----------------------------------------------------------------------------
-- * Derivación del nivel y la cuenta padre en el plan de cuentas.
-- * Bloqueo de días, períodos y gestiones cerrados (triggers).
-- * Cuadre obligatorio de cada asiento (trigger de restricción diferido).
-- * registrar_asiento, anular_asiento y contabilizar_interfaz.
--
-- Las funciones que modifican datos son SECURITY DEFINER con search_path fijo:
-- los usuarios de la aplicación solo reciben EXECUTE (ver 005_permisos.sql)
-- y nunca escriben directo en las tablas de asientos.
--
-- Requiere 001. PostgreSQL 9.5 o superior. Estado: PROPUESTA, NO APLICADA.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- Autorización interna para tocar días o períodos cerrados
-- -----------------------------------------------------------------------------
-- Los cierres y la reversión necesitan escribir en días cerrados (por ejemplo,
-- el asiento de revaluación del último día del mes). Lo indican con una
-- variable de sesión local a la transacción; los triggers la respetan.

CREATE OR REPLACE FUNCTION contabilidad.modificacion_cerrado_habilitada()
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN current_setting('contabilidad.modificar_cerrado') = 'on';
EXCEPTION
    WHEN undefined_object THEN
        RETURN false;
END;
$$;
COMMENT ON FUNCTION contabilidad.modificacion_cerrado_habilitada() IS 'true si la transacción actual tiene habilitada la escritura en días o períodos cerrados (solo la usan los cierres)';

CREATE OR REPLACE FUNCTION contabilidad.establecer_modificacion_cerrado(p_habilitar boolean)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    v_valor_previo boolean := contabilidad.modificacion_cerrado_habilitada();
BEGIN
    PERFORM set_config('contabilidad.modificar_cerrado', CASE WHEN p_habilitar THEN 'on' ELSE 'off' END, true);
    RETURN v_valor_previo;
END;
$$;
COMMENT ON FUNCTION contabilidad.establecer_modificacion_cerrado(boolean) IS 'Habilita o deshabilita la escritura en cerrados para la transacción y devuelve el valor anterior, para restaurarlo';

-- -----------------------------------------------------------------------------
-- Plan de cuentas: nivel, cuenta padre y grupo se calculan del código
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.nivel_de_cuenta(p_codigo_cuenta text)
RETURNS smallint
LANGUAGE sql
STABLE
AS $$
    SELECT min(n.nivel)
    FROM contabilidad.nivel_cuenta n
    WHERE length(p_codigo_cuenta) = (SELECT max(digitos_significativos) FROM contabilidad.nivel_cuenta)
      AND substr(p_codigo_cuenta, n.digitos_significativos + 1) ~ '^0*$';
$$;
COMMENT ON FUNCTION contabilidad.nivel_de_cuenta(text) IS 'Nivel de una cuenta según contabilidad.nivel_cuenta (10101010 → 4, 10101000 → 3). NULL si el largo no corresponde';

CREATE OR REPLACE FUNCTION contabilidad.cuenta_padre_de(p_codigo_cuenta text)
RETURNS varchar
LANGUAGE sql
STABLE
AS $$
    SELECT rpad(left(p_codigo_cuenta, superior.digitos_significativos), length(p_codigo_cuenta), '0')::varchar
    FROM contabilidad.nivel_cuenta superior
    WHERE superior.nivel = contabilidad.nivel_de_cuenta(p_codigo_cuenta) - 1;
$$;
COMMENT ON FUNCTION contabilidad.cuenta_padre_de(text) IS 'Cuenta del nivel inmediato superior (10101010 → 10101000). NULL para el nivel 1';

CREATE OR REPLACE FUNCTION contabilidad.trg_cuenta_contable_derivar()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_nivel_maximo smallint;
BEGIN
    NEW.nivel := contabilidad.nivel_de_cuenta(NEW.codigo_cuenta);
    IF NEW.nivel IS NULL THEN
        RAISE EXCEPTION 'La cuenta % no respeta la estructura del plan (contabilidad.nivel_cuenta)', NEW.codigo_cuenta;
    END IF;
    NEW.codigo_grupo := left(NEW.codigo_cuenta, 1);
    NEW.codigo_cuenta_padre := contabilidad.cuenta_padre_de(NEW.codigo_cuenta);

    SELECT max(nivel) INTO v_nivel_maximo FROM contabilidad.nivel_cuenta;
    IF NEW.es_imputable IS NULL THEN
        NEW.es_imputable := (NEW.nivel = v_nivel_maximo);
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF OLD.es_imputable AND NOT NEW.es_imputable
           AND EXISTS (SELECT 1 FROM contabilidad.asiento_detalle d WHERE d.codigo_cuenta = OLD.codigo_cuenta) THEN
            RAISE EXCEPTION 'La cuenta % tiene movimientos: no puede dejar de ser imputable', OLD.codigo_cuenta;
        END IF;
        NEW.usuario_modificacion := current_user;
        NEW.fecha_modificacion := now();
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_cuenta_contable_derivar
    BEFORE INSERT OR UPDATE ON contabilidad.cuenta_contable
    FOR EACH ROW EXECUTE PROCEDURE contabilidad.trg_cuenta_contable_derivar();

-- -----------------------------------------------------------------------------
-- Calendario: período de una fecha y control de cerrados
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.periodo_de_fecha(p_fecha_contable date, OUT gestion integer, OUT periodo integer)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    SELECT p.gestion, p.periodo INTO gestion, periodo
    FROM contabilidad.periodo_contable p
    WHERE p.periodo BETWEEN 1 AND 12
      AND p_fecha_contable BETWEEN p.fecha_inicio AND p.fecha_fin;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La fecha % no pertenece a ninguna gestión creada', p_fecha_contable
            USING HINT = 'Cree la gestión con contabilidad.crear_gestion';
    END IF;
END;
$$;
COMMENT ON FUNCTION contabilidad.periodo_de_fecha(date) IS 'Gestión y mes (1 a 12) al que pertenece una fecha';

CREATE OR REPLACE FUNCTION contabilidad.verificar_periodo_abierto(p_gestion integer, p_periodo integer, p_fecha_contable date)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM contabilidad.gestion g WHERE g.gestion = p_gestion AND g.estado = 'CERRADA') THEN
        RAISE EXCEPTION 'La gestión % está cerrada', p_gestion
            USING HINT = 'Si corresponde, reábrala con contabilidad.reabrir_gestion';
    END IF;
    IF EXISTS (SELECT 1 FROM contabilidad.periodo_contable p
               WHERE p.gestion = p_gestion AND p.periodo = p_periodo AND p.estado = 'CERRADO') THEN
        RAISE EXCEPTION 'El período % de la gestión % está cerrado', p_periodo, p_gestion
            USING HINT = 'Si corresponde, reábralo con contabilidad.reabrir_periodo';
    END IF;
    IF p_periodo BETWEEN 1 AND 12
       AND EXISTS (SELECT 1 FROM contabilidad.dia_contable d WHERE d.fecha_contable = p_fecha_contable AND d.estado = 'CERRADO') THEN
        RAISE EXCEPTION 'El día % está cerrado', p_fecha_contable
            USING HINT = 'Registre el movimiento en un día abierto o reabra el día con contabilidad.reabrir_dia';
    END IF;
END;
$$;
COMMENT ON FUNCTION contabilidad.verificar_periodo_abierto(integer, integer, date) IS 'Error si la gestión, el período o el día (para los meses 1 a 12) están cerrados';

CREATE OR REPLACE FUNCTION contabilidad.trg_asiento_controlar_periodo()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF contabilidad.modificacion_cerrado_habilitada() THEN
        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        END IF;
        RETURN NEW;
    END IF;

    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'Los asientos no se borran (asiento %): use contabilidad.anular_asiento', OLD.id_asiento;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        IF OLD.estado <> 'VIGENTE' THEN
            RAISE EXCEPTION 'El asiento % está %: no se modifica', OLD.id_asiento, OLD.estado;
        END IF;
        PERFORM contabilidad.verificar_periodo_abierto(OLD.gestion, OLD.periodo, OLD.fecha_contable);
    END IF;

    PERFORM contabilidad.verificar_periodo_abierto(NEW.gestion, NEW.periodo, NEW.fecha_contable);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_asiento_controlar_periodo
    BEFORE INSERT OR UPDATE OR DELETE ON contabilidad.asiento
    FOR EACH ROW EXECUTE PROCEDURE contabilidad.trg_asiento_controlar_periodo();

CREATE OR REPLACE FUNCTION contabilidad.trg_asiento_detalle_controlar_periodo()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_asiento  bigint;
    v_asiento     contabilidad.asiento%ROWTYPE;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_id_asiento := OLD.id_asiento;
    ELSE
        v_id_asiento := NEW.id_asiento;
    END IF;

    IF NOT contabilidad.modificacion_cerrado_habilitada() THEN
        IF TG_OP = 'UPDATE' AND NEW.id_asiento <> OLD.id_asiento THEN
            RAISE EXCEPTION 'Una línea no se pasa de un asiento a otro';
        END IF;
        SELECT * INTO v_asiento FROM contabilidad.asiento a WHERE a.id_asiento = v_id_asiento;
        IF v_asiento.estado <> 'VIGENTE' THEN
            RAISE EXCEPTION 'El asiento % está %: no se modifican sus líneas', v_id_asiento, v_asiento.estado;
        END IF;
        PERFORM contabilidad.verificar_periodo_abierto(v_asiento.gestion, v_asiento.periodo, v_asiento.fecha_contable);
    END IF;

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_asiento_detalle_controlar_periodo
    BEFORE INSERT OR UPDATE OR DELETE ON contabilidad.asiento_detalle
    FOR EACH ROW EXECUTE PROCEDURE contabilidad.trg_asiento_detalle_controlar_periodo();

-- -----------------------------------------------------------------------------
-- Cuadre obligatorio: se verifica al confirmar la transacción
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.trg_asiento_detalle_verificar_cuadre()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_id_asiento  bigint;
    v_origen      varchar;
    v_estado      varchar;
    v_suma_bs     numeric;
    v_suma_usd    numeric;
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_id_asiento := OLD.id_asiento;
    ELSE
        v_id_asiento := NEW.id_asiento;
    END IF;

    SELECT a.origen, a.estado INTO v_origen, v_estado FROM contabilidad.asiento a WHERE a.id_asiento = v_id_asiento;
    IF NOT FOUND OR v_origen = 'MIGRACION' OR v_estado = 'ANULADO' THEN
        RETURN NULL;
    END IF;

    SELECT coalesce(sum(d.importe_bs), 0), coalesce(sum(d.importe_usd), 0)
    INTO v_suma_bs, v_suma_usd
    FROM contabilidad.asiento_detalle d
    WHERE d.id_asiento = v_id_asiento;

    IF v_suma_bs <> 0 OR v_suma_usd <> 0 THEN
        RAISE EXCEPTION 'El asiento % no cuadra: diferencia de Bs % y de USD %', v_id_asiento, v_suma_bs, v_suma_usd
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER ctr_asiento_detalle_cuadre
    AFTER INSERT OR UPDATE OR DELETE ON contabilidad.asiento_detalle
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE PROCEDURE contabilidad.trg_asiento_detalle_verificar_cuadre();

CREATE OR REPLACE FUNCTION contabilidad.trg_asiento_verificar_detalle()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.origen <> 'MIGRACION'
       AND NOT EXISTS (SELECT 1 FROM contabilidad.asiento_detalle d WHERE d.id_asiento = NEW.id_asiento) THEN
        RAISE EXCEPTION 'El asiento % no tiene líneas', NEW.id_asiento USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER ctr_asiento_con_detalle
    AFTER INSERT ON contabilidad.asiento
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE PROCEDURE contabilidad.trg_asiento_verificar_detalle();

-- -----------------------------------------------------------------------------
-- Interfaz: lo contabilizado no se toca (es la traza del asiento)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.trg_interfaz_comprobante_proteger()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.estado = 'CONTABILIZADO' AND NOT contabilidad.modificacion_cerrado_habilitada() THEN
        RAISE EXCEPTION 'La línea de interfaz % ya está contabilizada en el asiento %: no se modifica ni se borra',
            OLD.id_interfaz_comprobante, OLD.id_asiento
            USING HINT = 'Para corregirla anule el asiento con contabilidad.anular_asiento y registre el ajuste';
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_interfaz_comprobante_proteger
    BEFORE UPDATE OR DELETE ON contabilidad.interfaz_comprobante
    FOR EACH ROW EXECUTE PROCEDURE contabilidad.trg_interfaz_comprobante_proteger();

-- -----------------------------------------------------------------------------
-- Funciones auxiliares del registro
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.tipo_cambio_vigente(p_fecha date, p_codigo_moneda integer DEFAULT 2)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = contabilidad, pg_temp
AS $$
DECLARE
    v_tipo_cambio numeric;
BEGIN
    IF EXISTS (SELECT 1 FROM moneda m WHERE m.codigo_moneda = p_codigo_moneda AND m.es_moneda_funcional) THEN
        RETURN 1;
    END IF;
    SELECT t.tipo_cambio_oficial INTO v_tipo_cambio
    FROM tipo_cambio t
    WHERE t.codigo_moneda = p_codigo_moneda AND t.fecha <= p_fecha
    ORDER BY t.fecha DESC
    LIMIT 1;
    IF v_tipo_cambio IS NULL THEN
        RAISE EXCEPTION 'No hay tipo de cambio de la moneda % al %', p_codigo_moneda, p_fecha
            USING HINT = 'Registre el tipo de cambio en contabilidad.tipo_cambio';
    END IF;
    RETURN v_tipo_cambio;
END;
$$;
COMMENT ON FUNCTION contabilidad.tipo_cambio_vigente(date, integer) IS 'Último tipo de cambio oficial registrado hasta la fecha (1 para la moneda funcional)';

CREATE OR REPLACE FUNCTION contabilidad.siguiente_numero_asiento(p_gestion integer)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_numero integer;
BEGIN
    INSERT INTO contabilidad.correlativo_asiento (gestion, ultimo_numero) VALUES (p_gestion, 0)
    ON CONFLICT (gestion) DO NOTHING;
    UPDATE contabilidad.correlativo_asiento c
    SET ultimo_numero = c.ultimo_numero + 1
    WHERE c.gestion = p_gestion
    RETURNING c.ultimo_numero INTO v_numero;
    RETURN v_numero;
END;
$$;
COMMENT ON FUNCTION contabilidad.siguiente_numero_asiento(integer) IS 'Siguiente correlativo de asiento de la gestión (bloquea la fila hasta el fin de la transacción: sin huecos ni duplicados)';

CREATE OR REPLACE FUNCTION contabilidad.lineas_de_detalle(p_detalle jsonb)
RETURNS TABLE (
    numero_linea           integer,
    codigo_cuenta          varchar,
    glosa                  text,
    importe_bs             numeric,
    importe_usd            numeric,
    codigo_moneda          smallint,
    tipo_cambio            numeric,
    codigo_unidad_negocio  smallint,
    codigo_centro_costo    smallint,
    codigo_tipo_auxiliar   smallint,
    codigo_auxiliar        integer)
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT e.orden::integer,
           nullif(btrim(e.linea->>'codigo_cuenta'), '')::varchar,
           e.linea->>'glosa',
           (e.linea->>'importe_bs')::numeric,
           (e.linea->>'importe_usd')::numeric,
           (e.linea->>'codigo_moneda')::smallint,
           (e.linea->>'tipo_cambio')::numeric,
           (e.linea->>'codigo_unidad_negocio')::smallint,
           (e.linea->>'codigo_centro_costo')::smallint,
           (e.linea->>'codigo_tipo_auxiliar')::smallint,
           (e.linea->>'codigo_auxiliar')::integer
    FROM jsonb_array_elements(p_detalle) WITH ORDINALITY AS e(linea, orden);
$$;
COMMENT ON FUNCTION contabilidad.lineas_de_detalle(jsonb) IS
'Convierte el detalle JSON de un asiento en filas. Claves: codigo_cuenta, codigo_unidad_negocio (obligatorias), importe_bs y/o importe_usd (con signo: + debe, - haber), '
'codigo_moneda, tipo_cambio, codigo_centro_costo, codigo_tipo_auxiliar, codigo_auxiliar, glosa';

CREATE OR REPLACE FUNCTION contabilidad.validar_detalle(p_detalle jsonb, p_origen text, p_codigo_centro_costo_defecto integer)
RETURNS void
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_errores        text;
    v_estricto       boolean := (p_origen = 'MANUAL');
    v_cuenta_activa  boolean := (p_origen IN ('MANUAL', 'INTERFAZ'));
BEGIN
    IF p_detalle IS NULL OR jsonb_typeof(p_detalle) <> 'array' OR jsonb_array_length(p_detalle) = 0 THEN
        RAISE EXCEPTION 'El detalle del asiento tiene que ser un arreglo JSON con al menos una línea';
    END IF;
    IF v_estricto AND jsonb_array_length(p_detalle) < 2 THEN
        RAISE EXCEPTION 'Un asiento manual necesita al menos dos líneas';
    END IF;

    SELECT string_agg(format('línea %s: %s', x.numero_linea, x.problema), '; ' ORDER BY x.numero_linea)
    INTO v_errores
    FROM (
        SELECT l.numero_linea, unnest(ARRAY[
            CASE WHEN l.codigo_cuenta IS NULL THEN 'falta codigo_cuenta' END,
            CASE WHEN l.codigo_cuenta IS NOT NULL AND c.codigo_cuenta IS NULL THEN format('la cuenta %s no existe', l.codigo_cuenta) END,
            CASE WHEN c.codigo_cuenta IS NOT NULL AND NOT c.es_imputable AND p_origen <> 'SISTEMA' THEN format('la cuenta %s no es imputable', l.codigo_cuenta) END,
            CASE WHEN c.codigo_cuenta IS NOT NULL AND NOT c.activo AND v_cuenta_activa THEN format('la cuenta %s está inactiva', l.codigo_cuenta) END,
            CASE WHEN l.codigo_unidad_negocio IS NULL THEN 'falta codigo_unidad_negocio' END,
            CASE WHEN l.codigo_unidad_negocio IS NOT NULL AND u.codigo_unidad_negocio IS NULL THEN format('la unidad de negocio %s no existe', l.codigo_unidad_negocio) END,
            CASE WHEN u.codigo_unidad_negocio IS NOT NULL AND NOT u.activo AND v_estricto THEN format('la unidad de negocio %s está inactiva', l.codigo_unidad_negocio) END,
            CASE WHEN l.codigo_centro_costo IS NOT NULL AND cc.codigo_centro_costo IS NULL THEN format('el centro de costo %s no existe', l.codigo_centro_costo) END,
            CASE WHEN v_estricto AND c.exige_centro_costo AND coalesce(l.codigo_centro_costo, p_codigo_centro_costo_defecto) = 0
                 THEN format('la cuenta %s exige centro de costo', l.codigo_cuenta) END,
            CASE WHEN v_estricto AND coalesce(l.codigo_centro_costo, p_codigo_centro_costo_defecto) <> 0
                      AND EXISTS (SELECT 1 FROM contabilidad.unidad_negocio_centro_costo x WHERE x.codigo_unidad_negocio = l.codigo_unidad_negocio)
                      AND NOT EXISTS (SELECT 1 FROM contabilidad.unidad_negocio_centro_costo x
                                      WHERE x.codigo_unidad_negocio = l.codigo_unidad_negocio
                                        AND x.codigo_centro_costo = coalesce(l.codigo_centro_costo, p_codigo_centro_costo_defecto))
                 THEN format('el centro de costo %s no está habilitado para la unidad %s', coalesce(l.codigo_centro_costo, p_codigo_centro_costo_defecto), l.codigo_unidad_negocio) END,
            CASE WHEN l.importe_bs IS NULL AND l.importe_usd IS NULL THEN 'falta importe_bs o importe_usd' END,
            CASE WHEN v_estricto AND coalesce(l.importe_bs, 0) = 0 AND coalesce(l.importe_usd, 0) = 0 THEN 'el importe es cero' END,
            CASE WHEN l.codigo_moneda IS NOT NULL AND NOT EXISTS (SELECT 1 FROM contabilidad.moneda m WHERE m.codigo_moneda = l.codigo_moneda)
                 THEN format('la moneda %s no existe', l.codigo_moneda) END,
            CASE WHEN (l.codigo_tipo_auxiliar IS NULL) <> (l.codigo_auxiliar IS NULL) THEN 'el auxiliar necesita codigo_tipo_auxiliar y codigo_auxiliar' END,
            CASE WHEN l.codigo_tipo_auxiliar IS NOT NULL AND l.codigo_auxiliar IS NOT NULL AND ax.codigo_auxiliar IS NULL
                 THEN format('el auxiliar %s-%s no existe', l.codigo_tipo_auxiliar, l.codigo_auxiliar) END
        ]) AS problema
        FROM contabilidad.lineas_de_detalle(p_detalle) l
        LEFT JOIN contabilidad.cuenta_contable c ON c.codigo_cuenta = l.codigo_cuenta
        LEFT JOIN contabilidad.unidad_negocio u ON u.codigo_unidad_negocio = l.codigo_unidad_negocio
        LEFT JOIN contabilidad.centro_costo cc ON cc.codigo_centro_costo = l.codigo_centro_costo
        LEFT JOIN contabilidad.auxiliar_contable ax ON ax.codigo_tipo_auxiliar = l.codigo_tipo_auxiliar AND ax.codigo_auxiliar = l.codigo_auxiliar
    ) x
    WHERE x.problema IS NOT NULL;

    IF v_errores IS NOT NULL THEN
        RAISE EXCEPTION 'El asiento tiene errores: %', v_errores;
    END IF;
END;
$$;
COMMENT ON FUNCTION contabilidad.validar_detalle(jsonb, text, integer) IS
'Valida el detalle antes de grabarlo. MANUAL: todas las reglas; INTERFAZ: cuentas existentes, imputables y activas; SISTEMA: cuentas existentes';

CREATE OR REPLACE FUNCTION contabilidad.cuadrar_asiento(p_id_asiento bigint)
RETURNS numeric
LANGUAGE plpgsql
AS $$
DECLARE
    v_moneda_operacion  smallint;
    v_tolerancia        numeric;
    v_cuenta_redondeo   varchar;
    v_centro_defecto    smallint;
    v_suma_bs           numeric;
    v_suma_usd          numeric;
    v_diferencia        numeric;
    v_unidad            smallint;
    v_nombre_moneda     text;
BEGIN
    SELECT a.codigo_moneda_operacion, g.tolerancia_redondeo, g.codigo_cuenta_redondeo, g.codigo_centro_costo_defecto
    INTO v_moneda_operacion, v_tolerancia, v_cuenta_redondeo, v_centro_defecto
    FROM contabilidad.asiento a
    JOIN contabilidad.gestion g ON g.gestion = a.gestion
    WHERE a.id_asiento = p_id_asiento;

    SELECT coalesce(sum(d.importe_bs), 0), coalesce(sum(d.importe_usd), 0)
    INTO v_suma_bs, v_suma_usd
    FROM contabilidad.asiento_detalle d
    WHERE d.id_asiento = p_id_asiento;

    -- En la moneda de la operación el asiento cuadra exacto (regla de pcuadre_cntcn)
    IF (v_moneda_operacion = 1 AND v_suma_bs <> 0) OR (v_moneda_operacion = 2 AND v_suma_usd <> 0) THEN
        RAISE EXCEPTION 'El asiento no cuadra en %: la suma da % y tiene que dar 0',
            CASE WHEN v_moneda_operacion = 1 THEN 'Bs' ELSE 'USD' END,
            CASE WHEN v_moneda_operacion = 1 THEN v_suma_bs ELSE v_suma_usd END;
    END IF;

    v_diferencia := CASE WHEN v_moneda_operacion = 1 THEN v_suma_usd ELSE v_suma_bs END;
    v_nombre_moneda := CASE WHEN v_moneda_operacion = 1 THEN 'USD' ELSE 'Bs' END;
    IF v_diferencia = 0 THEN
        RETURN 0;
    END IF;

    -- En la otra moneda se ajusta el redondeo si es menor a la tolerancia
    IF abs(v_diferencia) >= v_tolerancia THEN
        RAISE EXCEPTION 'El asiento tiene una diferencia no razonable en %: % (tolerancia %)', v_nombre_moneda, v_diferencia, v_tolerancia;
    END IF;
    IF v_cuenta_redondeo IS NULL THEN
        RAISE EXCEPTION 'Diferencia de redondeo de % % y la gestión no tiene codigo_cuenta_redondeo', v_diferencia, v_nombre_moneda;
    END IF;

    SELECT d.codigo_unidad_negocio INTO v_unidad
    FROM contabilidad.asiento_detalle d
    WHERE d.id_asiento = p_id_asiento
    ORDER BY abs(d.importe_bs) DESC, d.numero_linea
    LIMIT 1;

    INSERT INTO contabilidad.asiento_detalle (id_asiento, numero_linea, codigo_cuenta, glosa, importe_bs, importe_usd,
                                              codigo_moneda, codigo_unidad_negocio, codigo_centro_costo)
    SELECT p_id_asiento, max(d.numero_linea) + 1, v_cuenta_redondeo, 'DIFERENCIA DE REDONDEO',
           CASE WHEN v_moneda_operacion = 1 THEN 0 ELSE -v_diferencia END,
           CASE WHEN v_moneda_operacion = 1 THEN -v_diferencia ELSE 0 END,
           v_moneda_operacion, v_unidad, v_centro_defecto
    FROM contabilidad.asiento_detalle d
    WHERE d.id_asiento = p_id_asiento;

    RETURN v_diferencia;
END;
$$;
COMMENT ON FUNCTION contabilidad.cuadrar_asiento(bigint) IS
'Regla de pcuadre_cntcn: en la moneda de la operación la suma tiene que dar 0; en la otra, una diferencia menor a la tolerancia se lleva a la cuenta de redondeo. Devuelve la diferencia ajustada';

CREATE OR REPLACE FUNCTION contabilidad.insertar_asiento(
    p_fecha_contable           date,
    p_gestion                  integer,
    p_periodo                  integer,
    p_codigo_tipo_documento    integer,
    p_codigo_modulo            integer,
    p_numero_documento         integer,
    p_glosa                    text,
    p_origen                   text,
    p_tipo_asiento_sistema     text,
    p_id_asiento_revertido     bigint,
    p_codigo_moneda_operacion  integer,
    p_detalle                  jsonb,
    p_usuario                  text)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    v_periodo         contabilidad.periodo_contable%ROWTYPE;
    v_centro_defecto  smallint;
    v_tipo_cambio     numeric;
    v_id_asiento      bigint;
BEGIN
    IF p_usuario IS NULL OR btrim(p_usuario) = '' THEN
        RAISE EXCEPTION 'Falta el usuario que registra el asiento';
    END IF;

    SELECT * INTO v_periodo
    FROM contabilidad.periodo_contable p
    WHERE p.gestion = p_gestion AND p.periodo = p_periodo
    FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el período % de la gestión %', p_periodo, p_gestion;
    END IF;
    IF p_fecha_contable NOT BETWEEN v_periodo.fecha_inicio AND v_periodo.fecha_fin THEN
        RAISE EXCEPTION 'La fecha % no corresponde al período % de la gestión % (del % al %)',
            p_fecha_contable, p_periodo, p_gestion, v_periodo.fecha_inicio, v_periodo.fecha_fin;
    END IF;

    -- El día queda registrado y bloqueado en modo compartido: cerrar_dia espera a que terminen los registros en curso
    IF p_periodo BETWEEN 1 AND 12 THEN
        INSERT INTO contabilidad.dia_contable (fecha_contable, gestion, periodo)
        VALUES (p_fecha_contable, p_gestion, p_periodo)
        ON CONFLICT (fecha_contable) DO NOTHING;
        PERFORM 1 FROM contabilidad.dia_contable d WHERE d.fecha_contable = p_fecha_contable FOR SHARE;
    END IF;

    SELECT g.codigo_centro_costo_defecto INTO v_centro_defecto FROM contabilidad.gestion g WHERE g.gestion = p_gestion;
    PERFORM contabilidad.validar_detalle(p_detalle, p_origen, v_centro_defecto);

    -- El tipo de cambio solo se busca si alguna línea trae un solo importe y no trae su tipo de cambio
    IF EXISTS (SELECT 1 FROM contabilidad.lineas_de_detalle(p_detalle) l
               WHERE (l.importe_bs IS NULL OR l.importe_usd IS NULL) AND l.tipo_cambio IS NULL) THEN
        v_tipo_cambio := contabilidad.tipo_cambio_vigente(p_fecha_contable, 2);
    END IF;

    INSERT INTO contabilidad.asiento (gestion, periodo, numero_asiento, fecha_contable, codigo_tipo_documento, codigo_modulo,
                                      numero_documento, glosa, codigo_moneda_operacion, origen, tipo_asiento_sistema,
                                      id_asiento_revertido, usuario_creacion)
    VALUES (p_gestion, p_periodo, contabilidad.siguiente_numero_asiento(p_gestion), p_fecha_contable, p_codigo_tipo_documento,
            p_codigo_modulo, p_numero_documento, p_glosa, p_codigo_moneda_operacion, p_origen, p_tipo_asiento_sistema,
            p_id_asiento_revertido, p_usuario)
    RETURNING id_asiento INTO v_id_asiento;

    INSERT INTO contabilidad.asiento_detalle (id_asiento, numero_linea, codigo_cuenta, glosa, importe_bs, importe_usd, codigo_moneda,
                                              tipo_cambio, codigo_unidad_negocio, codigo_centro_costo, codigo_tipo_auxiliar, codigo_auxiliar)
    SELECT v_id_asiento,
           l.numero_linea,
           l.codigo_cuenta,
           l.glosa,
           round(coalesce(l.importe_bs, l.importe_usd * coalesce(l.tipo_cambio, v_tipo_cambio)), 2),
           round(coalesce(l.importe_usd, l.importe_bs / coalesce(l.tipo_cambio, v_tipo_cambio)), 2),
           coalesce(l.codigo_moneda, p_codigo_moneda_operacion),
           coalesce(l.tipo_cambio, v_tipo_cambio),
           l.codigo_unidad_negocio,
           coalesce(l.codigo_centro_costo, v_centro_defecto),
           l.codigo_tipo_auxiliar,
           l.codigo_auxiliar
    FROM contabilidad.lineas_de_detalle(p_detalle) l;

    PERFORM contabilidad.cuadrar_asiento(v_id_asiento);
    RETURN v_id_asiento;
END;
$$;
COMMENT ON FUNCTION contabilidad.insertar_asiento(date, integer, integer, integer, integer, integer, text, text, text, bigint, integer, jsonb, text) IS
'Uso interno: graba cabecera y detalle, completa el importe que falte con el tipo de cambio, valida y cuadra. Lo usan registrar_asiento, la interfaz y los cierres';

-- -----------------------------------------------------------------------------
-- API: registrar y anular asientos
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.registrar_asiento(
    p_fecha_contable           date,
    p_codigo_tipo_documento    integer,
    p_glosa                    text,
    p_detalle                  jsonb,
    p_usuario                  text,
    p_codigo_modulo            integer DEFAULT 2,
    p_numero_documento         integer DEFAULT NULL,
    p_codigo_moneda_operacion  integer DEFAULT 1,
    p_periodo                  integer DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = contabilidad, pg_temp
AS $$
DECLARE
    v_gestion  integer;
    v_periodo  integer;
BEGIN
    IF EXISTS (SELECT 1 FROM tipo_documento t WHERE t.codigo_tipo_documento = p_codigo_tipo_documento AND t.es_de_sistema) THEN
        RAISE EXCEPTION 'El tipo de documento % lo generan solo los cierres', p_codigo_tipo_documento;
    END IF;

    IF p_periodo IS NULL OR p_periodo BETWEEN 1 AND 12 THEN
        SELECT f.gestion, f.periodo INTO v_gestion, v_periodo FROM periodo_de_fecha(p_fecha_contable) f;
        IF p_periodo IS NOT NULL AND p_periodo <> v_periodo THEN
            RAISE EXCEPTION 'La fecha % es del período %, no del %', p_fecha_contable, v_periodo, p_periodo;
        END IF;
    ELSIF p_periodo = 0 THEN
        SELECT g.gestion INTO v_gestion FROM gestion g WHERE g.fecha_inicio = p_fecha_contable;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Un asiento de apertura manual (período 0) lleva la fecha de inicio de la gestión';
        END IF;
        v_periodo := 0;
    ELSE
        RAISE EXCEPTION 'El período % no admite asientos manuales (el 13 es del cierre de gestión)', p_periodo;
    END IF;

    RETURN insertar_asiento(p_fecha_contable, v_gestion, v_periodo, p_codigo_tipo_documento, p_codigo_modulo, p_numero_documento,
                            p_glosa, 'MANUAL', NULL, NULL, p_codigo_moneda_operacion, p_detalle, p_usuario);
END;
$$;
COMMENT ON FUNCTION contabilidad.registrar_asiento(date, integer, text, jsonb, text, integer, integer, integer, integer) IS
'Registra un asiento manual y devuelve su id. p_detalle: arreglo JSON (ver contabilidad.lineas_de_detalle). p_periodo = 0 solo para una apertura manual con la fecha de inicio de la gestión';

CREATE OR REPLACE FUNCTION contabilidad.anular_asiento(
    p_id_asiento        bigint,
    p_usuario           text,
    p_motivo            text,
    p_fecha_reversion   date DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = contabilidad, pg_temp
AS $$
DECLARE
    v_asiento           asiento%ROWTYPE;
    v_esta_cerrado      boolean;
    v_fecha_reversion   date;
    v_gestion           integer;
    v_periodo           integer;
    v_detalle           jsonb;
    v_id_reversion      bigint;
    v_valor_previo      boolean;
BEGIN
    IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
        RAISE EXCEPTION 'Indique el motivo de la anulación';
    END IF;

    SELECT * INTO v_asiento FROM asiento a WHERE a.id_asiento = p_id_asiento FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No existe el asiento %', p_id_asiento;
    END IF;
    IF v_asiento.estado <> 'VIGENTE' THEN
        RAISE EXCEPTION 'El asiento % ya está %', p_id_asiento, v_asiento.estado;
    END IF;
    IF v_asiento.tipo_asiento_sistema = 'REVERSION' THEN
        RAISE EXCEPTION 'El asiento % es la reversión del asiento %: no se anula, registre un asiento nuevo si corresponde',
            p_id_asiento, v_asiento.id_asiento_revertido;
    END IF;
    IF v_asiento.origen = 'SISTEMA' THEN
        RAISE EXCEPTION 'El asiento % es de %: se deshace reabriendo el cierre que lo generó', p_id_asiento, lower(v_asiento.tipo_asiento_sistema);
    END IF;

    v_esta_cerrado := EXISTS (SELECT 1 FROM gestion g WHERE g.gestion = v_asiento.gestion AND g.estado = 'CERRADA')
                   OR EXISTS (SELECT 1 FROM periodo_contable p WHERE p.gestion = v_asiento.gestion AND p.periodo = v_asiento.periodo AND p.estado = 'CERRADO')
                   OR (v_asiento.periodo BETWEEN 1 AND 12
                       AND EXISTS (SELECT 1 FROM dia_contable d WHERE d.fecha_contable = v_asiento.fecha_contable AND d.estado = 'CERRADO'));

    -- Día abierto: se anula y deja de contar en los saldos
    IF NOT v_esta_cerrado THEN
        UPDATE asiento
        SET estado = 'ANULADO', usuario_anulacion = p_usuario, fecha_anulacion = now(), motivo_anulacion = p_motivo
        WHERE id_asiento = p_id_asiento;
        RETURN p_id_asiento;
    END IF;

    -- Día cerrado: se registra un asiento inverso en un día abierto de la misma gestión
    v_fecha_reversion := coalesce(p_fecha_reversion, current_date);
    SELECT f.gestion, f.periodo INTO v_gestion, v_periodo FROM periodo_de_fecha(v_fecha_reversion) f;
    IF v_gestion <> v_asiento.gestion THEN
        RAISE EXCEPTION 'La reversión del asiento % tiene que quedar en su gestión (%); el % es de la gestión %',
            p_id_asiento, v_asiento.gestion, v_fecha_reversion, v_gestion
            USING HINT = 'Indique p_fecha_reversion dentro de la gestión o registre un asiento de ajuste';
    END IF;

    SELECT jsonb_agg(jsonb_build_object(
               'codigo_cuenta', d.codigo_cuenta, 'glosa', d.glosa,
               'importe_bs', -d.importe_bs, 'importe_usd', -d.importe_usd,
               'codigo_moneda', d.codigo_moneda, 'tipo_cambio', d.tipo_cambio,
               'codigo_unidad_negocio', d.codigo_unidad_negocio, 'codigo_centro_costo', d.codigo_centro_costo,
               'codigo_tipo_auxiliar', d.codigo_tipo_auxiliar, 'codigo_auxiliar', d.codigo_auxiliar)
           ORDER BY d.numero_linea)
    INTO v_detalle
    FROM asiento_detalle d
    WHERE d.id_asiento = p_id_asiento;

    v_id_reversion := insertar_asiento(v_fecha_reversion, v_gestion, v_periodo, v_asiento.codigo_tipo_documento, v_asiento.codigo_modulo,
                                       v_asiento.numero_documento,
                                       format('REVERSION DEL ASIENTO %s-%s: %s', v_asiento.gestion, v_asiento.numero_asiento, p_motivo),
                                       'SISTEMA', 'REVERSION', p_id_asiento, v_asiento.codigo_moneda_operacion, v_detalle, p_usuario);

    v_valor_previo := establecer_modificacion_cerrado(true);
    UPDATE asiento
    SET estado = 'REVERTIDO', usuario_anulacion = p_usuario, fecha_anulacion = now(), motivo_anulacion = p_motivo
    WHERE id_asiento = p_id_asiento;
    PERFORM establecer_modificacion_cerrado(v_valor_previo);

    RETURN v_id_reversion;
END;
$$;
COMMENT ON FUNCTION contabilidad.anular_asiento(bigint, text, text, date) IS
'Día abierto: marca el asiento ANULADO y devuelve su id. Día cerrado: lo marca REVERTIDO, registra el asiento inverso en p_fecha_reversion (por defecto hoy) y devuelve el id de la reversión';

-- -----------------------------------------------------------------------------
-- API: contabilizar la interfaz de un día
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.contabilizar_interfaz(p_fecha_contable date, p_usuario text)
RETURNS TABLE (
    codigo_modulo     smallint,
    numero_documento  integer,
    id_asiento        bigint,
    estado            varchar,
    mensaje           text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = contabilidad, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_gestion     integer;
    v_periodo     integer;
    v_documento   record;
    v_moneda      integer;
    v_id_asiento  bigint;
    v_mensaje     text;
BEGIN
    SELECT f.gestion, f.periodo INTO v_gestion, v_periodo FROM periodo_de_fecha(p_fecha_contable) f;
    PERFORM verificar_periodo_abierto(v_gestion, v_periodo, p_fecha_contable);

    FOR v_documento IN
        SELECT i.codigo_modulo,
               i.numero_documento,
               m.codigo_tipo_documento_defecto,
               max(i.codigo_moneda_operacion) AS codigo_moneda_operacion,
               sum(i.importe_bs) AS suma_bs,
               sum(i.importe_usd) AS suma_usd,
               (array_agg(i.descripcion ORDER BY i.numero_linea))[1] AS glosa,
               jsonb_agg(jsonb_build_object(
                   'codigo_cuenta', i.codigo_cuenta,
                   'glosa', concat_ws(' · ', i.descripcion, i.descripcion_adicional),
                   'importe_bs', i.importe_bs,
                   'importe_usd', i.importe_usd,
                   'tipo_cambio', i.tipo_cambio,
                   'codigo_unidad_negocio', i.codigo_unidad_negocio,
                   'codigo_centro_costo', i.codigo_centro_costo)
                   ORDER BY i.numero_linea) AS detalle,
               array_agg(i.id_interfaz_comprobante) AS ids
        FROM interfaz_comprobante i
        JOIN modulo_origen m ON m.codigo_modulo = i.codigo_modulo
        WHERE i.fecha_contable = p_fecha_contable
          AND i.estado IN ('PENDIENTE', 'ERROR')
        GROUP BY i.codigo_modulo, i.numero_documento, m.codigo_tipo_documento_defecto
        ORDER BY i.codigo_modulo, i.numero_documento
    LOOP
        -- Moneda de la operación: la informada o la que ya cuadra exacto
        v_moneda := coalesce(v_documento.codigo_moneda_operacion,
                             CASE WHEN v_documento.suma_bs = 0 THEN 1 WHEN v_documento.suma_usd = 0 THEN 2 ELSE 1 END);
        codigo_modulo := v_documento.codigo_modulo;
        numero_documento := v_documento.numero_documento;
        BEGIN
            v_id_asiento := insertar_asiento(p_fecha_contable, v_gestion, v_periodo, v_documento.codigo_tipo_documento_defecto,
                                             v_documento.codigo_modulo, v_documento.numero_documento, v_documento.glosa,
                                             'INTERFAZ', NULL, NULL, v_moneda, v_documento.detalle, p_usuario);
            UPDATE interfaz_comprobante
            SET estado = 'CONTABILIZADO', id_asiento = v_id_asiento, mensaje_error = NULL,
                usuario_proceso = p_usuario, fecha_proceso = now()
            WHERE id_interfaz_comprobante = ANY (v_documento.ids);
            id_asiento := v_id_asiento;
            estado := 'CONTABILIZADO';
            mensaje := NULL;
        EXCEPTION
            WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS v_mensaje = MESSAGE_TEXT;
                UPDATE interfaz_comprobante
                SET estado = 'ERROR', mensaje_error = v_mensaje, usuario_proceso = p_usuario, fecha_proceso = now()
                WHERE id_interfaz_comprobante = ANY (v_documento.ids);
                id_asiento := NULL;
                estado := 'ERROR';
                mensaje := v_mensaje;
        END;
        RETURN NEXT;
    END LOOP;
END;
$$;
COMMENT ON FUNCTION contabilidad.contabilizar_interfaz(date, text) IS
'Arma un asiento por cada módulo y documento con líneas PENDIENTE o ERROR del día. Un documento con error no frena a los demás: queda en ERROR con su mensaje y se reintenta en la próxima corrida';

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA contabilidad FROM PUBLIC;

COMMIT;

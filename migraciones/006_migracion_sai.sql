-- =============================================================================
-- Contabilidad · 006 · Migración desde el SAI (Informix tbsai@online09)
-- -----------------------------------------------------------------------------
-- 1. Esquema contabilidad_sai: copia de las tablas del módulo cn del SAI con
--    los mismos nombres y columnas. Se llena con Pentaho (Table input en
--    PRD SAI09 → Table output aquí), una tabla por paso, sin transformar nada.
-- 2. contabilidad.migrar_desde_sai(usuario): pasa los datos a las tablas nuevas
--    y devuelve un informe por paso. Se corre una sola vez, con el esquema
--    contabilidad vacío y en una transacción:
--
--      BEGIN;
--      SELECT * FROM contabilidad.migrar_desde_sai('migracion');
--      -- revisar el informe y contabilidad.asientos_descuadrados()
--      COMMIT;   -- o ROLLBACK
--
-- Reglas de la migración (ver README):
--   * Gestiones con histórico en el SAI (cnhpr, 2018-2022): quedan CERRADAS.
--   * Gestiones de cocierre (2023 en adelante): quedan ABIERTAS; sus meses se
--     cierran según coperiodo (B = cerrado). El SAI no generó asientos de cierre
--     ni de apertura desde 2023: se hacen después con contabilidad.cerrar_gestion.
--   * cndtr de la gestión 0 (borrador de apertura, descuadrado) no se migra.
--   * Las líneas dadas de baja (mrcb = 9) de asientos vigentes no se migran.
--   * Asientos anulados en el SAI (mrcb = 9): se migran como ANULADO.
--   * cntcn sin contabilizar (post = 0) de las gestiones abiertas pasa a la
--     interfaz como PENDIENTE (DESCARTADO si su mes ya está cerrado).
--   * Códigos que aparecen en los movimientos y no en los catálogos se crean
--     inactivos con el nombre "(SAI, SIN DESCRIPCION)" para no perder datos.
--
-- Requiere 001 a 004. Estado: PROPUESTA, NO APLICADA.
-- =============================================================================

BEGIN;

CREATE SCHEMA contabilidad_sai;
COMMENT ON SCHEMA contabilidad_sai IS 'Staging de la migración: copia sin transformar de las tablas cn y co del SAI (Informix). Se puede borrar después de migrar';

CREATE TABLE contabilidad_sai.cnune (cnuneuneg smallint, cnunedesc varchar(40), cnunecreg smallint);
CREATE TABLE contabilidad_sai.cncsu (cncsucsup smallint, cncsudesc varchar(40));
CREATE TABLE contabilidad_sai.cncco (cnccoccos smallint, cnccodesc varchar(40), cnccocsup smallint);
CREATE TABLE contabilidad_sai.cnruc (cnrucuneg smallint, cnrucccos smallint);
CREATE TABLE contabilidad_sai.cntdc (cntdctdoc smallint, cntdcdesc varchar(40));
CREATE TABLE contabilidad_sai.cntco (cntcotcon smallint, cntcodesc varchar(40));
CREATE TABLE contabilidad_sai.cnhtc (cnhtcgest smallint, cnhtctcon smallint, cnhtcdesc varchar(40));
CREATE TABLE contabilidad_sai.cncnp (cncnptcon smallint, cncnpncon integer, cncnpdesc varchar(40));
CREATE TABLE contabilidad_sai.cnhcn (cnhcngest smallint, cnhcntcon smallint, cnhcnncon integer, cnhcndesc varchar(40));
CREATE TABLE contabilidad_sai.cnplc (cnplccnta varchar(16), cnplcnomb varchar(40), cnplccmon smallint, cnplcmcco varchar(1),
                                     cnplctcon smallint, cnplcuser varchar(3), cnplchora varchar(8), cnplcfpro date);
CREATE TABLE contabilidad_sai.cnpch (cnpchgest smallint, cnpchcnta varchar(16), cnpchnomb varchar(40), cnpchcmon smallint, cnpchmcco varchar(1),
                                     cnpchtcon smallint, cnpchuser varchar(3), cnpchhora varchar(8), cnpchfpro date);
CREATE TABLE contabilidad_sai.cnprm (cnprmncp1 varchar(1), cnprmncp2 varchar(1), cnprmncp3 varchar(1), cnprmncp4 varchar(1), cnprmncp5 varchar(1),
                                     cnprmncp6 varchar(1), cnprmncp7 varchar(1), cnprmncp8 varchar(1), cnprmncp9 varchar(1),
                                     cnprmcres varchar(16), cnprmcrea varchar(16), cnprmcaju varchar(16), cnprmccos smallint, cnprmfdes date,
                                     cnprmmcre varchar(1), cnprmfsld date, cnprmfcii date, cnprmcpog varchar(1));
CREATE TABLE contabilidad_sai.cnhpr (cnhprgest smallint, cnhprpmes smallint, cnhprumes smallint, cnhprfini date, cnhprffin date,
                                     cnhprncp1 varchar(1), cnhprncp2 varchar(1), cnhprncp3 varchar(1), cnhprncp4 varchar(1), cnhprncp5 varchar(1),
                                     cnhprncp6 varchar(1), cnhprncp7 varchar(1), cnhprncp8 varchar(1), cnhprncp9 varchar(1),
                                     cnhprcres varchar(16), cnhprcrea varchar(16), cnhprcaju varchar(16), cnhprccos smallint, cnhprfdes date,
                                     cnhprmcre varchar(1), cnhprfsld date, cnhprfcii date, cnhprcpog varchar(1));
CREATE TABLE contabilidad_sai.cocierre (gestion date, fecha_ini date, fecha_fin date, estado varchar(1), usuario varchar(3), hora varchar(8), fecha date);
CREATE TABLE contabilidad_sai.coperiodo (gestion date, periodo smallint, i_fecha date, f_fecha date, des_peri varchar(30), estado varchar(1),
                                         usuario varchar(3), hora varchar(8), fecha date);
CREATE TABLE contabilidad_sai.cnrpc (cnrpcctao varchar(16), cnrpcctas varchar(16));
CREATE TABLE contabilidad_sai.cnhtr (cnhtrntra numeric(12,0), cnhtrtdoc smallint, cnhtrndoc integer, cnhtrfdoc date, cnhtrmorg smallint, cnhtrmrcb smallint,
                                     cnhtruser varchar(3), cnhtrhora varchar(8), cnhtrfpro date, cnhtrgest integer, cnhtrcper smallint, cnhtrnhtr integer);
CREATE TABLE contabilidad_sai.cndtr (cndtrntra numeric(12,0), cndtrtdoc smallint, cndtrndoc integer, cndtrfdoc date, cndtrmorg smallint, cndtritem smallint,
                                     cndtrcnta varchar(16), cndtrglos varchar(30), cndtrimpi numeric(14,2), cndtrcmon smallint, cndtrcamb numeric(18,8),
                                     cndtrimpc numeric(14,2), cndtruneg smallint, cndtrccos smallint, cndtrtcon smallint, cndtrncon integer,
                                     cndtrmrcb smallint, cndtrgest integer, cndtrcper smallint, cndtrnhtr integer);
CREATE TABLE contabilidad_sai.cndtrglo (cndtrntra integer, cndtritem smallint, apu smallint, glosa varchar(50));
CREATE TABLE contabilidad_sai.cnglo (cnglontra numeric(12,0), cngloitem smallint, cngloglo1 varchar(30), cngloglo2 varchar(30),
                                     cngloglo3 varchar(30), cngloglo4 varchar(30));
CREATE TABLE contabilidad_sai.cnhht (cnhhtgest smallint, cnhhtntra numeric(12,0), cnhhttdoc smallint, cnhhtndoc integer, cnhhtfdoc date, cnhhtmorg smallint,
                                     cnhhtmrcb smallint, cnhhtuser varchar(3), cnhhthora varchar(8), cnhhtfpro date, cnhhtgsti integer,
                                     cnhhtcper smallint, cnhhtnhtr integer);
CREATE TABLE contabilidad_sai.cnhdt (cnhdtgest smallint, cnhdtntra numeric(12,0), cnhdttdoc smallint, cnhdtndoc integer, cnhdtfdoc date, cnhdtmorg smallint,
                                     cnhdtitem smallint, cnhdtcnta varchar(16), cnhdtglos varchar(30), cnhdtimpi numeric(14,2), cnhdtcmon smallint,
                                     cnhdtcamb double precision, cnhdtimpc numeric(14,2), cnhdtuneg smallint, cnhdtccos smallint, cnhdttcon smallint,
                                     cnhdtncon integer, cnhdtmrcb smallint, cnhdtgsti integer, cnhdtcper smallint, cnhdtnhtr integer);
CREATE TABLE contabilidad_sai.cnhgl (cnhglgest smallint, cnhglntra numeric(12,0), cnhglitem smallint, cnhglglo1 varchar(30), cnhglglo2 varchar(30),
                                     cnhglglo3 varchar(30), cnhglglo4 varchar(30));
CREATE TABLE contabilidad_sai.cntcn (cntcnndoc integer, cntcnitem smallint, cntcnfreg date, cntcnpref smallint, cntcncorr smallint, cntcncctb varchar(16),
                                     cntcnuneg smallint, cntcnccos smallint, cntcnccta smallint, cntcnscaa integer, cntcndesc varchar(50),
                                     cntcnimpi numeric(14,2), cntcnimpc numeric(14,2), cntcntcam numeric(20,8), cntcnpost smallint, cntcnmodn smallint,
                                     cntcnnopr integer, cntcnntra integer, cntcnftra date, cntcncdin varchar(40), cntcnuser varchar(3),
                                     cntcnhora varchar(8), cntcnfpro date);

CREATE INDEX ix_sai_cnhtr_transaccion ON contabilidad_sai.cnhtr (cnhtrgest, cnhtrntra);
CREATE INDEX ix_sai_cndtr_transaccion ON contabilidad_sai.cndtr (cndtrgest, cndtrntra);
CREATE INDEX ix_sai_cnhht_transaccion ON contabilidad_sai.cnhht (cnhhtgest, cnhhtntra);
CREATE INDEX ix_sai_cnhdt_transaccion ON contabilidad_sai.cnhdt (cnhdtgest, cnhdtntra);
CREATE INDEX ix_sai_cndtrglo_linea ON contabilidad_sai.cndtrglo (cndtrntra, cndtritem);

-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION contabilidad.migrar_desde_sai(p_usuario text)
RETURNS TABLE (paso text, filas bigint, observacion text)
LANGUAGE plpgsql
SET search_path = contabilidad, pg_temp
AS $$
#variable_conflict use_column
DECLARE
    v_filas              bigint;
    v_cantidad           bigint;
    v_texto              text;
    v_gestion            record;
    v_inicio_abiertas    date;
    v_valor_previo       boolean;
BEGIN
    IF EXISTS (SELECT 1 FROM asiento) OR EXISTS (SELECT 1 FROM gestion) THEN
        RAISE EXCEPTION 'El esquema contabilidad ya tiene gestiones o asientos: la migración se corre una sola vez sobre el esquema vacío';
    END IF;
    -- Los asientos anulados en el SAI reciben sus líneas: se habilita la escritura interna durante la migración
    v_valor_previo := establecer_modificacion_cerrado(true);

    -- 1. Unidades de negocio --------------------------------------------------
    INSERT INTO unidad_negocio (codigo_unidad_negocio, nombre, usuario_creacion)
    SELECT DISTINCT ON (u.cnuneuneg) u.cnuneuneg, coalesce(nullif(btrim(u.cnunedesc), ''), format('UNIDAD %s', u.cnuneuneg)), p_usuario
    FROM contabilidad_sai.cnune u
    WHERE u.cnuneuneg IS NOT NULL
    ORDER BY u.cnuneuneg
    ON CONFLICT (codigo_unidad_negocio) DO UPDATE SET nombre = EXCLUDED.nombre;
    GET DIAGNOSTICS v_filas = ROW_COUNT;
    paso := '01 unidades de negocio (cnune)'; filas := v_filas; observacion := NULL; RETURN NEXT;

    INSERT INTO unidad_negocio (codigo_unidad_negocio, nombre, activo, usuario_creacion)
    SELECT x.unidad, format('UNIDAD %s (SAI, SIN DESCRIPCION)', x.unidad), false, p_usuario
    FROM (SELECT cndtruneg AS unidad FROM contabilidad_sai.cndtr
          UNION SELECT cnhdtuneg FROM contabilidad_sai.cnhdt
          UNION SELECT cntcnuneg FROM contabilidad_sai.cntcn
          UNION SELECT cnrucuneg FROM contabilidad_sai.cnruc) x
    WHERE x.unidad IS NOT NULL
    ON CONFLICT (codigo_unidad_negocio) DO NOTHING;
    GET DIAGNOSTICS v_filas = ROW_COUNT;
    paso := '01 unidades sin descripción en el SAI'; filas := v_filas; observacion := 'creadas inactivas'; RETURN NEXT;

    -- 2. Centros de costo -----------------------------------------------------
    INSERT INTO grupo_centro_costo (codigo_grupo_centro_costo, nombre)
    SELECT DISTINCT ON (s.cncsucsup) s.cncsucsup, coalesce(nullif(btrim(s.cncsudesc), ''), format('GRUPO %s', s.cncsucsup))
    FROM contabilidad_sai.cncsu s
    WHERE s.cncsucsup IS NOT NULL
    ORDER BY s.cncsucsup
    ON CONFLICT DO NOTHING;

    INSERT INTO centro_costo (codigo_centro_costo, nombre, codigo_grupo_centro_costo)
    SELECT DISTINCT ON (c.cnccoccos) c.cnccoccos, coalesce(nullif(btrim(c.cnccodesc), ''), format('CENTRO %s', c.cnccoccos)),
           (SELECT g.codigo_grupo_centro_costo FROM grupo_centro_costo g WHERE g.codigo_grupo_centro_costo = c.cnccocsup)
    FROM contabilidad_sai.cncco c
    WHERE c.cnccoccos IS NOT NULL
    ORDER BY c.cnccoccos
    ON CONFLICT (codigo_centro_costo) DO UPDATE SET nombre = EXCLUDED.nombre, codigo_grupo_centro_costo = EXCLUDED.codigo_grupo_centro_costo;
    GET DIAGNOSTICS v_filas = ROW_COUNT;
    paso := '02 centros de costo (cncco)'; filas := v_filas; observacion := NULL; RETURN NEXT;

    INSERT INTO centro_costo (codigo_centro_costo, nombre, activo)
    SELECT x.centro, format('CENTRO %s (SAI, SIN DESCRIPCION)', x.centro), false
    FROM (SELECT cndtrccos AS centro FROM contabilidad_sai.cndtr
          UNION SELECT cnhdtccos FROM contabilidad_sai.cnhdt
          UNION SELECT cntcnccos FROM contabilidad_sai.cntcn
          UNION SELECT cnrucccos FROM contabilidad_sai.cnruc) x
    WHERE x.centro IS NOT NULL
    ON CONFLICT (codigo_centro_costo) DO NOTHING;

    INSERT INTO unidad_negocio_centro_costo (codigo_unidad_negocio, codigo_centro_costo)
    SELECT DISTINCT r.cnrucuneg, r.cnrucccos
    FROM contabilidad_sai.cnruc r
    WHERE r.cnrucuneg IS NOT NULL AND r.cnrucccos IS NOT NULL
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_filas = ROW_COUNT;
    paso := '02 centros por unidad (cnruc)'; filas := v_filas; observacion := NULL; RETURN NEXT;

    -- 3. Tipos de documento y módulos -------------------------------------------
    INSERT INTO tipo_documento (codigo_tipo_documento, nombre)
    SELECT DISTINCT ON (t.cntdctdoc) t.cntdctdoc, coalesce(nullif(btrim(t.cntdcdesc), ''), format('TIPO DE DOCUMENTO %s', t.cntdctdoc))
    FROM contabilidad_sai.cntdc t
    WHERE t.cntdctdoc IS NOT NULL
    ORDER BY t.cntdctdoc
    ON CONFLICT (codigo_tipo_documento) DO NOTHING;

    INSERT INTO tipo_documento (codigo_tipo_documento, nombre)
    SELECT x.tipo, format('TIPO DE DOCUMENTO %s (SAI, SIN DESCRIPCION)', x.tipo)
    FROM (SELECT cnhtrtdoc AS tipo FROM contabilidad_sai.cnhtr UNION SELECT cnhhttdoc FROM contabilidad_sai.cnhht
          UNION SELECT cndtrtdoc FROM contabilidad_sai.cndtr UNION SELECT cnhdttdoc FROM contabilidad_sai.cnhdt) x
    WHERE x.tipo IS NOT NULL
    ON CONFLICT (codigo_tipo_documento) DO NOTHING;

    INSERT INTO modulo_origen (codigo_modulo, nombre, codigo_tipo_documento_defecto)
    SELECT x.modulo, format('MODULO %s (SAI, SIN DESCRIPCION)', x.modulo), 3
    FROM (SELECT cnhtrmorg AS modulo FROM contabilidad_sai.cnhtr UNION SELECT cnhhtmorg FROM contabilidad_sai.cnhht
          UNION SELECT cndtrmorg FROM contabilidad_sai.cndtr UNION SELECT cnhdtmorg FROM contabilidad_sai.cnhdt
          UNION SELECT cntcnmodn FROM contabilidad_sai.cntcn) x
    WHERE x.modulo IS NOT NULL
    ON CONFLICT (codigo_modulo) DO NOTHING;
    GET DIAGNOSTICS v_filas = ROW_COUNT;
    paso := '03 módulos de origen sin nombre'; filas := v_filas; observacion := 'revisar el nombre en contabilidad.modulo_origen'; RETURN NEXT;

    -- 4. Auxiliares (tcon / ncon) -------------------------------------------------
    INSERT INTO tipo_auxiliar (codigo_tipo_auxiliar, nombre)
    SELECT DISTINCT ON (x.tipo) x.tipo, x.nombre
    FROM (SELECT t.cntcotcon AS tipo, btrim(t.cntcodesc) AS nombre, 1 AS prioridad, 0 AS gestion FROM contabilidad_sai.cntco t
          UNION ALL
          SELECT h.cnhtctcon, btrim(h.cnhtcdesc), 2, h.cnhtcgest FROM contabilidad_sai.cnhtc h) x
    WHERE x.tipo IS NOT NULL AND x.tipo <> 0 AND coalesce(x.nombre, '') <> ''
    ORDER BY x.tipo, x.prioridad, x.gestion DESC
    ON CONFLICT DO NOTHING;

    INSERT INTO tipo_auxiliar (codigo_tipo_auxiliar, nombre)
    SELECT x.tipo, format('TIPO DE AUXILIAR %s (SAI, SIN DESCRIPCION)', x.tipo)
    FROM (SELECT cndtrtcon AS tipo FROM contabilidad_sai.cndtr UNION SELECT cnhdttcon FROM contabilidad_sai.cnhdt
          UNION SELECT cnplctcon FROM contabilidad_sai.cnplc) x
    WHERE x.tipo IS NOT NULL AND x.tipo <> 0
    ON CONFLICT DO NOTHING;

    INSERT INTO auxiliar_contable (codigo_tipo_auxiliar, codigo_auxiliar, nombre)
    SELECT DISTINCT ON (x.tipo, x.auxiliar) x.tipo, x.auxiliar, x.nombre
    FROM (SELECT c.cncnptcon AS tipo, c.cncnpncon AS auxiliar, btrim(c.cncnpdesc) AS nombre, 1 AS prioridad, 0 AS gestion FROM contabilidad_sai.cncnp c
          UNION ALL
          SELECT h.cnhcntcon, h.cnhcnncon, btrim(h.cnhcndesc), 2, h.cnhcngest FROM contabilidad_sai.cnhcn h) x
    JOIN tipo_auxiliar t ON t.codigo_tipo_auxiliar = x.tipo
    WHERE x.auxiliar IS NOT NULL AND coalesce(x.nombre, '') <> ''
    ORDER BY x.tipo, x.auxiliar, x.prioridad, x.gestion DESC
    ON CONFLICT DO NOTHING;

    INSERT INTO auxiliar_contable (codigo_tipo_auxiliar, codigo_auxiliar, nombre, activo)
    SELECT x.tipo, x.auxiliar, format('AUXILIAR %s-%s (SAI, SIN DESCRIPCION)', x.tipo, x.auxiliar), false
    FROM (SELECT cndtrtcon AS tipo, cndtrncon AS auxiliar FROM contabilidad_sai.cndtr
          UNION SELECT cnhdttcon, cnhdtncon FROM contabilidad_sai.cnhdt) x
    WHERE x.tipo IS NOT NULL AND x.tipo <> 0 AND x.auxiliar IS NOT NULL
    ON CONFLICT DO NOTHING;
    SELECT count(*) INTO v_filas FROM auxiliar_contable;
    paso := '04 auxiliares contables (cncnp, cnhcn)'; filas := v_filas; observacion := NULL; RETURN NEXT;

    -- 5. Plan de cuentas ------------------------------------------------------------
    CREATE TEMP TABLE tmp_cuenta_sai ON COMMIT DROP AS
    SELECT DISTINCT ON (x.codigo) x.codigo, x.nombre, x.moneda, x.exige_centro, x.tipo_auxiliar, x.activo
    FROM (
        SELECT btrim(p.cnplccnta) AS codigo, btrim(p.cnplcnomb) AS nombre, p.cnplccmon AS moneda, btrim(p.cnplcmcco) = 'S' AS exige_centro,
               p.cnplctcon AS tipo_auxiliar, true AS activo, 1 AS prioridad, 0 AS gestion
        FROM contabilidad_sai.cnplc p
        UNION ALL
        SELECT btrim(h.cnpchcnta), btrim(h.cnpchnomb), h.cnpchcmon, btrim(h.cnpchmcco) = 'S', h.cnpchtcon, false, 2, h.cnpchgest
        FROM contabilidad_sai.cnpch h
        UNION ALL
        SELECT btrim(m.codigo), NULL, NULL, false, NULL, false, 3, 0
        FROM (SELECT cndtrcnta AS codigo FROM contabilidad_sai.cndtr WHERE cndtrgest <> 0
              UNION SELECT cnhdtcnta FROM contabilidad_sai.cnhdt
              UNION SELECT cntcncctb FROM contabilidad_sai.cntcn WHERE cntcnpost = 0
              UNION SELECT cnprmcres FROM contabilidad_sai.cnprm UNION SELECT cnprmcrea FROM contabilidad_sai.cnprm
              UNION SELECT cnprmcaju FROM contabilidad_sai.cnprm UNION SELECT cnhprcres FROM contabilidad_sai.cnhpr
              UNION SELECT cnhprcrea FROM contabilidad_sai.cnhpr UNION SELECT cnhprcaju FROM contabilidad_sai.cnhpr) m
    ) x
    WHERE coalesce(x.codigo, '') <> ''
    ORDER BY x.codigo, x.prioridad, x.gestion DESC;

    SELECT string_agg(t.codigo, ', ' ORDER BY t.codigo) INTO v_texto
    FROM tmp_cuenta_sai t
    WHERE t.codigo !~ '^[1-9][0-9]*$' OR nivel_de_cuenta(t.codigo) IS NULL;
    IF v_texto IS NOT NULL THEN
        RAISE EXCEPTION 'Cuentas del SAI que no respetan la estructura del plan: %', v_texto
            USING HINT = 'Revise contabilidad.nivel_cuenta o corrija esas cuentas en el staging antes de migrar';
    END IF;

    -- Cuentas superiores que faltan (para que cada cuenta tenga su padre)
    INSERT INTO tmp_cuenta_sai (codigo, nombre, moneda, exige_centro, tipo_auxiliar, activo)
    WITH RECURSIVE superior (codigo) AS (
        SELECT cuenta_padre_de(t.codigo) FROM tmp_cuenta_sai t WHERE cuenta_padre_de(t.codigo) IS NOT NULL
        UNION
        SELECT cuenta_padre_de(s.codigo) FROM superior s WHERE cuenta_padre_de(s.codigo) IS NOT NULL
    )
    SELECT s.codigo, NULL, NULL, false, NULL, false
    FROM superior s
    WHERE NOT EXISTS (SELECT 1 FROM tmp_cuenta_sai t WHERE t.codigo = s.codigo);

    INSERT INTO cuenta_contable (codigo_cuenta, nombre, codigo_grupo, nivel, es_imputable, codigo_moneda, exige_centro_costo,
                                 codigo_tipo_auxiliar, activo, usuario_creacion)
    SELECT t.codigo,
           coalesce(nullif(t.nombre, ''), format('CUENTA %s (SAI, SIN DESCRIPCION)', t.codigo)),
           left(t.codigo, 1), nivel_de_cuenta(t.codigo), NULL,
           CASE WHEN t.moneda IN (1, 2) THEN t.moneda END,
           coalesce(t.exige_centro, false),
           (SELECT ta.codigo_tipo_auxiliar FROM tipo_auxiliar ta WHERE ta.codigo_tipo_auxiliar = t.tipo_auxiliar AND t.tipo_auxiliar <> 0),
           t.activo, p_usuario
    FROM tmp_cuenta_sai t
    ORDER BY nivel_de_cuenta(t.codigo), t.codigo;
    GET DIAGNOSTICS v_filas = ROW_COUNT;
    SELECT count(*) INTO v_cantidad FROM cuenta_contable c WHERE NOT c.activo;
    paso := '05 plan de cuentas (cnplc, cnpch y cuentas usadas)'; filas := v_filas;
    observacion := format('%s inactivas (solo en gestiones anteriores o sin descripción)', v_cantidad); RETURN NEXT;

    INSERT INTO cuenta_equivalencia (codigo_cuenta_origen, codigo_cuenta_destino)
    SELECT DISTINCT ON (btrim(r.cnrpcctao)) btrim(r.cnrpcctao), btrim(r.cnrpcctas)
    FROM contabilidad_sai.cnrpc r
    WHERE coalesce(btrim(r.cnrpcctao), '') <> '' AND coalesce(btrim(r.cnrpcctas), '') <> ''
    ORDER BY btrim(r.cnrpcctao);

    -- 6. Gestiones y períodos ---------------------------------------------------------
    FOR v_gestion IN
        SELECT DISTINCT ON (x.gestion) x.gestion, x.fecha_inicio, x.cuenta_resultado, x.cuenta_acumulado, x.cuenta_redondeo, x.centro
        FROM (
            SELECT h.cnhprgest::integer AS gestion, h.cnhprfini AS fecha_inicio, btrim(h.cnhprcres) AS cuenta_resultado,
                   btrim(h.cnhprcrea) AS cuenta_acumulado, nullif(btrim(h.cnhprcaju), '') AS cuenta_redondeo, h.cnhprccos AS centro, 1 AS prioridad
            FROM contabilidad_sai.cnhpr h
            UNION ALL
            SELECT extract(year FROM c.gestion)::integer, c.fecha_ini, btrim(p.cnprmcres), btrim(p.cnprmcrea), nullif(btrim(p.cnprmcaju), ''),
                   p.cnprmccos, 2
            FROM contabilidad_sai.cocierre c
            CROSS JOIN (SELECT * FROM contabilidad_sai.cnprm LIMIT 1) p
            UNION ALL
            SELECT y.gestion, make_date(y.gestion, 1, 1), btrim(p.cnprmcres), btrim(p.cnprmcrea), nullif(btrim(p.cnprmcaju), ''), p.cnprmccos, 3
            FROM (SELECT cnhtrgest::integer AS gestion FROM contabilidad_sai.cnhtr WHERE cnhtrgest <> 0
                  UNION SELECT cnhhtgest::integer FROM contabilidad_sai.cnhht) y
            CROSS JOIN (SELECT * FROM contabilidad_sai.cnprm LIMIT 1) p
        ) x
        WHERE x.gestion IS NOT NULL
        ORDER BY x.gestion, x.prioridad
    LOOP
        PERFORM crear_gestion(v_gestion.gestion, p_usuario, v_gestion.cuenta_resultado, v_gestion.cuenta_acumulado,
                              v_gestion.cuenta_redondeo, NULL, coalesce(extract(month FROM v_gestion.fecha_inicio)::integer, 1));
        UPDATE gestion g
        SET codigo_centro_costo_defecto = coalesce((SELECT cc.codigo_centro_costo FROM centro_costo cc WHERE cc.codigo_centro_costo = v_gestion.centro), 0)
        WHERE g.gestion = v_gestion.gestion;
    END LOOP;
    SELECT count(*) INTO v_filas FROM gestion;
    paso := '06 gestiones (cnhpr, cocierre)'; filas := v_filas; observacion := NULL; RETURN NEXT;

    -- 7. Asientos (cabecera) -------------------------------------------------------------
    INSERT INTO asiento (gestion, periodo, numero_asiento, fecha_contable, codigo_tipo_documento, codigo_modulo, numero_documento, glosa,
                         codigo_moneda_operacion, estado, origen, usuario_creacion, fecha_creacion,
                         usuario_anulacion, fecha_anulacion, motivo_anulacion, sai_numero_transaccion, sai_numero_correlativo)
    WITH glosa_actual AS (
        SELECT n.cnglontra AS ntra,
               string_agg(concat_ws(' ', btrim(n.cngloglo1), btrim(n.cngloglo2), btrim(n.cngloglo3), btrim(n.cngloglo4)), ' ' ORDER BY n.cngloitem) AS glosa
        FROM contabilidad_sai.cnglo n
        GROUP BY n.cnglontra
    ), glosa_historica AS (
        SELECT h.cnhglgest AS gestion, h.cnhglntra AS ntra,
               string_agg(concat_ws(' ', btrim(h.cnhglglo1), btrim(h.cnhglglo2), btrim(h.cnhglglo3), btrim(h.cnhglglo4)), ' ' ORDER BY h.cnhglitem) AS glosa
        FROM contabilidad_sai.cnhgl h
        GROUP BY h.cnhglgest, h.cnhglntra
    ), cabecera AS (
        -- Gestión abierta (cnhtr); el período 0 del SAI es la apertura
        SELECT h.cnhtrgest AS gestion, h.cnhtrntra AS ntra,
               CASE WHEN h.cnhtrcper BETWEEN 1 AND 12 THEN h.cnhtrcper ELSE 0 END AS periodo,
               coalesce(h.cnhtrfdoc, make_date(h.cnhtrgest, 1, 1)) AS fecha, coalesce(h.cnhtrtdoc, 3) AS tipo_documento,
               coalesce(h.cnhtrmorg, 2) AS modulo, h.cnhtrndoc AS numero_documento, h.cnhtrmrcb AS marca_baja,
               h.cnhtruser AS usuario, h.cnhtrfpro AS fecha_proceso, h.cnhtrnhtr AS correlativo, nullif(ga.glosa, '') AS glosa
        FROM contabilidad_sai.cnhtr h
        LEFT JOIN glosa_actual ga ON ga.ntra = h.cnhtrntra
        WHERE h.cnhtrgest <> 0
        UNION ALL
        -- Líneas de cndtr sin cabecera en cnhtr
        SELECT d.cndtrgest, d.cndtrntra,
               CASE WHEN min(d.cndtrcper) BETWEEN 1 AND 12 THEN min(d.cndtrcper) ELSE 0 END,
               coalesce(min(d.cndtrfdoc), make_date(d.cndtrgest, 1, 1)), coalesce(min(d.cndtrtdoc), 3), coalesce(min(d.cndtrmorg), 2),
               min(d.cndtrndoc), min(d.cndtrmrcb), NULL, NULL, min(d.cndtrnhtr), NULL
        FROM contabilidad_sai.cndtr d
        WHERE d.cndtrgest <> 0
          AND NOT EXISTS (SELECT 1 FROM contabilidad_sai.cnhtr h WHERE h.cnhtrgest = d.cndtrgest AND h.cnhtrntra = d.cndtrntra)
        GROUP BY d.cndtrgest, d.cndtrntra
        UNION ALL
        -- Histórico (cnhht): el SAI no guardaba el mes, se toma de la fecha
        SELECT h.cnhhtgest, h.cnhhtntra,
               CASE WHEN h.cnhhtcper BETWEEN 1 AND 12 THEN h.cnhhtcper
                    ELSE extract(month FROM coalesce(h.cnhhtfdoc, make_date(h.cnhhtgest, 1, 1)))::integer END,
               coalesce(h.cnhhtfdoc, make_date(h.cnhhtgest, 1, 1)), coalesce(h.cnhhttdoc, 3), coalesce(h.cnhhtmorg, 2),
               h.cnhhtndoc, h.cnhhtmrcb, h.cnhhtuser, h.cnhhtfpro, h.cnhhtnhtr, nullif(gh.glosa, '')
        FROM contabilidad_sai.cnhht h
        LEFT JOIN glosa_historica gh ON gh.gestion = h.cnhhtgest AND gh.ntra = h.cnhhtntra
        WHERE NOT EXISTS (SELECT 1 FROM contabilidad_sai.cnhtr x WHERE x.cnhtrgest = h.cnhhtgest)
        UNION ALL
        SELECT d.cnhdtgest, d.cnhdtntra,
               extract(month FROM coalesce(min(d.cnhdtfdoc), make_date(d.cnhdtgest, 1, 1)))::integer,
               coalesce(min(d.cnhdtfdoc), make_date(d.cnhdtgest, 1, 1)), coalesce(min(d.cnhdttdoc), 3), coalesce(min(d.cnhdtmorg), 2),
               min(d.cnhdtndoc), min(d.cnhdtmrcb), NULL, NULL, min(d.cnhdtnhtr), NULL
        FROM contabilidad_sai.cnhdt d
        WHERE NOT EXISTS (SELECT 1 FROM contabilidad_sai.cnhht h WHERE h.cnhhtgest = d.cnhdtgest AND h.cnhhtntra = d.cnhdtntra)
          AND NOT EXISTS (SELECT 1 FROM contabilidad_sai.cnhtr x WHERE x.cnhtrgest = d.cnhdtgest)
        GROUP BY d.cnhdtgest, d.cnhdtntra
    )
    SELECT c.gestion, c.periodo,
           row_number() OVER (PARTITION BY c.gestion ORDER BY c.fecha, c.ntra),
           c.fecha, c.tipo_documento, c.modulo, c.numero_documento, c.glosa, 1,
           CASE WHEN c.marca_baja = 9 THEN 'ANULADO' ELSE 'VIGENTE' END,
           'MIGRACION',
           coalesce(nullif(btrim(c.usuario), ''), p_usuario),
           coalesce(c.fecha_proceso::timestamptz, now()),
           CASE WHEN c.marca_baja = 9 THEN coalesce(nullif(btrim(c.usuario), ''), p_usuario) END,
           CASE WHEN c.marca_baja = 9 THEN coalesce(c.fecha_proceso::timestamptz, now()) END,
           CASE WHEN c.marca_baja = 9 THEN 'ANULADO EN EL SAI' END,
           c.ntra, c.correlativo
    FROM cabecera c;
    GET DIAGNOSTICS v_filas = ROW_COUNT;
    paso := '07 asientos (cnhtr, cnhht)'; filas := v_filas; observacion := NULL; RETURN NEXT;

    -- 8. Líneas ---------------------------------------------------------------------------
    INSERT INTO asiento_detalle (id_asiento, numero_linea, codigo_cuenta, glosa, importe_bs, importe_usd, codigo_moneda, tipo_cambio,
                                 codigo_unidad_negocio, codigo_centro_costo, codigo_tipo_auxiliar, codigo_auxiliar)
    SELECT a.id_asiento,
           row_number() OVER (PARTITION BY a.id_asiento ORDER BY l.item, l.codigo_cuenta, l.importe_bs)::integer,
           l.codigo_cuenta, l.glosa, coalesce(l.importe_bs, 0), coalesce(l.importe_usd, 0),
           CASE WHEN l.moneda IN (1, 2) THEN l.moneda ELSE 1 END,
           CASE WHEN l.tipo_cambio > 0 THEN l.tipo_cambio END,
           l.unidad, coalesce(l.centro, 0),
           CASE WHEN l.tipo_auxiliar <> 0 AND l.auxiliar IS NOT NULL THEN l.tipo_auxiliar END,
           CASE WHEN l.tipo_auxiliar <> 0 AND l.auxiliar IS NOT NULL THEN l.auxiliar END
    FROM (
        SELECT d.cndtrgest AS gestion, d.cndtrntra AS ntra, d.cndtritem AS item, btrim(d.cndtrcnta) AS codigo_cuenta,
               coalesce(gl.glosa, nullif(btrim(d.cndtrglos), '')) AS glosa, d.cndtrimpi AS importe_bs, d.cndtrimpc AS importe_usd,
               d.cndtrcmon AS moneda, d.cndtrcamb AS tipo_cambio, d.cndtruneg AS unidad, d.cndtrccos AS centro,
               d.cndtrtcon AS tipo_auxiliar, d.cndtrncon AS auxiliar, d.cndtrmrcb AS marca_baja
        FROM contabilidad_sai.cndtr d
        LEFT JOIN (SELECT g.cndtrntra, g.cndtritem, nullif(string_agg(btrim(g.glosa), ' ' ORDER BY g.apu), '') AS glosa
                   FROM contabilidad_sai.cndtrglo g
                   GROUP BY g.cndtrntra, g.cndtritem) gl ON gl.cndtrntra = d.cndtrntra AND gl.cndtritem = d.cndtritem
        WHERE d.cndtrgest <> 0
        UNION ALL
        SELECT d.cnhdtgest, d.cnhdtntra, d.cnhdtitem, btrim(d.cnhdtcnta), nullif(btrim(d.cnhdtglos), ''), d.cnhdtimpi, d.cnhdtimpc,
               d.cnhdtcmon, d.cnhdtcamb::numeric(18,8), d.cnhdtuneg, d.cnhdtccos, d.cnhdttcon, d.cnhdtncon, d.cnhdtmrcb
        FROM contabilidad_sai.cnhdt d
        WHERE NOT EXISTS (SELECT 1 FROM contabilidad_sai.cnhtr x WHERE x.cnhtrgest = d.cnhdtgest)
    ) l
    JOIN asiento a ON a.gestion = l.gestion AND a.sai_numero_transaccion = l.ntra
    WHERE l.marca_baja IS DISTINCT FROM 9 OR a.estado = 'ANULADO';
    GET DIAGNOSTICS v_filas = ROW_COUNT;
    paso := '08 líneas (cndtr, cnhdt)'; filas := v_filas; observacion := NULL; RETURN NEXT;

    SELECT count(*) INTO v_filas FROM contabilidad_sai.cndtr d WHERE d.cndtrgest = 0;
    paso := '08 líneas de la gestión 0 no migradas'; filas := v_filas; observacion := 'borrador de apertura del SAI (descuadrado)'; RETURN NEXT;

    SELECT count(*) INTO v_filas
    FROM (SELECT d.cndtrgest AS gestion, d.cndtrntra AS ntra FROM contabilidad_sai.cndtr d WHERE d.cndtrmrcb = 9 AND d.cndtrgest <> 0
          UNION ALL SELECT d.cnhdtgest, d.cnhdtntra FROM contabilidad_sai.cnhdt d WHERE d.cnhdtmrcb = 9) l
    JOIN asiento a ON a.gestion = l.gestion AND a.sai_numero_transaccion = l.ntra
    WHERE a.estado = 'VIGENTE';
    paso := '08 líneas dadas de baja no migradas'; filas := v_filas; observacion := 'mrcb = 9 dentro de asientos vigentes'; RETURN NEXT;

    -- 9. Estados de períodos y gestiones ----------------------------------------------------
    -- Gestiones con histórico: todo cerrado
    UPDATE periodo_contable p
    SET estado = 'CERRADO', usuario_cierre = p_usuario, fecha_cierre = now()
    WHERE p.gestion IN (SELECT h.cnhprgest FROM contabilidad_sai.cnhpr h);
    -- Gestiones abiertas: los meses según coperiodo (B = cerrado)
    UPDATE periodo_contable p
    SET estado = 'CERRADO', usuario_cierre = coalesce(nullif(btrim(c.usuario), ''), p_usuario),
        fecha_cierre = coalesce(c.fecha::timestamptz, now())
    FROM contabilidad_sai.coperiodo c
    WHERE p.gestion = extract(year FROM c.gestion)
      AND p.periodo = c.periodo
      AND p.periodo BETWEEN 1 AND 12
      AND btrim(c.estado) = 'B'
      AND p.estado = 'ABIERTO';
    -- El período 0 con apertura migrada queda cerrado
    UPDATE periodo_contable p
    SET estado = 'CERRADO', usuario_cierre = p_usuario, fecha_cierre = now()
    WHERE p.periodo = 0 AND p.estado = 'ABIERTO'
      AND EXISTS (SELECT 1 FROM asiento a WHERE a.gestion = p.gestion AND a.periodo = 0);
    SELECT count(*) INTO v_filas FROM periodo_contable p WHERE p.estado = 'CERRADO';
    paso := '09 períodos cerrados'; filas := v_filas; observacion := NULL; RETURN NEXT;

    -- 10. Días: cerrados si su mes está cerrado -------------------------------------------------
    INSERT INTO dia_contable (fecha_contable, gestion, periodo, estado, usuario_cierre, fecha_cierre)
    SELECT f.fecha_contable, p.gestion, p.periodo, p.estado,
           CASE WHEN p.estado = 'CERRADO' THEN p_usuario END,
           CASE WHEN p.estado = 'CERRADO' THEN now() END
    FROM (SELECT DISTINCT a.fecha_contable FROM asiento a WHERE a.periodo BETWEEN 1 AND 12) f
    JOIN periodo_contable p ON p.periodo BETWEEN 1 AND 12 AND f.fecha_contable BETWEEN p.fecha_inicio AND p.fecha_fin;
    GET DIAGNOSTICS v_filas = ROW_COUNT;
    SELECT count(DISTINCT a.fecha_contable) INTO v_cantidad
    FROM asiento a
    WHERE a.periodo BETWEEN 1 AND 12 AND NOT EXISTS (SELECT 1 FROM dia_contable d WHERE d.fecha_contable = a.fecha_contable);
    paso := '10 días contables'; filas := v_filas; observacion := format('%s fechas fuera de las gestiones creadas', v_cantidad); RETURN NEXT;

    INSERT INTO saldo_diario (fecha_contable, codigo_cuenta, codigo_unidad_negocio, codigo_centro_costo, debe_bs, haber_bs, debe_usd, haber_usd, cantidad_lineas)
    SELECT a.fecha_contable, d.codigo_cuenta, d.codigo_unidad_negocio, d.codigo_centro_costo,
           sum(greatest(d.importe_bs, 0)), sum(greatest(-d.importe_bs, 0)), sum(greatest(d.importe_usd, 0)), sum(greatest(-d.importe_usd, 0)), count(*)
    FROM asiento a
    JOIN asiento_detalle d ON d.id_asiento = a.id_asiento
    JOIN dia_contable dc ON dc.fecha_contable = a.fecha_contable AND dc.estado = 'CERRADO'
    WHERE a.periodo BETWEEN 1 AND 12 AND a.estado <> 'ANULADO'
    GROUP BY a.fecha_contable, d.codigo_cuenta, d.codigo_unidad_negocio, d.codigo_centro_costo;

    UPDATE dia_contable dc
    SET cantidad_asientos = t.asientos, total_debe_bs = t.debe_bs, total_debe_usd = t.debe_usd
    FROM (SELECT d.fecha_contable,
                 (SELECT count(*) FROM asiento a WHERE a.fecha_contable = d.fecha_contable AND a.periodo BETWEEN 1 AND 12 AND a.estado <> 'ANULADO') AS asientos,
                 coalesce((SELECT sum(s.debe_bs) FROM saldo_diario s WHERE s.fecha_contable = d.fecha_contable), 0) AS debe_bs,
                 coalesce((SELECT sum(s.debe_usd) FROM saldo_diario s WHERE s.fecha_contable = d.fecha_contable), 0) AS debe_usd
          FROM dia_contable d WHERE d.estado = 'CERRADO') t
    WHERE dc.fecha_contable = t.fecha_contable;

    -- 11. Saldos mensuales y gestiones históricas cerradas -------------------------------------
    FOR v_gestion IN SELECT g.gestion FROM gestion g ORDER BY g.gestion LOOP
        PERFORM recalcular_saldos_gestion(v_gestion.gestion);
    END LOOP;
    UPDATE gestion g
    SET estado = 'CERRADA', usuario_cierre = p_usuario, fecha_cierre = now()
    WHERE g.gestion IN (SELECT h.cnhprgest FROM contabilidad_sai.cnhpr h);
    SELECT count(*) INTO v_filas FROM saldo_mensual;
    paso := '11 saldos mensuales'; filas := v_filas; observacion := NULL; RETURN NEXT;

    UPDATE correlativo_asiento c
    SET ultimo_numero = x.ultimo
    FROM (SELECT a.gestion, max(a.numero_asiento) AS ultimo FROM asiento a GROUP BY a.gestion) x
    WHERE c.gestion = x.gestion;

    -- 12. Interfaz pendiente del SAI -----------------------------------------------------------
    SELECT min(g.fecha_inicio) INTO v_inicio_abiertas FROM gestion g WHERE g.estado = 'ABIERTA';
    INSERT INTO interfaz_comprobante (codigo_modulo, numero_documento, numero_linea, fecha_contable, codigo_cuenta, codigo_unidad_negocio,
                                      codigo_centro_costo, importe_bs, importe_usd, tipo_cambio, descripcion, descripcion_adicional,
                                      numero_operacion, numero_transaccion, fecha_transaccion, sai_grupo_transaccion, sai_codigo_transaccion,
                                      sai_cuenta_corriente, sai_subcuenta, estado, mensaje_error, usuario_creacion, fecha_creacion)
    SELECT t.cntcnmodn, t.cntcnndoc, t.cntcnitem, t.cntcnfreg, btrim(t.cntcncctb), t.cntcnuneg, coalesce(t.cntcnccos, 0),
           t.cntcnimpi, t.cntcnimpc, nullif(t.cntcntcam, 0), nullif(btrim(t.cntcndesc), ''), nullif(btrim(t.cntcncdin), ''),
           t.cntcnnopr, t.cntcnntra, t.cntcnftra, t.cntcnpref, t.cntcncorr, t.cntcnccta, t.cntcnscaa,
           CASE WHEN p.estado = 'CERRADO' THEN 'DESCARTADO' ELSE 'PENDIENTE' END,
           CASE WHEN p.estado = 'CERRADO' THEN 'Pendiente en el SAI con el mes ya cerrado: revisar y registrar un ajuste si corresponde' END,
           coalesce(nullif(btrim(t.cntcnuser), ''), p_usuario), coalesce(t.cntcnfpro::timestamptz, now())
    FROM contabilidad_sai.cntcn t
    JOIN periodo_contable p ON p.periodo BETWEEN 1 AND 12 AND t.cntcnfreg BETWEEN p.fecha_inicio AND p.fecha_fin
    WHERE t.cntcnpost = 0 AND t.cntcnfreg >= v_inicio_abiertas
    ON CONFLICT (codigo_modulo, numero_documento, numero_linea) DO NOTHING;
    GET DIAGNOSTICS v_filas = ROW_COUNT;
    SELECT count(*) INTO v_cantidad
    FROM contabilidad_sai.cntcn t
    WHERE t.cntcnpost = 0 AND (v_inicio_abiertas IS NULL OR t.cntcnfreg < v_inicio_abiertas);
    paso := '12 interfaz pendiente (cntcn post = 0)'; filas := v_filas;
    observacion := format('%s líneas anteriores a las gestiones abiertas, no migradas', v_cantidad); RETURN NEXT;

    PERFORM establecer_modificacion_cerrado(v_valor_previo);

    -- 13. Control ---------------------------------------------------------------------------
    FOR v_gestion IN
        SELECT x.gestion, count(*) AS cantidad, sum(abs(x.diferencia_bs)) AS diferencia
        FROM asientos_descuadrados() x
        GROUP BY x.gestion
        ORDER BY x.gestion
    LOOP
        paso := format('13 asientos descuadrados de %s', v_gestion.gestion); filas := v_gestion.cantidad;
        observacion := format('diferencia total Bs %s: corregir antes de cerrar la gestión', v_gestion.diferencia); RETURN NEXT;
    END LOOP;
END;
$$;
COMMENT ON FUNCTION contabilidad.migrar_desde_sai(text) IS
'Migra el módulo cn del SAI desde el staging contabilidad_sai al esquema contabilidad vacío y devuelve un informe por paso. Correr una sola vez dentro de una transacción';

REVOKE ALL ON FUNCTION contabilidad.migrar_desde_sai(text) FROM PUBLIC;

COMMIT;

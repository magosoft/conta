-- =============================================================================
-- Contabilidad · prueba de la migración desde el SAI
-- -----------------------------------------------------------------------------
-- Carga en contabilidad_sai un SAI en miniatura con los casos reales encontrados
-- en tbsai@online09: histórico por gestión (cnhht/cnhdt, 2022), apertura en el
-- período 0 (2023), líneas y asientos dados de baja (mrcb = 9), un asiento
-- descuadrado, borrador de la gestión 0 y cntcn sin contabilizar en meses
-- abiertos y cerrados. Migra, controla, corrige el descuadre, cierra 2023 y
-- verifica la apertura de 2024. Termina con ROLLBACK.
--
-- Uso, en una base de prueba con instalar.sql aplicado y el esquema contabilidad vacío:
--   psql -d <base_de_prueba> -f sql/postgres/contabilidad/pruebas/prueba_migracion_sai.sql
-- =============================================================================

\set ON_ERROR_STOP on
BEGIN;
SET client_min_messages = notice;

CREATE FUNCTION pg_temp.verificar(p_condicion boolean, p_mensaje text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_condicion IS NOT TRUE THEN
        RAISE EXCEPTION 'FALLA: %', p_mensaje;
    END IF;
    RAISE NOTICE 'ok   %', p_mensaje;
END;
$$;

CREATE FUNCTION pg_temp.debe_fallar(p_sql text, p_fragmento text, p_mensaje text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_error text;
BEGIN
    BEGIN
        EXECUTE p_sql;
        SET CONSTRAINTS ALL IMMEDIATE;
        SET CONSTRAINTS ALL DEFERRED;
    EXCEPTION
        WHEN OTHERS THEN
            v_error := SQLERRM;
    END;
    IF v_error IS NULL THEN
        RAISE EXCEPTION 'FALLA: % (se esperaba un error)', p_mensaje;
    END IF;
    IF position(p_fragmento IN v_error) = 0 THEN
        RAISE EXCEPTION 'FALLA: % (error inesperado: %)', p_mensaje, v_error;
    END IF;
    RAISE NOTICE 'ok   % → %', p_mensaje, v_error;
END;
$$;

-- -----------------------------------------------------------------------------
-- SAI en miniatura
-- -----------------------------------------------------------------------------
INSERT INTO contabilidad_sai.cnune VALUES (406, 'CIUDAD NUEVA SANTA CRUZ                 ', 1);
INSERT INTO contabilidad_sai.cncsu VALUES (1, 'CNSCZ');
INSERT INTO contabilidad_sai.cncco VALUES (1, 'ADMINISTRACION', 1), (2, 'COMERCIALIZACION', 1);
INSERT INTO contabilidad_sai.cnruc VALUES (406, 1), (406, 2);
INSERT INTO contabilidad_sai.cntdc VALUES (3, 'TRASPASOS'), (40, 'POSTEO DE LOTES');
INSERT INTO contabilidad_sai.cnplc (cnplccnta, cnplcnomb, cnplccmon, cnplcmcco, cnplctcon) VALUES
    ('10000000        ', 'ACTIVO', NULL, 'N', NULL), ('10100000', 'DISPONIBLE', NULL, 'N', NULL), ('10101000', 'CAJAS', NULL, 'N', NULL),
    ('10101010', 'CAJA MONEDA NACIONAL', 1, 'N', 0),
    ('30000000', 'PATRIMONIO', NULL, 'N', NULL), ('30400000', 'RESULTADOS', NULL, 'N', NULL),
    ('30401000', 'RESULTADOS ACUMULADOS', NULL, 'N', NULL), ('30401010', 'RESULTADOS ACUMULADOS', 1, 'N', 0),
    ('30402000', 'RESULTADO DE LA GESTION', NULL, 'N', NULL), ('30402010', 'RESULTADO DE LA GESTION', 1, 'N', 0),
    ('40000000', 'INGRESOS', NULL, 'N', NULL), ('40100000', 'INGRESOS OPERATIVOS', NULL, 'N', NULL),
    ('40101000', 'INGRESOS POR VENTAS', NULL, 'N', NULL), ('40101010', 'VENTA DE LOTES', 1, 'S', 0),
    ('50000000', 'GASTOS', NULL, 'N', NULL), ('50200000', 'GASTOS NO OPERATIVOS', NULL, 'N', NULL),
    ('50201000', 'CORRECCION MONETARIA', NULL, 'N', NULL), ('50201030', 'DIFCIA. DE REDONDEO', 1, 'S', 0);
INSERT INTO contabilidad_sai.cnpch (cnpchgest, cnpchcnta, cnpchnomb, cnpchcmon, cnpchmcco, cnpchtcon) VALUES (2022, '10101099', 'CAJA ANTIGUA', 1, 'N', 0);
INSERT INTO contabilidad_sai.cnprm (cnprmcres, cnprmcrea, cnprmcaju, cnprmccos) VALUES ('30402010', '30401010', '50201030', 1);
INSERT INTO contabilidad_sai.cnhpr (cnhprgest, cnhprpmes, cnhprumes, cnhprfini, cnhprffin, cnhprcres, cnhprcrea, cnhprcaju, cnhprccos)
    VALUES (2022, 1, 12, '2022-01-01', '2022-12-31', '30402010', '30401010', '50201030', 1);
INSERT INTO contabilidad_sai.cocierre VALUES ('2023-10-01', '2023-01-01', '2023-12-31', 'B', 'FHQ', '16:18:29', '2024-06-17'),
                                            ('2024-10-01', '2024-01-01', '2024-12-31', 'A', 'FHQ', '16:19:46', '2024-06-17');
INSERT INTO contabilidad_sai.coperiodo (gestion, periodo, i_fecha, f_fecha, des_peri, estado)
SELECT '2023-10-01'::date, m, make_date(2023, m, 1), (make_date(2023, m, 1) + interval '1 month - 1 day')::date, 'MES', 'B' FROM generate_series(1, 12) m
UNION ALL
SELECT '2024-10-01'::date, m, make_date(2024, m, 1), (make_date(2024, m, 1) + interval '1 month - 1 day')::date, 'MES', CASE WHEN m = 1 THEN 'B' ELSE 'A' END
FROM generate_series(1, 12) m;

-- 2022: histórico
INSERT INTO contabilidad_sai.cnhht (cnhhtgest, cnhhtntra, cnhhttdoc, cnhhtndoc, cnhhtfdoc, cnhhtmorg, cnhhtmrcb, cnhhtuser, cnhhtcper, cnhhtnhtr)
    VALUES (2022, 10, 3, 1, '2022-03-15', 2, 0, 'ADM', 0, 1);
INSERT INTO contabilidad_sai.cnhdt (cnhdtgest, cnhdtntra, cnhdttdoc, cnhdtfdoc, cnhdtmorg, cnhdtitem, cnhdtcnta, cnhdtglos, cnhdtimpi, cnhdtcmon, cnhdtcamb, cnhdtimpc,
                                    cnhdtuneg, cnhdtccos, cnhdttcon, cnhdtncon, cnhdtmrcb, cnhdtcper)
    VALUES (2022, 10, 3, '2022-03-15', 2, 1, '10101099', 'VENTA', 100, 1, 6.96, 14.37, 406, 0, 0, 0, 0, 0),
           (2022, 10, 3, '2022-03-15', 2, 2, '40101010', 'VENTA', -100, 1, 6.96, -14.37, 406, 2, 0, 0, 0, 0);

-- 2023 y 2024: gestión abierta (cnhtr / cndtr)
INSERT INTO contabilidad_sai.cnhtr (cnhtrntra, cnhtrtdoc, cnhtrndoc, cnhtrfdoc, cnhtrmorg, cnhtrmrcb, cnhtruser, cnhtrgest, cnhtrcper, cnhtrnhtr) VALUES
    (500, 3, 1, '2023-01-01', 2, 0, 'FHQ', 2023, 0, 1),
    (501, 40, 9001, '2023-02-10', 40, 0, 'FHQ', 2023, 2, 2),
    (502, 40, 9002, '2023-02-11', 40, 9, 'FHQ', 2023, 2, 3),
    (503, 40, 9003, '2023-05-05', 40, 0, 'FHQ', 2023, 5, 4),
    (600, 40, 9100, '2024-01-15', 40, 0, 'MAA', 2024, 1, 1),
    (601, 40, 9101, '2024-03-03', 40, 0, 'MAA', 2024, 3, 2);
INSERT INTO contabilidad_sai.cndtr (cndtrntra, cndtrtdoc, cndtrfdoc, cndtrmorg, cndtritem, cndtrcnta, cndtrglos, cndtrimpi, cndtrcmon, cndtrcamb, cndtrimpc,
                                    cndtruneg, cndtrccos, cndtrtcon, cndtrncon, cndtrmrcb, cndtrgest, cndtrcper) VALUES
    (500, 3, '2023-01-01', 2, 1, '10101010', 'APERTURA', 100, 1, 6.96, 14.37, 406, 0, 0, 0, 0, 2023, 0),
    (500, 3, '2023-01-01', 2, 2, '30401010', 'APERTURA', -100, 1, 6.96, -14.37, 406, 0, 0, 0, 0, 2023, 0),
    (501, 40, '2023-02-10', 40, 1, '10101010', 'COBRO', 50, 1, 6.96, 7.18, 406, 0, 0, 0, 0, 2023, 2),
    (501, 40, '2023-02-10', 40, 2, '40101010', 'COBRO', -50, 1, 6.96, -7.18, 406, 2, 0, 0, 0, 2023, 2),
    (501, 40, '2023-02-10', 40, 3, '10101010', 'LINEA DE BAJA', 999, 1, 6.96, 143.53, 406, 0, 0, 0, 9, 2023, 2),
    (502, 40, '2023-02-11', 40, 1, '10101010', 'ANULADO', 20, 1, 6.96, 2.87, 406, 0, 0, 0, 0, 2023, 2),
    (502, 40, '2023-02-11', 40, 2, '40101010', 'ANULADO', -20, 1, 6.96, -2.87, 406, 2, 0, 0, 0, 2023, 2),
    (503, 40, '2023-05-05', 40, 1, '10101010', 'DESCUADRADO', 10, 1, 6.96, 1.44, 406, 0, 0, 0, 0, 2023, 5),
    (503, 40, '2023-05-05', 40, 2, '40101010', 'DESCUADRADO', -9, 1, 6.96, -1.29, 406, 2, 0, 0, 0, 2023, 5),
    (600, 40, '2024-01-15', 40, 1, '10101010', 'COBRO', 30, 1, 6.96, 4.31, 406, 0, 0, 0, 0, 2024, 1),
    (600, 40, '2024-01-15', 40, 2, '40101010', 'COBRO', -30, 1, 6.96, -4.31, 406, 2, 0, 0, 0, 2024, 1),
    (601, 40, '2024-03-03', 40, 1, '10101010', 'COBRO', 40, 1, 6.96, 5.75, 406, 0, 0, 0, 0, 2024, 3),
    (601, 40, '2024-03-03', 40, 2, '40101010', 'COBRO', -40, 1, 6.96, -5.75, 406, 2, 0, 0, 0, 2024, 3),
    (999, 88, '2024-01-01', 2, 1, '10101010', 'BORRADOR', 5, 1, 6.96, 0.72, 406, 0, 0, 0, 0, 0, 0);
INSERT INTO contabilidad_sai.cndtrglo VALUES (501, 1, 1, 'COBRO CUOTA LOTE'), (501, 1, 2, 'UV 1 MZ 2');
INSERT INTO contabilidad_sai.cnglo VALUES (501, 1, 'GLOSA', 'ADICIONAL', NULL, NULL);

-- cntcn: pendiente en mes abierto, pendiente en mes cerrado, pendiente viejo y contabilizado
INSERT INTO contabilidad_sai.cntcn (cntcnndoc, cntcnitem, cntcnfreg, cntcnpref, cntcncorr, cntcncctb, cntcnuneg, cntcnccos, cntcnccta, cntcnscaa,
                                    cntcndesc, cntcnimpi, cntcnimpc, cntcntcam, cntcnpost, cntcnmodn, cntcnnopr, cntcnntra, cntcnftra, cntcnuser) VALUES
    (7001, 1, '2024-03-10', 27, 2, '10101010', 406, 0, 0, 0, 'COBRO', 70, 10.06, 6.96, 0, 40, 123, 1, '2024-03-10', 'CEV'),
    (7001, 2, '2024-03-10', 27, 2, '40101010', 406, 2, 0, 0, 'COBRO', -70, -10.06, 6.96, 0, 40, 123, 1, '2024-03-10', 'CEV'),
    (7002, 1, '2024-01-20', 27, 2, '10101010', 406, 0, 0, 0, 'COBRO', 15, 2.16, 6.96, 0, 40, 124, 2, '2024-01-20', 'CEV'),
    (7002, 2, '2024-01-20', 27, 2, '40101010', 406, 2, 0, 0, 'COBRO', -15, -2.16, 6.96, 0, 40, 124, 2, '2024-01-20', 'CEV'),
    (6001, 1, '2019-05-05', 27, 2, '10101010', 406, 0, 0, 0, 'VIEJO', 1, 0.14, 6.96, 0, 40, 1, 1, '2019-05-05', 'ADM'),
    (6002, 1, '2024-03-03', 27, 2, '10101010', 406, 0, 0, 0, 'YA POSTEADO', 40, 5.75, 6.96, 9, 40, 1, 1, '2024-03-03', 'ADM');

-- -----------------------------------------------------------------------------
-- Migración
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE prueba_informe AS SELECT * FROM contabilidad.migrar_desde_sai('migracion');
SELECT paso, filas, observacion FROM prueba_informe;

SELECT pg_temp.verificar((SELECT estado = 'CERRADA' FROM contabilidad.gestion WHERE gestion = 2022), '2022 (histórico del SAI) queda cerrada');
SELECT pg_temp.verificar((SELECT estado = 'ABIERTA' FROM contabilidad.gestion WHERE gestion = 2023)
                         AND (SELECT count(*) = 13 FROM contabilidad.periodo_contable WHERE gestion = 2023 AND periodo BETWEEN 0 AND 12 AND estado = 'CERRADO'),
       '2023 queda abierta, con la apertura y los 12 meses cerrados como en coperiodo');
SELECT pg_temp.verificar((SELECT array_agg(periodo ORDER BY periodo) = ARRAY[1]::smallint[] FROM contabilidad.periodo_contable WHERE gestion = 2024 AND estado = 'CERRADO'),
       '2024 tiene cerrado solo enero, y su período 0 abierto para la apertura');
SELECT pg_temp.verificar((SELECT count(*) = 7 AND count(*) FILTER (WHERE estado = 'ANULADO') = 1 FROM contabilidad.asiento),
       'se migran 7 asientos, uno de ellos anulado en el SAI');
SELECT pg_temp.verificar((SELECT count(*) = 2 AND bool_and(d.glosa = 'COBRO CUOTA LOTE UV 1 MZ 2' OR d.numero_linea = 2)
                          FROM contabilidad.asiento_detalle d JOIN contabilidad.asiento a ON a.id_asiento = d.id_asiento
                          WHERE a.sai_numero_transaccion = 501),
       'el asiento 501 trae sus 2 líneas vigentes (sin la dada de baja) y la glosa larga de cndtrglo');
SELECT pg_temp.verificar((SELECT glosa = 'GLOSA ADICIONAL' FROM contabilidad.asiento WHERE sai_numero_transaccion = 501), 'la glosa de cnglo queda en la cabecera');
SELECT pg_temp.verificar((SELECT periodo = 0 FROM contabilidad.asiento WHERE sai_numero_transaccion = 500), 'el período 0 del SAI es la apertura de 2023');
SELECT pg_temp.verificar((SELECT periodo = 3 FROM contabilidad.asiento WHERE gestion = 2022 AND sai_numero_transaccion = 10), 'el histórico toma el mes de la fecha (marzo)');
SELECT pg_temp.verificar((SELECT NOT activo FROM contabilidad.cuenta_contable WHERE codigo_cuenta = '10101099'), 'la cuenta que solo está en cnpch queda inactiva');
SELECT pg_temp.verificar((SELECT count(*) = 0 FROM contabilidad.asiento WHERE sai_numero_transaccion = 999), 'el borrador de la gestión 0 no se migra');
SELECT pg_temp.verificar((SELECT count(*) = 1 FROM contabilidad.asientos_descuadrados() WHERE id_asiento = (SELECT id_asiento FROM contabilidad.asiento WHERE sai_numero_transaccion = 503)),
       'el asiento 503 aparece en el control de descuadres');
SELECT pg_temp.verificar((SELECT count(*) FILTER (WHERE numero_documento = 7001 AND estado = 'PENDIENTE') = 2
                                 AND count(*) FILTER (WHERE numero_documento = 7002 AND estado = 'DESCARTADO') = 2
                                 AND count(*) FILTER (WHERE numero_documento IN (6001, 6002)) = 0
                          FROM contabilidad.interfaz_comprobante),
       'cntcn: lo pendiente de marzo 2024 pasa a la interfaz, lo de enero (cerrado) queda descartado y lo viejo o ya posteado no se migra');
SELECT pg_temp.verificar((SELECT estado = 'CERRADO' FROM contabilidad.dia_contable WHERE fecha_contable = '2023-02-10')
                         AND (SELECT estado = 'ABIERTO' FROM contabilidad.dia_contable WHERE fecha_contable = '2024-03-03'),
       'los días de meses cerrados quedan cerrados y los de meses abiertos, abiertos');
SELECT pg_temp.verificar((SELECT saldo_final_bs = 160 FROM contabilidad.saldo_mensual WHERE gestion = 2023 AND periodo = 12 AND codigo_cuenta = '10101010'),
       'la caja termina 2023 con 160 Bs (100 de apertura + 50 + 10; el anulado no cuenta)');
SELECT pg_temp.verificar((SELECT ultimo_numero = 4 FROM contabilidad.correlativo_asiento WHERE gestion = 2023), 'el correlativo de 2023 sigue después de lo migrado');
SELECT pg_temp.debe_fallar($$SELECT * FROM contabilidad.migrar_desde_sai('otra vez')$$, 'una sola vez', 'la migración no se puede correr dos veces');

-- -----------------------------------------------------------------------------
-- Después de migrar: corregir el descuadre, cerrar 2023 y abrir 2024
-- -----------------------------------------------------------------------------
SELECT pg_temp.debe_fallar($$SELECT contabilidad.cerrar_gestion(2023, 'prueba')$$, 'no cuadra', 'con un asiento descuadrado la apertura de 2024 no cuadra y el cierre se rechaza');
SELECT pg_temp.debe_fallar(format($$SELECT contabilidad.ajustar_asiento_migrado(%s, '[{"codigo_cuenta": "40101010", "importe_bs": -1, "importe_usd": -0.15, "codigo_unidad_negocio": 406}]', 'prueba', 'falta 1 Bs del cobro')$$,
                                  (SELECT id_asiento FROM contabilidad.asiento WHERE sai_numero_transaccion = 503)),
    'Reabra el período 5', 'un asiento migrado se ajusta con su mes reabierto');

DO $$
BEGIN
    FOR v_mes IN REVERSE 12..5 LOOP
        PERFORM contabilidad.reabrir_periodo(2023, v_mes, 'prueba', 'corregir el asiento 503 migrado');
    END LOOP;
END;
$$;
SELECT pg_temp.verificar((SELECT contabilidad.ajustar_asiento_migrado((SELECT id_asiento FROM contabilidad.asiento WHERE sai_numero_transaccion = 503),
                                  '[{"codigo_cuenta": "40101010", "importe_bs": -1, "importe_usd": -0.15, "codigo_unidad_negocio": 406}]', 'prueba', 'falta 1 Bs del cobro') = 1),
       'el asiento 503 se completa con la línea que faltaba');
SELECT pg_temp.verificar((SELECT count(*) = 0 FROM contabilidad.asientos_descuadrados(2023)), 'ya no hay descuadres en 2023');
DO $$
BEGIN
    FOR v_mes IN 5..12 LOOP
        PERFORM contabilidad.cerrar_periodo(2023, v_mes, 'prueba');
    END LOOP;
END;
$$;

CREATE TEMP TABLE prueba_cierre AS SELECT contabilidad.cerrar_gestion(2023, 'prueba') AS resultado;
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
SELECT pg_temp.verificar((SELECT (resultado->>'resultado_bs')::numeric = 60 FROM prueba_cierre), 'el resultado de 2023 es una utilidad de 60 Bs (50 + 10)');
SELECT pg_temp.verificar((SELECT sum(d.importe_bs) FILTER (WHERE d.codigo_cuenta = '10101010') = 160
                                 AND sum(d.importe_bs) FILTER (WHERE d.codigo_cuenta = '30401010') = -160
                          FROM contabilidad.asiento_detalle d JOIN contabilidad.asiento a ON a.id_asiento = d.id_asiento
                          WHERE a.gestion = 2024 AND a.tipo_asiento_sistema = 'APERTURA' AND a.estado = 'VIGENTE'),
       'la apertura de 2024 trae la caja de 160 Bs y 160 Bs de resultados acumulados (100 + utilidad 60)');
SELECT pg_temp.verificar((SELECT saldo_inicial_bs = 160 AND saldo_final_bs = 190 FROM contabilidad.saldo_mensual
                          WHERE gestion = 2024 AND periodo = 1 AND codigo_cuenta = '10101010'),
       'enero de 2024 (ya cerrado al migrar) se recalcula con la apertura: 160 + 30 = 190 Bs');

ROLLBACK;
\echo 'Prueba de la migración terminada sin fallas (todo se deshizo con ROLLBACK)'

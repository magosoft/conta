-- =============================================================================
-- Contabilidad · prueba del ciclo completo
-- -----------------------------------------------------------------------------
-- Registro, interfaz, cierre diario, reversión, revaluación y cierre mensual,
-- reportes, cierre anual con apertura, reapertura y cuadre diferido.
-- No deja datos: todo corre en una transacción que termina con ROLLBACK.
--
-- Uso, en una base de prueba con instalar.sql aplicado:
--   psql -d <base_de_prueba> -f sql/postgres/contabilidad/pruebas/prueba_ciclo_contable.sql
-- Cada control imprime "ok ..."; el primero que falla corta la prueba con "FALLA: ...".
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

-- Ejecuta p_sql y exige que falle con un mensaje que contenga p_fragmento (también por el cuadre diferido)
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

-- Fuerza los controles diferidos (cuadre) como si se confirmara la transacción
CREATE FUNCTION pg_temp.confirmar_restricciones() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;
END;
$$;

CREATE TEMP TABLE prueba_id (nombre text PRIMARY KEY, id bigint);
CREATE TEMP TABLE prueba_resultado (nombre text PRIMARY KEY, resultado jsonb);

-- -----------------------------------------------------------------------------
-- Datos base
-- -----------------------------------------------------------------------------
INSERT INTO contabilidad.unidad_negocio (codigo_unidad_negocio, nombre) VALUES
    (406, 'CIUDAD NUEVA SANTA CRUZ'), (410, 'TERRENOS EN CONDOMINIOS');
INSERT INTO contabilidad.centro_costo (codigo_centro_costo, nombre) VALUES
    (1, 'ADMINISTRACION'), (2, 'COMERCIALIZACION'), (3, 'OBRAS Y PROYECTOS');
INSERT INTO contabilidad.unidad_negocio_centro_costo (codigo_unidad_negocio, codigo_centro_costo) VALUES (406, 1), (406, 2);

INSERT INTO contabilidad.cuenta_contable (codigo_cuenta, nombre, codigo_moneda, exige_centro_costo) VALUES
    ('10000000', 'ACTIVO', NULL, false),
    ('10100000', 'DISPONIBLE', NULL, false),
    ('10101000', 'CAJAS', NULL, false),
    ('10101010', 'CAJA MONEDA NACIONAL', 1, false),
    ('10101011', 'CAJA MONEDA EXTRANJERA', 2, false),
    ('10200000', 'EXIGIBLE', NULL, false),
    ('10204000', 'CUENTAS POR COBRAR CLIENTES', NULL, false),
    ('10204011', 'CTAS. POR COBRAR CLIENTES M/E', 2, false),
    ('30000000', 'PATRIMONIO', NULL, false),
    ('30400000', 'RESULTADOS', NULL, false),
    ('30401000', 'RESULTADOS ACUMULADOS', NULL, false),
    ('30401010', 'RESULTADOS ACUMULADOS', 1, false),
    ('30402000', 'RESULTADO DE LA GESTION', NULL, false),
    ('30402010', 'RESULTADO DE LA GESTION', 1, false),
    ('40000000', 'INGRESOS', NULL, false),
    ('40100000', 'INGRESOS OPERATIVOS', NULL, false),
    ('40101000', 'INGRESOS POR VENTAS', NULL, false),
    ('40101010', 'VENTA DE LOTES', 1, true),
    ('50000000', 'GASTOS', NULL, false),
    ('50100000', 'GASTOS OPERATIVOS', NULL, false),
    ('50103000', 'GASTOS GENERALES', NULL, false),
    ('50103010', 'GASTOS GENERALES VARIOS', 1, true),
    ('50200000', 'GASTOS NO OPERATIVOS', NULL, false),
    ('50201000', 'CORRECCION MONETARIA', NULL, false),
    ('50201020', 'DIFERENCIA DE CAMBIO', 1, false),
    ('50201030', 'DIFERENCIA DE REDONDEO', 1, false);

INSERT INTO contabilidad.tipo_cambio (fecha, codigo_moneda, tipo_cambio_oficial) VALUES ('2026-01-01', 2, 6.96), ('2026-01-31', 2, 7.00);

-- -----------------------------------------------------------------------------
-- 1. Plan de cuentas
-- -----------------------------------------------------------------------------
SELECT pg_temp.verificar((SELECT nivel = 4 AND codigo_cuenta_padre = '10101000' AND es_imputable FROM contabilidad.cuenta_contable WHERE codigo_cuenta = '10101010'),
       'la cuenta 10101010 es de nivel 4, imputable y su padre es 10101000');
SELECT pg_temp.verificar((SELECT nivel = 2 AND codigo_cuenta_padre = '10000000' AND NOT es_imputable FROM contabilidad.cuenta_contable WHERE codigo_cuenta = '10100000'),
       'la cuenta 10100000 es de nivel 2 y no es imputable');
SELECT pg_temp.debe_fallar($$INSERT INTO contabilidad.cuenta_contable (codigo_cuenta, nombre) VALUES ('1010101', 'MAL')$$,
       'no respeta la estructura', 'una cuenta de 7 dígitos no entra en el plan');

-- -----------------------------------------------------------------------------
-- 2. Gestión
-- -----------------------------------------------------------------------------
SELECT contabilidad.crear_gestion(2026, 'prueba', '30402010', '30401010', '50201030', '50201020');
UPDATE contabilidad.gestion SET revaluar_moneda_extranjera = true WHERE gestion = 2026;
SELECT pg_temp.verificar((SELECT count(*) = 14 FROM contabilidad.periodo_contable WHERE gestion = 2026), 'la gestión 2026 tiene 14 períodos (0, 1-12, 13)');
SELECT pg_temp.verificar((SELECT nombre = 'FEBRERO 2026' AND fecha_fin = '2026-02-28' FROM contabilidad.periodo_contable WHERE gestion = 2026 AND periodo = 2),
       'febrero de 2026 termina el 28');

-- -----------------------------------------------------------------------------
-- 3. Asientos manuales
-- -----------------------------------------------------------------------------
INSERT INTO prueba_id SELECT 'venta_usd', contabilidad.registrar_asiento('2026-01-05', 1, 'VENTA AL CONTADO EN USD',
    '[{"codigo_cuenta": "10101011", "importe_usd": 1000, "codigo_unidad_negocio": 406},
      {"codigo_cuenta": "40101010", "importe_usd": -1000, "codigo_unidad_negocio": 406, "codigo_centro_costo": 2}]', 'prueba', 2, NULL, 2);
SELECT pg_temp.confirmar_restricciones();
SELECT pg_temp.verificar((SELECT sum(importe_bs) = 0 AND max(importe_bs) = 6960 FROM contabilidad.asiento_detalle
                          WHERE id_asiento = (SELECT id FROM prueba_id WHERE nombre = 'venta_usd')),
       'la venta de 1000 USD se registra en 6960 Bs con el TC 6,96');

INSERT INTO prueba_id SELECT 'gasto_bs', contabilidad.registrar_asiento('2026-01-05', 2, 'GASTOS VARIOS',
    '[{"codigo_cuenta": "50103010", "importe_bs": 10, "codigo_unidad_negocio": 406, "codigo_centro_costo": 1},
      {"codigo_cuenta": "50103010", "importe_bs": 10, "codigo_unidad_negocio": 406, "codigo_centro_costo": 1},
      {"codigo_cuenta": "50103010", "importe_bs": 10, "codigo_unidad_negocio": 406, "codigo_centro_costo": 1},
      {"codigo_cuenta": "10101010", "importe_bs": -30, "codigo_unidad_negocio": 406}]', 'prueba');
SELECT pg_temp.confirmar_restricciones();
SELECT pg_temp.verificar((SELECT count(*) = 5 AND sum(importe_usd) = 0 AND bool_or(codigo_cuenta = '50201030' AND importe_usd = -0.01)
                          FROM contabilidad.asiento_detalle WHERE id_asiento = (SELECT id FROM prueba_id WHERE nombre = 'gasto_bs')),
       'la diferencia de redondeo de 0,01 USD se lleva a la cuenta 50201030');

SELECT pg_temp.debe_fallar($$SELECT contabilidad.registrar_asiento('2026-01-05', 3, 'DESCUADRADO',
    '[{"codigo_cuenta": "10101010", "importe_bs": 100, "codigo_unidad_negocio": 406},
      {"codigo_cuenta": "40101010", "importe_bs": -90, "codigo_unidad_negocio": 406, "codigo_centro_costo": 2}]', 'prueba')$$,
    'no cuadra en Bs', 'un asiento descuadrado se rechaza');
SELECT pg_temp.debe_fallar($$SELECT contabilidad.registrar_asiento('2026-01-05', 2, 'SIN CENTRO',
    '[{"codigo_cuenta": "50103010", "importe_bs": 10, "codigo_unidad_negocio": 406},
      {"codigo_cuenta": "10101010", "importe_bs": -10, "codigo_unidad_negocio": 406}]', 'prueba')$$,
    'exige centro de costo', 'una cuenta de gasto exige centro de costo');
SELECT pg_temp.debe_fallar($$SELECT contabilidad.registrar_asiento('2026-01-05', 2, 'CENTRO NO HABILITADO',
    '[{"codigo_cuenta": "50103010", "importe_bs": 10, "codigo_unidad_negocio": 406, "codigo_centro_costo": 3},
      {"codigo_cuenta": "10101010", "importe_bs": -10, "codigo_unidad_negocio": 406}]', 'prueba')$$,
    'no está habilitado para la unidad 406', 'el centro 3 no está habilitado para la unidad 406');
SELECT pg_temp.debe_fallar($$SELECT contabilidad.registrar_asiento('2026-01-05', 3, 'CUENTA DE NIVEL 3',
    '[{"codigo_cuenta": "10101000", "importe_bs": 10, "codigo_unidad_negocio": 406},
      {"codigo_cuenta": "10101010", "importe_bs": -10, "codigo_unidad_negocio": 406}]', 'prueba')$$,
    'no es imputable', 'una cuenta de nivel 3 no recibe movimientos');
SELECT pg_temp.debe_fallar($$SELECT contabilidad.registrar_asiento('2026-01-05', 88, 'APERTURA A MANO',
    '[{"codigo_cuenta": "10101010", "importe_bs": 10, "codigo_unidad_negocio": 406},
      {"codigo_cuenta": "30401010", "importe_bs": -10, "codigo_unidad_negocio": 406}]', 'prueba')$$,
    'lo generan solo los cierres', 'el tipo de documento de apertura es del sistema');

-- -----------------------------------------------------------------------------
-- 4. Interfaz con los módulos y cierre diario
-- -----------------------------------------------------------------------------
INSERT INTO contabilidad.interfaz_comprobante (codigo_modulo, numero_documento, numero_linea, fecha_contable, codigo_cuenta, codigo_unidad_negocio,
                                               codigo_moneda_operacion, importe_bs, importe_usd, tipo_cambio, descripcion) VALUES
    (40, 1001, 1, '2026-01-05', '10101011', 406, 2, 3480, 500, 6.96, 'COBRO DE CUOTA'),
    (40, 1001, 2, '2026-01-05', '10204011', 406, 2, -3480, -500, 6.96, 'COBRO DE CUOTA'),
    (40, 1002, 1, '2026-01-05', '10101010', 406, 1, 100, 14.37, 6.96, 'COBRO EN BS'),
    (40, 1002, 2, '2026-01-05', '40101010', 406, 1, -90, -12.93, 6.96, 'COBRO EN BS');

INSERT INTO prueba_resultado SELECT 'dia_5_intento_1', contabilidad.cerrar_dia('2026-01-05', 'prueba');
SELECT pg_temp.verificar((SELECT resultado->>'cerrado' = 'false' AND (resultado->>'documentos_con_error')::integer = 1
                                 AND (resultado->>'documentos_contabilizados')::integer = 1
                          FROM prueba_resultado WHERE nombre = 'dia_5_intento_1'),
       'el día no cierra con un documento de interfaz descuadrado; el otro queda contabilizado');
SELECT pg_temp.verificar((SELECT estado = 'ERROR' AND mensaje_error LIKE '%no cuadra en Bs%' FROM contabilidad.interfaz_comprobante
                          WHERE numero_documento = 1002 AND numero_linea = 1),
       'el documento 1002 queda en ERROR con el motivo');
SELECT pg_temp.debe_fallar($$UPDATE contabilidad.interfaz_comprobante SET importe_bs = 1 WHERE numero_documento = 1001 AND numero_linea = 1$$,
    'ya está contabilizada', 'una línea de interfaz contabilizada no se modifica');

UPDATE contabilidad.interfaz_comprobante SET importe_bs = -100, importe_usd = -14.37 WHERE numero_documento = 1002 AND numero_linea = 2;
INSERT INTO prueba_resultado SELECT 'dia_5_intento_2', contabilidad.cerrar_dia('2026-01-05', 'prueba');
SELECT pg_temp.confirmar_restricciones();
SELECT pg_temp.verificar((SELECT resultado->>'cerrado' = 'true' FROM prueba_resultado WHERE nombre = 'dia_5_intento_2'),
       'corregida la interfaz, el 5 de enero cierra');
SELECT pg_temp.verificar((SELECT estado = 'CERRADO' AND total_debe_bs = 10570 FROM contabilidad.dia_contable WHERE fecha_contable = '2026-01-05'),
       'el día cerrado guarda su total de control (10570 Bs al debe)');

SELECT pg_temp.debe_fallar($$SELECT contabilidad.registrar_asiento('2026-01-05', 3, 'FUERA DE HORA',
    '[{"codigo_cuenta": "10101010", "importe_bs": 5, "codigo_unidad_negocio": 406},
      {"codigo_cuenta": "40101010", "importe_bs": -5, "codigo_unidad_negocio": 406, "codigo_centro_costo": 2}]', 'prueba')$$,
    'está cerrado', 'no se registra en un día cerrado');
SELECT pg_temp.debe_fallar(format($$UPDATE contabilidad.asiento SET glosa = 'CAMBIO' WHERE id_asiento = %s$$, (SELECT id FROM prueba_id WHERE nombre = 'venta_usd')),
    'está cerrado', 'un asiento de un día cerrado no se modifica');
SELECT pg_temp.debe_fallar(format($$DELETE FROM contabilidad.asiento WHERE id_asiento = %s$$, (SELECT id FROM prueba_id WHERE nombre = 'venta_usd')),
    'no se borran', 'los asientos no se borran');

INSERT INTO prueba_id SELECT 'traspaso_7', contabilidad.registrar_asiento('2026-01-07', 3, 'TRASPASO',
    '[{"codigo_cuenta": "10101010", "importe_bs": 5, "codigo_unidad_negocio": 406},
      {"codigo_cuenta": "40101010", "importe_bs": -5, "codigo_unidad_negocio": 406, "codigo_centro_costo": 2}]', 'prueba');
SELECT pg_temp.debe_fallar($$SELECT contabilidad.cerrar_dia('2026-01-08', 'prueba')$$, 'Primero cierre el día 2026-01-07', 'los días se cierran en orden');

-- -----------------------------------------------------------------------------
-- 5. Anulación y reversión
-- -----------------------------------------------------------------------------
SELECT pg_temp.verificar((SELECT contabilidad.anular_asiento((SELECT id FROM prueba_id WHERE nombre = 'traspaso_7'), 'prueba', 'error de carga')
                                 = (SELECT id FROM prueba_id WHERE nombre = 'traspaso_7')),
       'en un día abierto el asiento se anula');
SELECT pg_temp.verificar((SELECT estado = 'ANULADO' FROM contabilidad.asiento WHERE id_asiento = (SELECT id FROM prueba_id WHERE nombre = 'traspaso_7')),
       'el traspaso queda ANULADO');

INSERT INTO prueba_id SELECT 'reversion_venta',
    contabilidad.anular_asiento((SELECT id FROM prueba_id WHERE nombre = 'venta_usd'), 'prueba', 'venta desistida por el cliente', '2026-01-20');
SELECT pg_temp.confirmar_restricciones();
SELECT pg_temp.verificar((SELECT estado = 'REVERTIDO' FROM contabilidad.asiento WHERE id_asiento = (SELECT id FROM prueba_id WHERE nombre = 'venta_usd')),
       'la venta del día cerrado queda REVERTIDA');
SELECT pg_temp.verificar((SELECT tipo_asiento_sistema = 'REVERSION' AND fecha_contable = '2026-01-20'
                                 AND id_asiento_revertido = (SELECT id FROM prueba_id WHERE nombre = 'venta_usd')
                          FROM contabilidad.asiento WHERE id_asiento = (SELECT id FROM prueba_id WHERE nombre = 'reversion_venta')),
       'la reversión queda el 20 de enero y apunta a la venta');
SELECT pg_temp.verificar((SELECT sum(importe_bs) = 0 AND sum(importe_usd) = 0 FROM contabilidad.asiento_detalle
                          WHERE codigo_cuenta = '40101010'
                            AND id_asiento IN (SELECT id FROM prueba_id WHERE nombre IN ('venta_usd', 'reversion_venta'))),
       'la venta y su reversión se compensan');
SELECT pg_temp.debe_fallar(format($$SELECT contabilidad.anular_asiento(%s, 'prueba', 'deshacer la reversión')$$, (SELECT id FROM prueba_id WHERE nombre = 'reversion_venta')),
    'es la reversión del asiento', 'una reversión no se anula');

INSERT INTO prueba_id SELECT 'venta_usd_2', contabilidad.registrar_asiento('2026-01-07', 1, 'VENTA AL CONTADO EN USD',
    '[{"codigo_cuenta": "10101011", "importe_usd": 1000, "codigo_unidad_negocio": 406},
      {"codigo_cuenta": "40101010", "importe_usd": -1000, "codigo_unidad_negocio": 406, "codigo_centro_costo": 2}]', 'prueba', 2, NULL, 2);

CREATE TEMP TABLE prueba_dias AS SELECT * FROM contabilidad.cerrar_dias_pendientes('2026-01-31', 'prueba');
SELECT pg_temp.confirmar_restricciones();
SELECT pg_temp.verificar((SELECT count(*) = 2 AND bool_and((resultado->>'cerrado')::boolean) FROM prueba_dias),
       'el proceso nocturno cierra en orden el 7 y el 20 de enero');

-- -----------------------------------------------------------------------------
-- 6. Cierre mensual con revaluación de la moneda extranjera
-- -----------------------------------------------------------------------------
SELECT pg_temp.debe_fallar($$SELECT contabilidad.cerrar_periodo(2026, 2, 'prueba')$$, 'Primero cierre el período 1', 'los meses se cierran en orden');

INSERT INTO prueba_resultado SELECT 'enero', contabilidad.cerrar_periodo(2026, 1, 'prueba');
SELECT pg_temp.confirmar_restricciones();
SELECT pg_temp.verificar((SELECT resultado->>'id_asiento_revaluacion' IS NOT NULL FROM prueba_resultado WHERE nombre = 'enero'),
       'el cierre de enero revalúa la moneda extranjera al TC 7,00');
SELECT pg_temp.verificar((SELECT saldo_final_bs = 10500 AND saldo_final_usd = 1500 FROM contabilidad.saldo_mensual
                          WHERE gestion = 2026 AND periodo = 1 AND codigo_cuenta = '10101011'),
       'la caja en USD cierra enero con 1500 USD = 10500 Bs');
SELECT pg_temp.verificar((SELECT saldo_final_bs = -3500 FROM contabilidad.saldo_mensual WHERE gestion = 2026 AND periodo = 1 AND codigo_cuenta = '10204011'),
       'la cuenta por cobrar en USD queda en -3500 Bs');
SELECT pg_temp.verificar((SELECT saldo_final_bs = -40 FROM contabilidad.saldo_mensual WHERE gestion = 2026 AND periodo = 1 AND codigo_cuenta = '50201020'),
       'la diferencia de cambio neta es una ganancia de 40 Bs');
SELECT pg_temp.verificar((SELECT estado = 'CERRADO' FROM contabilidad.dia_contable WHERE fecha_contable = '2026-01-31'),
       'el 31 de enero, día de la revaluación, queda cerrado');

DO $$
BEGIN
    FOR v_mes IN 2..12 LOOP
        PERFORM contabilidad.cerrar_periodo(2026, v_mes, 'prueba');
    END LOOP;
END;
$$;
SELECT pg_temp.verificar((SELECT count(*) = 12 FROM contabilidad.periodo_contable WHERE gestion = 2026 AND periodo BETWEEN 1 AND 12 AND estado = 'CERRADO'),
       'los 12 meses de 2026 quedan cerrados');
SELECT pg_temp.debe_fallar($$SELECT contabilidad.reabrir_periodo(2026, 5, 'prueba', 'revisión de mayo')$$,
    'Primero reabra el período 6', 'un mes se reabre solo si el siguiente está abierto');
SELECT contabilidad.reabrir_periodo(2026, 12, 'prueba', 'ajuste de diciembre');
SELECT contabilidad.cerrar_periodo(2026, 12, 'prueba');

-- -----------------------------------------------------------------------------
-- 7. Reportes
-- -----------------------------------------------------------------------------
SELECT pg_temp.verificar((SELECT sum(debe_bs) = sum(haber_bs) AND sum(debe_usd) = sum(haber_usd) FROM contabilidad.balance_sumas_saldos(2026, 12, NULL, 1)),
       'sumas y saldos: en el nivel 1 el debe es igual al haber');
SELECT pg_temp.verificar((SELECT importe_bs = 7070 FROM contabilidad.estado_resultados(2026) WHERE naturaleza = 'RESULTADO'),
       'el estado de resultados de 2026 da una utilidad de 7070 Bs');
SELECT pg_temp.verificar((SELECT sum(saldo_bs) FILTER (WHERE naturaleza = 'ACTIVO') = 7070
                                 AND sum(saldo_bs) FILTER (WHERE naturaleza IN ('PASIVO', 'PATRIMONIO')) = 7070
                          FROM contabilidad.balance_general(2026, 12, NULL, 1)),
       'balance general: activo = pasivo + patrimonio (con el resultado sin cerrar)');
SELECT pg_temp.verificar((SELECT saldo_bs = 10500 FROM contabilidad.libro_mayor('10101011', '2026-01-01', '2026-12-31')
                          ORDER BY fecha_contable DESC NULLS LAST, numero_asiento DESC LIMIT 1),
       'el mayor de la caja en USD termina en 10500 Bs');
SELECT pg_temp.verificar((SELECT saldo_bs = 10510 FROM contabilidad.libro_mayor('10101000', '2026-01-06', '2026-12-31') WHERE glosa = 'SALDO ANTERIOR'),
       'el mayor de una cuenta de nivel 3 acumula sus subcuentas (saldo anterior 10510 Bs)');
SELECT pg_temp.verificar((SELECT count(*) > 0 FROM contabilidad.libro_diario('2026-01-01', '2026-01-31')), 'el libro diario de enero tiene movimientos');
SELECT pg_temp.verificar((SELECT count(*) = 0 FROM contabilidad.asientos_descuadrados(2026)), 'no hay asientos descuadrados en 2026');

-- -----------------------------------------------------------------------------
-- 8. Cierre anual y apertura
-- -----------------------------------------------------------------------------
INSERT INTO prueba_resultado SELECT 'gestion_2026', contabilidad.cerrar_gestion(2026, 'prueba');
SELECT pg_temp.confirmar_restricciones();
SELECT pg_temp.verificar((SELECT (resultado->>'resultado_bs')::numeric = 7070 FROM prueba_resultado WHERE nombre = 'gestion_2026'),
       'el cierre de 2026 lleva la utilidad de 7070 Bs a la cuenta de resultado');
SELECT pg_temp.verificar((SELECT coalesce(sum(s.saldo_final_bs), 0) = 0 FROM contabilidad.saldo_mensual s
                          JOIN contabilidad.cuenta_contable c ON c.codigo_cuenta = s.codigo_cuenta
                          WHERE s.gestion = 2026 AND s.periodo = 13 AND c.codigo_grupo IN ('4', '5')),
       'las cuentas de ingreso y gasto quedan en cero');
SELECT pg_temp.verificar((SELECT estado = 'CERRADA' FROM contabilidad.gestion WHERE gestion = 2026), 'la gestión 2026 queda cerrada');
SELECT pg_temp.verificar((SELECT count(*) = 1 FROM contabilidad.asiento WHERE gestion = 2027 AND periodo = 0 AND tipo_asiento_sistema = 'APERTURA' AND estado = 'VIGENTE'),
       'se crea la gestión 2027 con su asiento de apertura');
SELECT pg_temp.verificar((SELECT sum(d.importe_bs) = -7070 FROM contabilidad.asiento_detalle d JOIN contabilidad.asiento a ON a.id_asiento = d.id_asiento
                          WHERE a.gestion = 2027 AND a.periodo = 0 AND a.estado = 'VIGENTE' AND d.codigo_cuenta = '30401010'),
       'la utilidad abre 2027 en resultados acumulados');
SELECT pg_temp.verificar((SELECT sum(saldo_bs) FILTER (WHERE naturaleza = 'ACTIVO') = 7070 AND sum(saldo_bs) FILTER (WHERE naturaleza = 'PATRIMONIO') = 7070
                          FROM contabilidad.balance_general(2027, 0, NULL, 1)),
       'el balance de apertura de 2027 coincide con el de cierre de 2026');
SELECT pg_temp.debe_fallar($$SELECT contabilidad.registrar_asiento('2026-12-15', 3, 'TARDE',
    '[{"codigo_cuenta": "10101010", "importe_bs": 5, "codigo_unidad_negocio": 406},
      {"codigo_cuenta": "40101010", "importe_bs": -5, "codigo_unidad_negocio": 406, "codigo_centro_costo": 2}]', 'prueba')$$,
    'está cerrada', 'no se registra en una gestión cerrada');

SELECT contabilidad.reabrir_gestion(2026, 'prueba', 'ajuste pedido por auditoría');
SELECT pg_temp.verificar((SELECT estado = 'ABIERTA' FROM contabilidad.gestion WHERE gestion = 2026)
                         AND (SELECT count(*) = 0 FROM contabilidad.asiento WHERE gestion = 2027 AND periodo = 0 AND estado = 'VIGENTE'),
       'al reabrir 2026 se anula la apertura de 2027');
SELECT contabilidad.cerrar_gestion(2026, 'prueba');
SELECT pg_temp.confirmar_restricciones();
SELECT pg_temp.verificar((SELECT count(*) FILTER (WHERE estado = 'VIGENTE') = 1 AND count(*) = 2
                          FROM contabilidad.asiento WHERE gestion = 2027 AND tipo_asiento_sistema = 'APERTURA'),
       'al cerrar de nuevo queda una sola apertura vigente y la anterior anulada');

-- -----------------------------------------------------------------------------
-- 9. Cuadre diferido y bitácora
-- -----------------------------------------------------------------------------
INSERT INTO prueba_id SELECT 'traspaso_2027', contabilidad.registrar_asiento('2027-01-10', 3, 'TRASPASO',
    '[{"codigo_cuenta": "10101010", "importe_bs": 5, "codigo_unidad_negocio": 406},
      {"codigo_cuenta": "40101010", "importe_bs": -5, "codigo_unidad_negocio": 406, "codigo_centro_costo": 2}]', 'prueba');
SELECT pg_temp.confirmar_restricciones();
SELECT pg_temp.debe_fallar(format($$INSERT INTO contabilidad.asiento_detalle (id_asiento, numero_linea, codigo_cuenta, importe_bs, codigo_unidad_negocio)
                                     VALUES (%s, 99, '10101010', 1, 406)$$, (SELECT id FROM prueba_id WHERE nombre = 'traspaso_2027')),
    'no cuadra', 'una línea suelta que descuadra un asiento se rechaza al confirmar');
SELECT pg_temp.verificar((SELECT count(*) FILTER (WHERE tipo_cierre = 'DIA' AND accion = 'CIERRE') = 3
                                 AND count(*) FILTER (WHERE tipo_cierre = 'GESTION' AND accion = 'REAPERTURA') = 1
                          FROM contabilidad.bitacora_cierre),
       'la bitácora registra los cierres de día y la reapertura de la gestión');

ROLLBACK;
\echo 'Prueba del ciclo contable terminada sin fallas (todo se deshizo con ROLLBACK)'

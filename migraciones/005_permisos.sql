-- =============================================================================
-- Contabilidad · 005 · Roles y permisos
-- -----------------------------------------------------------------------------
-- Cuatro roles sin login; a cada usuario real se le otorga el que corresponde:
--   GRANT contabilidad_operador TO <usuario>;
--
--   contabilidad_consulta    lee tablas y reportes
--   contabilidad_operador    + registra y anula asientos, contabiliza la interfaz,
--                            cierra días y carga tipos de cambio
--   contabilidad_supervisor  + catálogos y plan de cuentas, crea gestiones,
--                            cierres mensual y anual y todas las reaperturas
--   contabilidad_interfaz    solo inserta en interfaz_comprobante (ETL / módulos)
--
-- Nadie escribe directo en asiento, asiento_detalle, saldos ni calendario:
-- todo pasa por las funciones SECURITY DEFINER del esquema. Las funciones de uso
-- interno no se otorgan a ningún rol.
--
-- Crear roles requiere CREATEROLE. Requiere 001 a 004. Estado: PROPUESTA, NO APLICADA.
-- =============================================================================

BEGIN;

DO $$
DECLARE
    v_rol text;
BEGIN
    FOREACH v_rol IN ARRAY ARRAY['contabilidad_consulta', 'contabilidad_operador', 'contabilidad_supervisor', 'contabilidad_interfaz'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles r WHERE r.rolname = v_rol) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', v_rol);
        END IF;
    END LOOP;
END;
$$;

COMMENT ON ROLE contabilidad_consulta IS 'Contabilidad: lectura de tablas y reportes';
COMMENT ON ROLE contabilidad_operador IS 'Contabilidad: registro de asientos, interfaz y cierre diario';
COMMENT ON ROLE contabilidad_supervisor IS 'Contabilidad: catálogos, plan de cuentas, cierres mensual y anual y reaperturas';
COMMENT ON ROLE contabilidad_interfaz IS 'Contabilidad: carga de comprobantes de los módulos (interfaz_comprobante)';

GRANT contabilidad_consulta TO contabilidad_operador;
GRANT contabilidad_operador TO contabilidad_supervisor;

REVOKE ALL ON SCHEMA contabilidad FROM PUBLIC;
GRANT USAGE ON SCHEMA contabilidad TO contabilidad_consulta, contabilidad_interfaz;

-- Consulta ---------------------------------------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA contabilidad TO contabilidad_consulta;
GRANT EXECUTE ON FUNCTION
    contabilidad.tipo_cambio_vigente(date, integer),
    contabilidad.periodo_de_fecha(date),
    contabilidad.libro_diario(date, date, boolean),
    contabilidad.libro_mayor(text, date, date, integer),
    contabilidad.balance_sumas_saldos(integer, integer, integer, integer),
    contabilidad.balance_general(integer, integer, integer, integer),
    contabilidad.estado_resultados(integer, integer, integer, integer, integer),
    contabilidad.asientos_descuadrados(integer)
TO contabilidad_consulta;

-- Operador ---------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION
    contabilidad.registrar_asiento(date, integer, text, jsonb, text, integer, integer, integer, integer),
    contabilidad.anular_asiento(bigint, text, text, date),
    contabilidad.contabilizar_interfaz(date, text),
    contabilidad.cerrar_dia(date, text, boolean),
    contabilidad.cerrar_dias_pendientes(date, text)
TO contabilidad_operador;
GRANT INSERT, UPDATE ON contabilidad.tipo_cambio TO contabilidad_operador;
-- Corregir o descartar líneas de interfaz con error (las contabilizadas las protege un trigger)
GRANT UPDATE (codigo_cuenta, codigo_unidad_negocio, codigo_centro_costo, codigo_moneda_operacion,
              importe_bs, importe_usd, tipo_cambio, estado, mensaje_error)
    ON contabilidad.interfaz_comprobante TO contabilidad_operador;

-- Supervisor -------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION
    contabilidad.crear_gestion(integer, text, text, text, text, text, integer),
    contabilidad.reabrir_dia(date, text, text),
    contabilidad.cerrar_periodo(integer, integer, text),
    contabilidad.reabrir_periodo(integer, integer, text, text),
    contabilidad.cerrar_gestion(integer, text, boolean),
    contabilidad.reabrir_gestion(integer, text, text),
    contabilidad.recalcular_saldos_gestion(integer)
TO contabilidad_supervisor;
GRANT INSERT, UPDATE ON
    contabilidad.unidad_negocio,
    contabilidad.grupo_centro_costo,
    contabilidad.centro_costo,
    contabilidad.tipo_auxiliar,
    contabilidad.auxiliar_contable,
    contabilidad.cuenta_contable,
    contabilidad.cuenta_equivalencia,
    contabilidad.modulo_origen
TO contabilidad_supervisor;
GRANT INSERT, DELETE ON contabilidad.unidad_negocio_centro_costo TO contabilidad_supervisor;
-- Parámetros de la gestión (el estado solo lo cambian los cierres)
GRANT UPDATE (codigo_cuenta_resultado, codigo_cuenta_resultado_acumulado, codigo_cuenta_redondeo, codigo_cuenta_diferencia_cambio,
              codigo_centro_costo_defecto, revaluar_moneda_extranjera, tolerancia_redondeo, exigir_cierre_dias_en_orden)
    ON contabilidad.gestion TO contabilidad_supervisor;

-- Interfaz ---------------------------------------------------------------------
GRANT SELECT ON contabilidad.modulo_origen TO contabilidad_interfaz;
GRANT SELECT, INSERT ON contabilidad.interfaz_comprobante TO contabilidad_interfaz;
GRANT USAGE ON SEQUENCE contabilidad.interfaz_comprobante_id_interfaz_comprobante_seq TO contabilidad_interfaz;

COMMIT;

-- =============================================================================
-- Contabilidad · 001 · Estructuras
-- -----------------------------------------------------------------------------
-- Esquema contabilidad: catálogos, plan de cuentas, calendario contable
-- (gestión, período, día), asientos, interfaz con los módulos de origen,
-- saldos diarios y mensuales y bitácora de cierres.
--
-- Reemplaza al módulo cn del SAI (Informix tbsai@online09). Cada tabla y
-- columna indica en su comentario de qué tabla y columna del SAI viene.
--
-- Requiere PostgreSQL 9.5 o superior (ON CONFLICT, jsonb_build_object).
-- Estado: PROPUESTA, NO APLICADA. Ver sql/postgres/contabilidad/README.md.
--
-- Convenciones
--   tablas y columnas   singular, snake_case, palabras completas
--   claves              pk_<tabla>, fk_<tabla>_<referencia>, uk_<tabla>_<columnas>
--   controles           ck_<tabla>_<regla>
--   índices             ix_<tabla>_<columnas>
--   importes            numeric(18,2) con signo: positivo = debe, negativo = haber
--   auditoría           usuario_creacion, fecha_creacion (timestamptz)
-- =============================================================================

BEGIN;

CREATE SCHEMA contabilidad;
COMMENT ON SCHEMA contabilidad IS 'Contabilidad general: plan de cuentas, asientos, interfaz con los módulos y cierres diario, mensual y anual. Reemplaza al módulo cn del SAI';

-- -----------------------------------------------------------------------------
-- Monedas y tipo de cambio
-- -----------------------------------------------------------------------------
CREATE TABLE contabilidad.moneda (
    codigo_moneda        smallint     NOT NULL,
    codigo_iso           char(3)      NOT NULL,
    nombre               varchar(40)  NOT NULL,
    simbolo              varchar(5)   NOT NULL,
    es_moneda_funcional  boolean      NOT NULL DEFAULT false,
    CONSTRAINT pk_moneda PRIMARY KEY (codigo_moneda),
    CONSTRAINT uk_moneda_codigo_iso UNIQUE (codigo_iso)
);
CREATE UNIQUE INDEX uk_moneda_funcional ON contabilidad.moneda (es_moneda_funcional) WHERE es_moneda_funcional;
COMMENT ON TABLE contabilidad.moneda IS 'Monedas. Mismos códigos que cmon del SAI: 1 bolivianos (moneda funcional, importe_bs), 2 dólares (importe_usd)';
COMMENT ON COLUMN contabilidad.moneda.es_moneda_funcional IS 'Moneda en la que se lleva la contabilidad; solo una puede serlo';

INSERT INTO contabilidad.moneda (codigo_moneda, codigo_iso, nombre, simbolo, es_moneda_funcional) VALUES
    (1, 'BOB', 'BOLIVIANOS', 'Bs', true),
    (2, 'USD', 'DOLARES ESTADOUNIDENSES', 'USD', false);

CREATE TABLE contabilidad.tipo_cambio (
    fecha                date           NOT NULL,
    codigo_moneda        smallint       NOT NULL,
    tipo_cambio_oficial  numeric(18,8)  NOT NULL,
    tipo_cambio_compra   numeric(18,8),
    tipo_cambio_venta    numeric(18,8),
    usuario_creacion     varchar(30)    NOT NULL DEFAULT current_user,
    fecha_creacion       timestamptz    NOT NULL DEFAULT now(),
    CONSTRAINT pk_tipo_cambio PRIMARY KEY (fecha, codigo_moneda),
    CONSTRAINT fk_tipo_cambio_moneda FOREIGN KEY (codigo_moneda) REFERENCES contabilidad.moneda (codigo_moneda),
    CONSTRAINT ck_tipo_cambio_positivo CHECK (tipo_cambio_oficial > 0 AND coalesce(tipo_cambio_compra, 1) > 0 AND coalesce(tipo_cambio_venta, 1) > 0)
);
COMMENT ON TABLE contabilidad.tipo_cambio IS 'Bolivianos por unidad de moneda extranjera. Vale el último registrado a la fecha (contabilidad.tipo_cambio_vigente). En el SAI venía en cada línea (cndtrcamb, cntcntcam)';
COMMENT ON COLUMN contabilidad.tipo_cambio.tipo_cambio_oficial IS 'El que se usa para convertir importes y revaluar las cuentas en moneda extranjera';

-- -----------------------------------------------------------------------------
-- Unidades de negocio y centros de costo
-- -----------------------------------------------------------------------------
CREATE TABLE contabilidad.unidad_negocio (
    codigo_unidad_negocio  smallint     NOT NULL,
    nombre                 varchar(60)  NOT NULL,
    activo                 boolean      NOT NULL DEFAULT true,
    usuario_creacion       varchar(30)  NOT NULL DEFAULT current_user,
    fecha_creacion         timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT pk_unidad_negocio PRIMARY KEY (codigo_unidad_negocio)
);
COMMENT ON TABLE contabilidad.unidad_negocio IS 'Unidades de negocio (proyectos: 405, 406, 410, 411...). SAI: cnune';

CREATE TABLE contabilidad.grupo_centro_costo (
    codigo_grupo_centro_costo  smallint     NOT NULL,
    nombre                     varchar(60)  NOT NULL,
    CONSTRAINT pk_grupo_centro_costo PRIMARY KEY (codigo_grupo_centro_costo)
);
COMMENT ON TABLE contabilidad.grupo_centro_costo IS 'Agrupador de centros de costo. SAI: cncsu (centro de costo superior)';

CREATE TABLE contabilidad.centro_costo (
    codigo_centro_costo        smallint     NOT NULL,
    nombre                     varchar(60)  NOT NULL,
    codigo_grupo_centro_costo  smallint,
    activo                     boolean      NOT NULL DEFAULT true,
    CONSTRAINT pk_centro_costo PRIMARY KEY (codigo_centro_costo),
    CONSTRAINT fk_centro_costo_grupo FOREIGN KEY (codigo_grupo_centro_costo) REFERENCES contabilidad.grupo_centro_costo (codigo_grupo_centro_costo)
);
COMMENT ON TABLE contabilidad.centro_costo IS 'Centros de costo. SAI: cncco. El 0 es "sin centro de costo" (el SAI lo usa en cntcn)';

INSERT INTO contabilidad.centro_costo (codigo_centro_costo, nombre) VALUES (0, 'SIN CENTRO DE COSTO');

CREATE TABLE contabilidad.unidad_negocio_centro_costo (
    codigo_unidad_negocio  smallint  NOT NULL,
    codigo_centro_costo    smallint  NOT NULL,
    CONSTRAINT pk_unidad_negocio_centro_costo PRIMARY KEY (codigo_unidad_negocio, codigo_centro_costo),
    CONSTRAINT fk_unidad_negocio_centro_costo_unidad FOREIGN KEY (codigo_unidad_negocio) REFERENCES contabilidad.unidad_negocio (codigo_unidad_negocio),
    CONSTRAINT fk_unidad_negocio_centro_costo_centro FOREIGN KEY (codigo_centro_costo) REFERENCES contabilidad.centro_costo (codigo_centro_costo)
);
CREATE INDEX ix_unidad_negocio_centro_costo_centro ON contabilidad.unidad_negocio_centro_costo (codigo_centro_costo);
COMMENT ON TABLE contabilidad.unidad_negocio_centro_costo IS 'Centros de costo permitidos por unidad de negocio. SAI: cnruc. Si una unidad no tiene filas acepta cualquier centro';

-- -----------------------------------------------------------------------------
-- Tipos de documento, módulos de origen y auxiliares
-- -----------------------------------------------------------------------------
CREATE TABLE contabilidad.tipo_documento (
    codigo_tipo_documento  smallint     NOT NULL,
    nombre                 varchar(60)  NOT NULL,
    es_de_sistema          boolean      NOT NULL DEFAULT false,
    CONSTRAINT pk_tipo_documento PRIMARY KEY (codigo_tipo_documento)
);
COMMENT ON TABLE contabilidad.tipo_documento IS 'Tipos de documento contable. SAI: cntdc (cndtrtdoc). Los de sistema solo los generan los cierres';
COMMENT ON COLUMN contabilidad.tipo_documento.es_de_sistema IS 'true: apertura, cierre de resultados y diferencia de cambio; no se pueden usar en asientos manuales';

INSERT INTO contabilidad.tipo_documento (codigo_tipo_documento, nombre, es_de_sistema) VALUES
    (1, 'INGRESOS', false),
    (2, 'EGRESOS', false),
    (3, 'TRASPASOS', false),
    (4, 'RESUMEN DE CAJA', false),
    (5, 'RESUMEN DE VENTAS', false),
    (6, 'RESUMEN DE INVENTARIOS', false),
    (7, 'RESUMEN DE CUENTAS CORRIENTES', false),
    (9, 'RESUMEN DE SUELDOS', false),
    (10, 'RESUMEN DE ACTIVO FIJO', false),
    (11, 'RESUMEN DE PRODUCCION', false),
    (12, 'RESUMEN DE CUENTAS POR PAGAR', false),
    (13, 'RESUMEN DE CUENTAS POR COBRAR', false),
    (17, 'RESUMEN DE COMPRAS', false),
    (40, 'POSTEO DE LOTES', false),
    (88, 'APERTURA DE GESTION', true),
    (96, 'RESUMEN DE TESORERIA', false),
    (97, 'CIERRE DE RESULTADOS', true),
    (98, 'DIFERENCIA DE CAMBIO', true),
    (99, 'AJUSTE MONETARIO', false);

CREATE TABLE contabilidad.modulo_origen (
    codigo_modulo                   smallint     NOT NULL,
    nombre                          varchar(60)  NOT NULL,
    codigo_tipo_documento_defecto   smallint     NOT NULL,
    CONSTRAINT pk_modulo_origen PRIMARY KEY (codigo_modulo),
    CONSTRAINT fk_modulo_origen_tipo_documento FOREIGN KEY (codigo_tipo_documento_defecto) REFERENCES contabilidad.tipo_documento (codigo_tipo_documento)
);
COMMENT ON TABLE contabilidad.modulo_origen IS 'Módulos que generan asientos. SAI: cndtrmorg / cntcnmodn. Los nombres se dedujeron del tipo de documento que usa cada módulo';
COMMENT ON COLUMN contabilidad.modulo_origen.codigo_tipo_documento_defecto IS 'Tipo de documento de los asientos que se arman desde la interfaz del módulo';

INSERT INTO contabilidad.modulo_origen (codigo_modulo, nombre, codigo_tipo_documento_defecto) VALUES
    (2, 'CONTABILIDAD', 3),
    (4, 'CAJA', 4),
    (9, 'SUELDOS', 9),
    (12, 'CUENTAS POR PAGAR', 12),
    (13, 'CUENTAS POR COBRAR', 13),
    (40, 'INMOBILIARIA (LOTES)', 40),
    (96, 'TESORERIA', 96);

CREATE TABLE contabilidad.tipo_auxiliar (
    codigo_tipo_auxiliar  smallint     NOT NULL,
    nombre                varchar(60)  NOT NULL,
    CONSTRAINT pk_tipo_auxiliar PRIMARY KEY (codigo_tipo_auxiliar)
);
COMMENT ON TABLE contabilidad.tipo_auxiliar IS 'Tipos de auxiliar contable (análisis adicional de una cuenta: vehículo, obra...). SAI: cntco / cnhtc (tcon)';

CREATE TABLE contabilidad.auxiliar_contable (
    codigo_tipo_auxiliar  smallint     NOT NULL,
    codigo_auxiliar       integer      NOT NULL,
    nombre                varchar(80)  NOT NULL,
    activo                boolean      NOT NULL DEFAULT true,
    CONSTRAINT pk_auxiliar_contable PRIMARY KEY (codigo_tipo_auxiliar, codigo_auxiliar),
    CONSTRAINT fk_auxiliar_contable_tipo FOREIGN KEY (codigo_tipo_auxiliar) REFERENCES contabilidad.tipo_auxiliar (codigo_tipo_auxiliar)
);
COMMENT ON TABLE contabilidad.auxiliar_contable IS 'Auxiliares contables por tipo. SAI: cncnp / cnhcn (tcon + ncon)';

-- -----------------------------------------------------------------------------
-- Plan de cuentas
-- -----------------------------------------------------------------------------
CREATE TABLE contabilidad.grupo_cuenta (
    codigo_grupo         char(1)      NOT NULL,
    nombre               varchar(60)  NOT NULL,
    naturaleza           varchar(10)  NOT NULL,
    saldo_normal         varchar(8)   NOT NULL,
    es_cuenta_resultado  boolean      NOT NULL,
    CONSTRAINT pk_grupo_cuenta PRIMARY KEY (codigo_grupo),
    CONSTRAINT ck_grupo_cuenta_codigo CHECK (codigo_grupo ~ '^[1-9]$'),
    CONSTRAINT ck_grupo_cuenta_naturaleza CHECK (naturaleza IN ('ACTIVO', 'PASIVO', 'PATRIMONIO', 'INGRESO', 'GASTO', 'ORDEN')),
    CONSTRAINT ck_grupo_cuenta_saldo_normal CHECK (saldo_normal IN ('DEUDOR', 'ACREEDOR')),
    CONSTRAINT ck_grupo_cuenta_resultado CHECK (es_cuenta_resultado = (naturaleza IN ('INGRESO', 'GASTO')))
);
COMMENT ON TABLE contabilidad.grupo_cuenta IS 'Primer dígito de la cuenta. SAI: cnprmncp1..9 (A P P I E O O O O). Las cuentas de resultado se cierran contra el resultado de la gestión';

INSERT INTO contabilidad.grupo_cuenta (codigo_grupo, nombre, naturaleza, saldo_normal, es_cuenta_resultado) VALUES
    ('1', 'ACTIVO', 'ACTIVO', 'DEUDOR', false),
    ('2', 'PASIVO', 'PASIVO', 'ACREEDOR', false),
    ('3', 'PATRIMONIO', 'PATRIMONIO', 'ACREEDOR', false),
    ('4', 'INGRESOS', 'INGRESO', 'ACREEDOR', true),
    ('5', 'GASTOS', 'GASTO', 'DEUDOR', true),
    ('6', 'CUENTAS DE ORDEN DEUDORAS', 'ORDEN', 'DEUDOR', false),
    ('7', 'CUENTAS DE ORDEN ACREEDORAS', 'ORDEN', 'ACREEDOR', false),
    ('8', 'CUENTAS DE ORDEN DEUDORAS II', 'ORDEN', 'DEUDOR', false),
    ('9', 'CUENTAS DE ORDEN ACREEDORAS II', 'ORDEN', 'ACREEDOR', false);

CREATE TABLE contabilidad.nivel_cuenta (
    nivel                   smallint     NOT NULL,
    digitos_significativos  smallint     NOT NULL,
    nombre                  varchar(40)  NOT NULL,
    CONSTRAINT pk_nivel_cuenta PRIMARY KEY (nivel),
    CONSTRAINT uk_nivel_cuenta_digitos UNIQUE (digitos_significativos),
    CONSTRAINT ck_nivel_cuenta_digitos CHECK (digitos_significativos BETWEEN 1 AND 16)
);
COMMENT ON TABLE contabilidad.nivel_cuenta IS 'Estructura del código de cuenta: dígitos significativos por nivel (el resto son ceros). SAI: 1-3-5-8 (10000000, 10100000, 10101000, 10101010)';

INSERT INTO contabilidad.nivel_cuenta (nivel, digitos_significativos, nombre) VALUES
    (1, 1, 'GRUPO'),
    (2, 3, 'SUBGRUPO'),
    (3, 5, 'CUENTA'),
    (4, 8, 'SUBCUENTA');

CREATE TABLE contabilidad.cuenta_contable (
    codigo_cuenta         varchar(16)  NOT NULL,
    nombre                varchar(80)  NOT NULL,
    codigo_grupo          char(1)      NOT NULL,
    nivel                 smallint     NOT NULL,
    codigo_cuenta_padre   varchar(16),
    es_imputable          boolean      NOT NULL,
    codigo_moneda         smallint,
    exige_centro_costo    boolean      NOT NULL DEFAULT false,
    codigo_tipo_auxiliar  smallint,
    activo                boolean      NOT NULL DEFAULT true,
    usuario_creacion      varchar(30)  NOT NULL DEFAULT current_user,
    fecha_creacion        timestamptz  NOT NULL DEFAULT now(),
    usuario_modificacion  varchar(30),
    fecha_modificacion    timestamptz,
    CONSTRAINT pk_cuenta_contable PRIMARY KEY (codigo_cuenta),
    CONSTRAINT fk_cuenta_contable_grupo FOREIGN KEY (codigo_grupo) REFERENCES contabilidad.grupo_cuenta (codigo_grupo),
    CONSTRAINT fk_cuenta_contable_nivel FOREIGN KEY (nivel) REFERENCES contabilidad.nivel_cuenta (nivel),
    CONSTRAINT fk_cuenta_contable_padre FOREIGN KEY (codigo_cuenta_padre) REFERENCES contabilidad.cuenta_contable (codigo_cuenta),
    CONSTRAINT fk_cuenta_contable_moneda FOREIGN KEY (codigo_moneda) REFERENCES contabilidad.moneda (codigo_moneda),
    CONSTRAINT fk_cuenta_contable_tipo_auxiliar FOREIGN KEY (codigo_tipo_auxiliar) REFERENCES contabilidad.tipo_auxiliar (codigo_tipo_auxiliar),
    CONSTRAINT ck_cuenta_contable_codigo CHECK (codigo_cuenta ~ '^[1-9][0-9]*$'),
    CONSTRAINT ck_cuenta_contable_grupo CHECK (codigo_grupo = left(codigo_cuenta, 1)),
    CONSTRAINT ck_cuenta_contable_padre CHECK ((nivel = 1) = (codigo_cuenta_padre IS NULL))
);
CREATE INDEX ix_cuenta_contable_padre ON contabilidad.cuenta_contable (codigo_cuenta_padre);
COMMENT ON TABLE contabilidad.cuenta_contable IS 'Plan de cuentas vigente. SAI: cnplc. Nivel, cuenta padre y grupo se calculan del código (trigger trg_cuenta_contable_derivar)';
COMMENT ON COLUMN contabilidad.cuenta_contable.es_imputable IS 'Solo las cuentas imputables reciben movimientos (por defecto, las del último nivel)';
COMMENT ON COLUMN contabilidad.cuenta_contable.codigo_moneda IS 'Moneda de la cuenta (SAI cnplccmon). Las de moneda 2 se revalúan al cierre de mes si la gestión lo indica';
COMMENT ON COLUMN contabilidad.cuenta_contable.exige_centro_costo IS 'SAI cnplcmcco = S: los asientos manuales tienen que indicar centro de costo';
COMMENT ON COLUMN contabilidad.cuenta_contable.codigo_tipo_auxiliar IS 'SAI cnplctcon: tipo de auxiliar con el que se analiza la cuenta';

CREATE TABLE contabilidad.cuenta_equivalencia (
    codigo_cuenta_origen   varchar(16)  NOT NULL,
    codigo_cuenta_destino  varchar(16)  NOT NULL,
    CONSTRAINT pk_cuenta_equivalencia PRIMARY KEY (codigo_cuenta_origen)
);
COMMENT ON TABLE contabilidad.cuenta_equivalencia IS 'Relación de cuentas origen → destino del SAI (cnrpc). El SAI no documenta su uso: se conserva como referencia, sin claves foráneas';

-- -----------------------------------------------------------------------------
-- Calendario contable: gestión, período y día
-- -----------------------------------------------------------------------------
CREATE TABLE contabilidad.gestion (
    gestion                             smallint      NOT NULL,
    fecha_inicio                        date          NOT NULL,
    fecha_fin                           date          NOT NULL,
    estado                              varchar(8)    NOT NULL DEFAULT 'ABIERTA',
    codigo_cuenta_resultado             varchar(16)   NOT NULL,
    codigo_cuenta_resultado_acumulado   varchar(16)   NOT NULL,
    codigo_cuenta_redondeo              varchar(16),
    codigo_cuenta_diferencia_cambio     varchar(16),
    codigo_centro_costo_defecto         smallint      NOT NULL DEFAULT 0,
    revaluar_moneda_extranjera          boolean       NOT NULL DEFAULT false,
    tolerancia_redondeo                 numeric(8,2)  NOT NULL DEFAULT 0.80,
    exigir_cierre_dias_en_orden         boolean       NOT NULL DEFAULT true,
    usuario_cierre                      varchar(30),
    fecha_cierre                        timestamptz,
    usuario_creacion                    varchar(30)   NOT NULL DEFAULT current_user,
    fecha_creacion                      timestamptz   NOT NULL DEFAULT now(),
    CONSTRAINT pk_gestion PRIMARY KEY (gestion),
    CONSTRAINT fk_gestion_cuenta_resultado FOREIGN KEY (codigo_cuenta_resultado) REFERENCES contabilidad.cuenta_contable (codigo_cuenta),
    CONSTRAINT fk_gestion_cuenta_resultado_acumulado FOREIGN KEY (codigo_cuenta_resultado_acumulado) REFERENCES contabilidad.cuenta_contable (codigo_cuenta),
    CONSTRAINT fk_gestion_cuenta_redondeo FOREIGN KEY (codigo_cuenta_redondeo) REFERENCES contabilidad.cuenta_contable (codigo_cuenta),
    CONSTRAINT fk_gestion_cuenta_diferencia_cambio FOREIGN KEY (codigo_cuenta_diferencia_cambio) REFERENCES contabilidad.cuenta_contable (codigo_cuenta),
    CONSTRAINT fk_gestion_centro_costo FOREIGN KEY (codigo_centro_costo_defecto) REFERENCES contabilidad.centro_costo (codigo_centro_costo),
    CONSTRAINT ck_gestion_rango CHECK (gestion BETWEEN 1990 AND 2200),
    CONSTRAINT ck_gestion_fechas CHECK (fecha_fin > fecha_inicio),
    CONSTRAINT ck_gestion_estado CHECK (estado IN ('ABIERTA', 'CERRADA')),
    CONSTRAINT ck_gestion_tolerancia CHECK (tolerancia_redondeo >= 0),
    CONSTRAINT ck_gestion_cierre CHECK ((estado = 'CERRADA') = (fecha_cierre IS NOT NULL))
);
COMMENT ON TABLE contabilidad.gestion IS 'Gestión (año contable) y sus parámetros. SAI: cocierre (estado) + cnprm / cnhpr (cuentas de resultado y ajuste)';
COMMENT ON COLUMN contabilidad.gestion.codigo_cuenta_resultado IS 'Recibe el resultado en el cierre anual. SAI cnprmcres (30402010 RESULTADO DE LA GESTION)';
COMMENT ON COLUMN contabilidad.gestion.codigo_cuenta_resultado_acumulado IS 'Recibe el resultado en la apertura de la gestión siguiente. SAI cnprmcrea (30401010 RESULTADOS ACUMULADOS)';
COMMENT ON COLUMN contabilidad.gestion.codigo_cuenta_redondeo IS 'Diferencias de redondeo de la segunda moneda al cuadrar un asiento. SAI cnprmcaju (50201030 DIFCIA. DE REDONDEO)';
COMMENT ON COLUMN contabilidad.gestion.codigo_cuenta_diferencia_cambio IS 'Contrapartida de la revaluación mensual de las cuentas en moneda extranjera (por ejemplo 50201020 DIFERENCIA DE CAMBIO)';
COMMENT ON COLUMN contabilidad.gestion.tolerancia_redondeo IS 'Diferencia máxima (exclusiva) que se ajusta automáticamente en la segunda moneda. SAI pcuadre_cntcn: 0,80';
COMMENT ON COLUMN contabilidad.gestion.exigir_cierre_dias_en_orden IS 'true: un día solo se cierra si los días anteriores de la gestión ya están cerrados';

CREATE TABLE contabilidad.periodo_contable (
    gestion          smallint     NOT NULL,
    periodo          smallint     NOT NULL,
    nombre           varchar(30)  NOT NULL,
    fecha_inicio     date         NOT NULL,
    fecha_fin        date         NOT NULL,
    estado           varchar(8)   NOT NULL DEFAULT 'ABIERTO',
    usuario_cierre   varchar(30),
    fecha_cierre     timestamptz,
    CONSTRAINT pk_periodo_contable PRIMARY KEY (gestion, periodo),
    CONSTRAINT fk_periodo_contable_gestion FOREIGN KEY (gestion) REFERENCES contabilidad.gestion (gestion),
    CONSTRAINT ck_periodo_contable_numero CHECK (periodo BETWEEN 0 AND 13),
    CONSTRAINT ck_periodo_contable_fechas CHECK (fecha_fin >= fecha_inicio),
    CONSTRAINT ck_periodo_contable_estado CHECK (estado IN ('ABIERTO', 'CERRADO')),
    CONSTRAINT ck_periodo_contable_cierre CHECK ((estado = 'CERRADO') = (fecha_cierre IS NOT NULL))
);
COMMENT ON TABLE contabilidad.periodo_contable IS 'Períodos de la gestión: 0 apertura, 1 a 12 meses, 13 cierre de resultados. SAI: coperiodo (estado A/B) y cndtrcper';

CREATE TABLE contabilidad.dia_contable (
    fecha_contable     date           NOT NULL,
    gestion            smallint       NOT NULL,
    periodo            smallint       NOT NULL,
    estado             varchar(8)     NOT NULL DEFAULT 'ABIERTO',
    cantidad_asientos  integer,
    total_debe_bs      numeric(18,2),
    total_debe_usd     numeric(18,2),
    usuario_cierre     varchar(30),
    fecha_cierre       timestamptz,
    CONSTRAINT pk_dia_contable PRIMARY KEY (fecha_contable),
    CONSTRAINT fk_dia_contable_periodo FOREIGN KEY (gestion, periodo) REFERENCES contabilidad.periodo_contable (gestion, periodo),
    CONSTRAINT ck_dia_contable_periodo CHECK (periodo BETWEEN 1 AND 12),
    CONSTRAINT ck_dia_contable_estado CHECK (estado IN ('ABIERTO', 'CERRADO')),
    CONSTRAINT ck_dia_contable_cierre CHECK ((estado = 'CERRADO') = (fecha_cierre IS NOT NULL))
);
CREATE INDEX ix_dia_contable_periodo_estado ON contabilidad.dia_contable (gestion, periodo, estado);
COMMENT ON TABLE contabilidad.dia_contable IS 'Cierre diario (no existía en el SAI). Se crea al registrar el primer asiento o al cerrar el día';
COMMENT ON COLUMN contabilidad.dia_contable.total_debe_bs IS 'Suma del debe en Bs de los asientos del día al momento del cierre (control)';

CREATE TABLE contabilidad.correlativo_asiento (
    gestion        smallint  NOT NULL,
    ultimo_numero  integer   NOT NULL DEFAULT 0,
    CONSTRAINT pk_correlativo_asiento PRIMARY KEY (gestion),
    CONSTRAINT fk_correlativo_asiento_gestion FOREIGN KEY (gestion) REFERENCES contabilidad.gestion (gestion),
    CONSTRAINT ck_correlativo_asiento_numero CHECK (ultimo_numero >= 0)
);
COMMENT ON TABLE contabilidad.correlativo_asiento IS 'Último número de asiento por gestión. SAI: cnsrl / cnhsr';

CREATE TABLE contabilidad.bitacora_cierre (
    id_bitacora_cierre  bigserial    NOT NULL,
    tipo_cierre         varchar(8)   NOT NULL,
    accion              varchar(10)  NOT NULL,
    gestion             smallint     NOT NULL,
    periodo             smallint,
    fecha_contable      date,
    motivo              text,
    resultado           jsonb,
    usuario             varchar(30)  NOT NULL,
    fecha_registro      timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT pk_bitacora_cierre PRIMARY KEY (id_bitacora_cierre),
    CONSTRAINT ck_bitacora_cierre_tipo CHECK (tipo_cierre IN ('DIA', 'PERIODO', 'GESTION')),
    CONSTRAINT ck_bitacora_cierre_accion CHECK (accion IN ('CIERRE', 'REAPERTURA'))
);
CREATE INDEX ix_bitacora_cierre_gestion ON contabilidad.bitacora_cierre (gestion, periodo, fecha_contable);
COMMENT ON TABLE contabilidad.bitacora_cierre IS 'Quién cerró o reabrió cada día, período y gestión, cuándo y por qué';

-- -----------------------------------------------------------------------------
-- Asientos
-- -----------------------------------------------------------------------------
CREATE TABLE contabilidad.asiento (
    id_asiento                bigserial    NOT NULL,
    gestion                   smallint     NOT NULL,
    periodo                   smallint     NOT NULL,
    numero_asiento            integer      NOT NULL,
    fecha_contable            date         NOT NULL,
    codigo_tipo_documento     smallint     NOT NULL,
    codigo_modulo             smallint     NOT NULL,
    numero_documento          integer,
    glosa                     text,
    codigo_moneda_operacion   smallint     NOT NULL DEFAULT 1,
    estado                    varchar(10)  NOT NULL DEFAULT 'VIGENTE',
    origen                    varchar(10)  NOT NULL,
    tipo_asiento_sistema      varchar(12),
    id_asiento_revertido      bigint,
    usuario_creacion          varchar(30)  NOT NULL,
    fecha_creacion            timestamptz  NOT NULL DEFAULT now(),
    usuario_anulacion         varchar(30),
    fecha_anulacion           timestamptz,
    motivo_anulacion          text,
    sai_numero_transaccion    numeric(12,0),
    sai_numero_correlativo    integer,
    CONSTRAINT pk_asiento PRIMARY KEY (id_asiento),
    CONSTRAINT uk_asiento_gestion_numero UNIQUE (gestion, numero_asiento),
    CONSTRAINT fk_asiento_periodo FOREIGN KEY (gestion, periodo) REFERENCES contabilidad.periodo_contable (gestion, periodo),
    CONSTRAINT fk_asiento_tipo_documento FOREIGN KEY (codigo_tipo_documento) REFERENCES contabilidad.tipo_documento (codigo_tipo_documento),
    CONSTRAINT fk_asiento_modulo FOREIGN KEY (codigo_modulo) REFERENCES contabilidad.modulo_origen (codigo_modulo),
    CONSTRAINT fk_asiento_moneda_operacion FOREIGN KEY (codigo_moneda_operacion) REFERENCES contabilidad.moneda (codigo_moneda),
    CONSTRAINT fk_asiento_revertido FOREIGN KEY (id_asiento_revertido) REFERENCES contabilidad.asiento (id_asiento),
    CONSTRAINT ck_asiento_estado CHECK (estado IN ('VIGENTE', 'ANULADO', 'REVERTIDO')),
    CONSTRAINT ck_asiento_origen CHECK (origen IN ('MANUAL', 'INTERFAZ', 'SISTEMA', 'MIGRACION')),
    CONSTRAINT ck_asiento_tipo_sistema CHECK (tipo_asiento_sistema IN ('APERTURA', 'CIERRE', 'REVALUACION', 'REVERSION')),
    CONSTRAINT ck_asiento_origen_sistema CHECK ((origen = 'SISTEMA') = (tipo_asiento_sistema IS NOT NULL)),
    CONSTRAINT ck_asiento_reversion CHECK ((tipo_asiento_sistema = 'REVERSION') = (id_asiento_revertido IS NOT NULL)),
    CONSTRAINT ck_asiento_anulacion CHECK ((estado = 'VIGENTE') = (fecha_anulacion IS NULL))
);
CREATE INDEX ix_asiento_fecha ON contabilidad.asiento (fecha_contable);
CREATE INDEX ix_asiento_gestion_periodo ON contabilidad.asiento (gestion, periodo);
CREATE INDEX ix_asiento_documento ON contabilidad.asiento (codigo_modulo, numero_documento);
CREATE INDEX ix_asiento_revertido ON contabilidad.asiento (id_asiento_revertido) WHERE id_asiento_revertido IS NOT NULL;
CREATE INDEX ix_asiento_sai ON contabilidad.asiento (gestion, sai_numero_transaccion) WHERE sai_numero_transaccion IS NOT NULL;
CREATE UNIQUE INDEX uk_asiento_sistema_vigente ON contabilidad.asiento (gestion, periodo, tipo_asiento_sistema)
    WHERE estado = 'VIGENTE' AND tipo_asiento_sistema IN ('APERTURA', 'CIERRE', 'REVALUACION');
COMMENT ON TABLE contabilidad.asiento IS 'Cabecera del asiento. SAI: cnhtr (gestión abierta) y cnhht (histórico)';
COMMENT ON COLUMN contabilidad.asiento.numero_asiento IS 'Correlativo por gestión (contabilidad.correlativo_asiento)';
COMMENT ON COLUMN contabilidad.asiento.numero_documento IS 'Número del documento de origen (SAI cnhtrndoc / cntcnndoc)';
COMMENT ON COLUMN contabilidad.asiento.codigo_moneda_operacion IS 'Moneda en la que el asiento tiene que cuadrar exacto; la otra admite la tolerancia de redondeo';
COMMENT ON COLUMN contabilidad.asiento.estado IS 'VIGENTE; ANULADO (día abierto: no cuenta en saldos); REVERTIDO (día cerrado: cuenta en saldos y lo compensa un asiento de REVERSION)';
COMMENT ON COLUMN contabilidad.asiento.origen IS 'MANUAL, INTERFAZ (contabilizado desde interfaz_comprobante), SISTEMA (cierres) o MIGRACION (traído del SAI)';
COMMENT ON COLUMN contabilidad.asiento.sai_numero_transaccion IS 'cnhtrntra / cnhhtntra del SAI, para trazabilidad de lo migrado';
COMMENT ON COLUMN contabilidad.asiento.sai_numero_correlativo IS 'cnhtrnhtr / cnhhtnhtr del SAI';

CREATE TABLE contabilidad.asiento_detalle (
    id_asiento             bigint         NOT NULL,
    numero_linea           integer        NOT NULL,
    codigo_cuenta          varchar(16)    NOT NULL,
    glosa                  text,
    importe_bs             numeric(18,2)  NOT NULL,
    importe_usd            numeric(18,2)  NOT NULL DEFAULT 0,
    codigo_moneda          smallint       NOT NULL DEFAULT 1,
    tipo_cambio            numeric(18,8),
    codigo_unidad_negocio  smallint       NOT NULL,
    codigo_centro_costo    smallint       NOT NULL DEFAULT 0,
    codigo_tipo_auxiliar   smallint,
    codigo_auxiliar        integer,
    CONSTRAINT pk_asiento_detalle PRIMARY KEY (id_asiento, numero_linea),
    CONSTRAINT fk_asiento_detalle_asiento FOREIGN KEY (id_asiento) REFERENCES contabilidad.asiento (id_asiento),
    CONSTRAINT fk_asiento_detalle_cuenta FOREIGN KEY (codigo_cuenta) REFERENCES contabilidad.cuenta_contable (codigo_cuenta),
    CONSTRAINT fk_asiento_detalle_moneda FOREIGN KEY (codigo_moneda) REFERENCES contabilidad.moneda (codigo_moneda),
    CONSTRAINT fk_asiento_detalle_unidad FOREIGN KEY (codigo_unidad_negocio) REFERENCES contabilidad.unidad_negocio (codigo_unidad_negocio),
    CONSTRAINT fk_asiento_detalle_centro FOREIGN KEY (codigo_centro_costo) REFERENCES contabilidad.centro_costo (codigo_centro_costo),
    CONSTRAINT fk_asiento_detalle_auxiliar FOREIGN KEY (codigo_tipo_auxiliar, codigo_auxiliar) REFERENCES contabilidad.auxiliar_contable (codigo_tipo_auxiliar, codigo_auxiliar),
    CONSTRAINT ck_asiento_detalle_linea CHECK (numero_linea > 0),
    CONSTRAINT ck_asiento_detalle_tipo_cambio CHECK (tipo_cambio IS NULL OR tipo_cambio > 0)
);
CREATE INDEX ix_asiento_detalle_cuenta ON contabilidad.asiento_detalle (codigo_cuenta);
CREATE INDEX ix_asiento_detalle_unidad ON contabilidad.asiento_detalle (codigo_unidad_negocio);
CREATE INDEX ix_asiento_detalle_centro ON contabilidad.asiento_detalle (codigo_centro_costo);
CREATE INDEX ix_asiento_detalle_auxiliar ON contabilidad.asiento_detalle (codigo_tipo_auxiliar, codigo_auxiliar) WHERE codigo_tipo_auxiliar IS NOT NULL;
COMMENT ON TABLE contabilidad.asiento_detalle IS 'Líneas del asiento. SAI: cndtr (gestión abierta) y cnhdt (histórico), con las glosas largas de cndtrglo';
COMMENT ON COLUMN contabilidad.asiento_detalle.importe_bs IS 'Importe en Bs con signo: positivo = debe, negativo = haber. SAI cndtrimpi';
COMMENT ON COLUMN contabilidad.asiento_detalle.importe_usd IS 'Importe en USD con el mismo signo. SAI cndtrimpc';
COMMENT ON COLUMN contabilidad.asiento_detalle.codigo_moneda IS 'Moneda en que se originó la línea. SAI cndtrcmon';
COMMENT ON COLUMN contabilidad.asiento_detalle.tipo_cambio IS 'Tipo de cambio usado para convertir la línea. SAI cndtrcamb';

-- -----------------------------------------------------------------------------
-- Interfaz con los módulos de origen
-- -----------------------------------------------------------------------------
CREATE TABLE contabilidad.interfaz_comprobante (
    id_interfaz_comprobante   bigserial      NOT NULL,
    codigo_modulo             smallint       NOT NULL,
    numero_documento          integer        NOT NULL,
    numero_linea              smallint       NOT NULL,
    fecha_contable            date           NOT NULL,
    codigo_cuenta             varchar(16)    NOT NULL,
    codigo_unidad_negocio     smallint       NOT NULL,
    codigo_centro_costo       smallint       NOT NULL DEFAULT 0,
    codigo_moneda_operacion   smallint,
    importe_bs                numeric(18,2)  NOT NULL,
    importe_usd               numeric(18,2)  NOT NULL,
    tipo_cambio               numeric(18,8),
    descripcion               varchar(80),
    descripcion_adicional     varchar(80),
    numero_operacion          integer,
    numero_transaccion        integer,
    fecha_transaccion         date,
    sai_grupo_transaccion     smallint,
    sai_codigo_transaccion    smallint,
    sai_cuenta_corriente      smallint,
    sai_subcuenta             integer,
    estado                    varchar(13)    NOT NULL DEFAULT 'PENDIENTE',
    mensaje_error             text,
    id_asiento                bigint,
    usuario_creacion          varchar(30)    NOT NULL DEFAULT current_user,
    fecha_creacion            timestamptz    NOT NULL DEFAULT now(),
    usuario_proceso           varchar(30),
    fecha_proceso             timestamptz,
    CONSTRAINT pk_interfaz_comprobante PRIMARY KEY (id_interfaz_comprobante),
    CONSTRAINT uk_interfaz_comprobante_linea UNIQUE (codigo_modulo, numero_documento, numero_linea),
    CONSTRAINT fk_interfaz_comprobante_modulo FOREIGN KEY (codigo_modulo) REFERENCES contabilidad.modulo_origen (codigo_modulo),
    CONSTRAINT fk_interfaz_comprobante_moneda FOREIGN KEY (codigo_moneda_operacion) REFERENCES contabilidad.moneda (codigo_moneda),
    CONSTRAINT fk_interfaz_comprobante_asiento FOREIGN KEY (id_asiento) REFERENCES contabilidad.asiento (id_asiento),
    CONSTRAINT ck_interfaz_comprobante_estado CHECK (estado IN ('PENDIENTE', 'CONTABILIZADO', 'ERROR', 'DESCARTADO')),
    CONSTRAINT ck_interfaz_comprobante_asiento CHECK ((estado = 'CONTABILIZADO') = (id_asiento IS NOT NULL))
);
CREATE INDEX ix_interfaz_comprobante_pendiente ON contabilidad.interfaz_comprobante (fecha_contable, codigo_modulo, numero_documento)
    WHERE estado IN ('PENDIENTE', 'ERROR');
CREATE INDEX ix_interfaz_comprobante_asiento ON contabilidad.interfaz_comprobante (id_asiento) WHERE id_asiento IS NOT NULL;
COMMENT ON TABLE contabilidad.interfaz_comprobante IS 'Líneas de comprobante que dejan los módulos (cobros, reservas, caja, tesorería...) para contabilizar. SAI: cntcn (lo que escribe pins_cntcn). El cierre diario las agrupa por módulo y documento en un asiento';
COMMENT ON COLUMN contabilidad.interfaz_comprobante.codigo_moneda_operacion IS 'Moneda en la que el documento tiene que cuadrar exacto (SAI: parámetro xcmon de pcuadre_cntcn). Si viene vacía se deduce';
COMMENT ON COLUMN contabilidad.interfaz_comprobante.estado IS 'PENDIENTE (SAI cntcnpost 0), CONTABILIZADO (SAI 9), ERROR (no se pudo contabilizar: ver mensaje_error) o DESCARTADO';
COMMENT ON COLUMN contabilidad.interfaz_comprobante.sai_grupo_transaccion IS 'SAI cntcnpref: grupo del catálogo del módulo (por ejemplo 27 = tipos de transacción en ilcon)';
COMMENT ON COLUMN contabilidad.interfaz_comprobante.sai_codigo_transaccion IS 'SAI cntcncorr: código dentro del grupo (por ejemplo 2 = cobros de contratos)';

-- -----------------------------------------------------------------------------
-- Saldos
-- -----------------------------------------------------------------------------
CREATE TABLE contabilidad.saldo_diario (
    fecha_contable         date           NOT NULL,
    codigo_cuenta          varchar(16)    NOT NULL,
    codigo_unidad_negocio  smallint       NOT NULL,
    codigo_centro_costo    smallint       NOT NULL,
    debe_bs                numeric(18,2)  NOT NULL,
    haber_bs               numeric(18,2)  NOT NULL,
    debe_usd               numeric(18,2)  NOT NULL,
    haber_usd              numeric(18,2)  NOT NULL,
    cantidad_lineas        integer        NOT NULL,
    CONSTRAINT pk_saldo_diario PRIMARY KEY (fecha_contable, codigo_cuenta, codigo_unidad_negocio, codigo_centro_costo),
    CONSTRAINT fk_saldo_diario_dia FOREIGN KEY (fecha_contable) REFERENCES contabilidad.dia_contable (fecha_contable),
    CONSTRAINT fk_saldo_diario_cuenta FOREIGN KEY (codigo_cuenta) REFERENCES contabilidad.cuenta_contable (codigo_cuenta)
);
CREATE INDEX ix_saldo_diario_cuenta ON contabilidad.saldo_diario (codigo_cuenta, fecha_contable);
COMMENT ON TABLE contabilidad.saldo_diario IS 'Movimiento del día por cuenta, unidad y centro (debe y haber en positivo). Lo calcula el cierre diario';

CREATE TABLE contabilidad.saldo_mensual (
    gestion                smallint       NOT NULL,
    periodo                smallint       NOT NULL,
    codigo_cuenta          varchar(16)    NOT NULL,
    codigo_unidad_negocio  smallint       NOT NULL,
    codigo_centro_costo    smallint       NOT NULL,
    saldo_inicial_bs       numeric(18,2)  NOT NULL,
    debe_bs                numeric(18,2)  NOT NULL,
    haber_bs               numeric(18,2)  NOT NULL,
    saldo_final_bs         numeric(18,2)  NOT NULL,
    saldo_inicial_usd      numeric(18,2)  NOT NULL,
    debe_usd               numeric(18,2)  NOT NULL,
    haber_usd              numeric(18,2)  NOT NULL,
    saldo_final_usd        numeric(18,2)  NOT NULL,
    CONSTRAINT pk_saldo_mensual PRIMARY KEY (gestion, periodo, codigo_cuenta, codigo_unidad_negocio, codigo_centro_costo),
    CONSTRAINT fk_saldo_mensual_periodo FOREIGN KEY (gestion, periodo) REFERENCES contabilidad.periodo_contable (gestion, periodo),
    CONSTRAINT fk_saldo_mensual_cuenta FOREIGN KEY (codigo_cuenta) REFERENCES contabilidad.cuenta_contable (codigo_cuenta),
    CONSTRAINT ck_saldo_mensual_bs CHECK (saldo_final_bs = saldo_inicial_bs + debe_bs - haber_bs),
    CONSTRAINT ck_saldo_mensual_usd CHECK (saldo_final_usd = saldo_inicial_usd + debe_usd - haber_usd)
);
CREATE INDEX ix_saldo_mensual_cuenta ON contabilidad.saldo_mensual (codigo_cuenta, gestion, periodo);
COMMENT ON TABLE contabilidad.saldo_mensual IS 'Saldo por período, cuenta, unidad y centro (con signo: positivo deudor). Lo calcula el cierre mensual; el período 13 es el saldo final de la gestión. El SAI tenía la tabla vacía cnhmc';

CREATE TABLE contabilidad.cuenta_contable_gestion (
    gestion               smallint     NOT NULL,
    codigo_cuenta         varchar(16)  NOT NULL,
    nombre                varchar(80)  NOT NULL,
    codigo_grupo          char(1)      NOT NULL,
    nivel                 smallint     NOT NULL,
    codigo_cuenta_padre   varchar(16),
    es_imputable          boolean      NOT NULL,
    codigo_moneda         smallint,
    exige_centro_costo    boolean      NOT NULL,
    codigo_tipo_auxiliar  smallint,
    activo                boolean      NOT NULL,
    CONSTRAINT pk_cuenta_contable_gestion PRIMARY KEY (gestion, codigo_cuenta),
    CONSTRAINT fk_cuenta_contable_gestion_gestion FOREIGN KEY (gestion) REFERENCES contabilidad.gestion (gestion)
);
COMMENT ON TABLE contabilidad.cuenta_contable_gestion IS 'Foto del plan de cuentas al cerrar cada gestión. SAI: cnpch';

-- -----------------------------------------------------------------------------
-- Vistas
-- -----------------------------------------------------------------------------
CREATE VIEW contabilidad.v_cuenta_contable_ancestro AS
WITH RECURSIVE ancestro (codigo_cuenta, codigo_cuenta_ancestro, nivel_ancestro) AS (
    SELECT c.codigo_cuenta, c.codigo_cuenta, c.nivel
    FROM contabilidad.cuenta_contable c
    UNION ALL
    SELECT a.codigo_cuenta, padre.codigo_cuenta, padre.nivel
    FROM ancestro a
    JOIN contabilidad.cuenta_contable hijo ON hijo.codigo_cuenta = a.codigo_cuenta_ancestro
    JOIN contabilidad.cuenta_contable padre ON padre.codigo_cuenta = hijo.codigo_cuenta_padre
)
SELECT codigo_cuenta, codigo_cuenta_ancestro, nivel_ancestro FROM ancestro;
COMMENT ON VIEW contabilidad.v_cuenta_contable_ancestro IS 'Cada cuenta con ella misma y todas sus cuentas superiores: sirve para acumular saldos por nivel';

CREATE VIEW contabilidad.v_asiento_detalle AS
SELECT a.id_asiento, a.gestion, a.periodo, a.numero_asiento, a.fecha_contable,
       a.codigo_tipo_documento, a.codigo_modulo, a.numero_documento, a.glosa AS glosa_asiento,
       a.estado, a.origen, a.tipo_asiento_sistema,
       d.numero_linea, d.codigo_cuenta, c.nombre AS nombre_cuenta, c.codigo_grupo,
       d.codigo_unidad_negocio, d.codigo_centro_costo, d.codigo_tipo_auxiliar, d.codigo_auxiliar,
       d.glosa AS glosa_linea, d.codigo_moneda, d.tipo_cambio, d.importe_bs, d.importe_usd,
       greatest(d.importe_bs, 0)  AS debe_bs,  greatest(-d.importe_bs, 0)  AS haber_bs,
       greatest(d.importe_usd, 0) AS debe_usd, greatest(-d.importe_usd, 0) AS haber_usd
FROM contabilidad.asiento a
JOIN contabilidad.asiento_detalle d ON d.id_asiento = a.id_asiento
JOIN contabilidad.cuenta_contable c ON c.codigo_cuenta = d.codigo_cuenta;
COMMENT ON VIEW contabilidad.v_asiento_detalle IS 'Líneas con su cabecera, el nombre de la cuenta y el importe separado en debe y haber';

COMMIT;

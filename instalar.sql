-- =============================================================================
-- Contabilidad · instalación completa
-- -----------------------------------------------------------------------------
-- Uso (con el usuario que va a ser dueño del esquema, nunca un superusuario de aplicación):
--   psql -h <servidor> -d <base> -U <dueño> -f sql/postgres/contabilidad/instalar.sql
--
-- Cada script corre en su propia transacción; si uno falla, psql se detiene y
-- los anteriores quedan aplicados (ver "Desinstalar" en el README).
-- 005 crea roles: necesita CREATEROLE. 006 solo hace falta para migrar el SAI.
-- =============================================================================

\set ON_ERROR_STOP on

\ir migraciones/001_estructuras.sql
\ir migraciones/002_reglas_y_registro.sql
\ir migraciones/003_cierres.sql
\ir migraciones/004_reportes.sql
\ir migraciones/005_permisos.sql
\ir migraciones/006_migracion_sai.sql

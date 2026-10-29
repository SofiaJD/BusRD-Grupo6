/* =====================================================================
   07_seguridad.sql  |  BusRD  |  E4 Seguridad (Unidad III)
   Vistas, roles, usuarios de prueba y evidencia de accesos permitidos y
   denegados. Tomar captura de cada bloque de pruebas.
   ===================================================================== */
USE BusRD;
GO

/* ---------- 1. Vistas ---------- */
CREATE OR ALTER VIEW dbo.vw_AsientosDisponibles
AS
SELECT v.ViajeID, v.RutaID, v.FechaSalida, a.AsientoID, a.Numero, a.Ubicacion
FROM dbo.Viajes v
JOIN dbo.Asientos a ON a.AutobusID = v.AutobusID
WHERE v.Estado = 'Programado'
  AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b
                  WHERE b.ViajeID = v.ViajeID
                    AND b.AsientoID = a.AsientoID
                    AND b.Estado = 'Activo');
GO

-- Sin datos personales de clientes (no incluye Email ni Telefono)
CREATE OR ALTER VIEW dbo.vw_VentasMensuales
AS
SELECT YEAR(p.FechaPago)  AS Anio,
       MONTH(p.FechaPago) AS Mes,
       b.Canal,
       COUNT(CASE WHEN p.Tipo = 'Pago'    THEN 1 END) AS Pagos,
       COUNT(CASE WHEN p.Tipo = 'Reverso' THEN 1 END) AS Reversos,
       SUM(p.Monto)                                    AS VentaNeta
FROM dbo.Pagos p
JOIN dbo.Boletos b ON b.BoletoID = p.BoletoID
GROUP BY YEAR(p.FechaPago), MONTH(p.FechaPago), b.Canal;
GO

/* ---------- 2. Roles ---------- */
IF DATABASE_PRINCIPAL_ID('rol_taquilla') IS NULL CREATE ROLE rol_taquilla;
IF DATABASE_PRINCIPAL_ID('rol_reportes') IS NULL CREATE ROLE rol_reportes;
IF DATABASE_PRINCIPAL_ID('rol_admin')    IS NULL CREATE ROLE rol_admin;
GO

-- Taquilla: solo ejecutar los procedimientos y leer la vista. Nada de tablas.
GRANT EXECUTE ON OBJECT::dbo.sp_VenderBoleto TO rol_taquilla;
GRANT EXECUTE ON OBJECT::dbo.sp_AnularBoleto TO rol_taquilla;
GRANT SELECT  ON OBJECT::dbo.vw_AsientosDisponibles TO rol_taquilla;

-- Reportes: solo la vista de ventas. Ademas se niega explicitamente el acceso a
-- las columnas sensibles de Clientes por si algun dia se le otorga SELECT en la tabla.
GRANT SELECT ON OBJECT::dbo.vw_VentasMensuales TO rol_reportes;
DENY  SELECT ON OBJECT::dbo.Clientes (Email, Telefono) TO rol_reportes;

-- Admin: administracion completa de esta base
GRANT CONTROL ON DATABASE::BusRD TO rol_admin;
GO

/* ---------- 3. Usuarios de prueba (sin login) ---------- */
IF DATABASE_PRINCIPAL_ID('u_taquilla') IS NULL CREATE USER u_taquilla WITHOUT LOGIN;
IF DATABASE_PRINCIPAL_ID('u_reportes') IS NULL CREATE USER u_reportes WITHOUT LOGIN;
IF DATABASE_PRINCIPAL_ID('u_admin')    IS NULL CREATE USER u_admin    WITHOUT LOGIN;

ALTER ROLE rol_taquilla ADD MEMBER u_taquilla;
ALTER ROLE rol_reportes ADD MEMBER u_reportes;
ALTER ROLE rol_admin    ADD MEMBER u_admin;
GO

/* ---------- 4. PRUEBAS (permitido y denegado) ---------- */
DECLARE @v INT = 16001;   -- <== CAMBIAR (viaje asignado)
DECLARE @asiento INT, @boleto INT;

SELECT TOP 1 @asiento = AsientoID FROM dbo.vw_AsientosDisponibles WHERE ViajeID = @v ORDER BY AsientoID DESC;

PRINT '=== rol_taquilla ===';
EXECUTE AS USER = 'u_taquilla';
    -- PERMITIDO 1: leer la vista
    SELECT TOP 5 * FROM dbo.vw_AsientosDisponibles WHERE ViajeID = @v;
    -- PERMITIDO 2: vender y anular por procedimiento (sin permiso sobre las tablas)
    EXEC dbo.sp_VenderBoleto @ViajeID = @v, @AsientoID = @asiento, @ClienteID = 1,
         @Canal = 'Taquilla', @Metodo = 'Efectivo', @BoletoID = @boleto OUTPUT;
    PRINT 'PERMITIDO: venta realizada, BoletoID = ' + CAST(@boleto AS VARCHAR(20));
    EXEC dbo.sp_AnularBoleto @BoletoID = @boleto;
    PRINT 'PERMITIDO: boleto anulado';
    -- DENEGADO 1: leer tabla Boletos
    BEGIN TRY SELECT TOP 1 * FROM dbo.Boletos; END TRY
    BEGIN CATCH PRINT 'DENEGADO: ' + ERROR_MESSAGE(); END CATCH;
    -- DENEGADO 2: borrar boletos directamente
    BEGIN TRY DELETE FROM dbo.Boletos WHERE BoletoID = -1; END TRY
    BEGIN CATCH PRINT 'DENEGADO: ' + ERROR_MESSAGE(); END CATCH;
REVERT;

PRINT '=== rol_reportes ===';
EXECUTE AS USER = 'u_reportes';
    -- PERMITIDO 1: vista de ventas mensuales
    SELECT TOP 5 * FROM dbo.vw_VentasMensuales ORDER BY Anio DESC, Mes DESC;
    -- PERMITIDO 2: conteo sobre la misma vista
    SELECT COUNT(*) AS FilasVista FROM dbo.vw_VentasMensuales;
    -- DENEGADO 1: Email y Telefono de clientes
    BEGIN TRY SELECT TOP 1 Email, Telefono FROM dbo.Clientes; END TRY
    BEGIN CATCH PRINT 'DENEGADO: ' + ERROR_MESSAGE(); END CATCH;
    -- DENEGADO 2: ejecutar el procedimiento de venta
    BEGIN TRY EXEC dbo.sp_AnularBoleto @BoletoID = -1; END TRY
    BEGIN CATCH PRINT 'DENEGADO: ' + ERROR_MESSAGE(); END CATCH;
REVERT;

PRINT '=== rol_admin ===';
EXECUTE AS USER = 'u_admin';
    -- PERMITIDO 1: leer tablas completas
    SELECT TOP 5 ClienteID, Nombre, Email, Telefono FROM dbo.Clientes;
    -- PERMITIDO 2: consultar metadatos de seguridad
    SELECT TOP 5 name, type_desc FROM sys.database_principals WHERE name LIKE 'rol[_]%';
    -- DENEGADO 1: no es sysadmin del servidor, no puede cambiar configuracion de la instancia
    BEGIN TRY EXEC sp_configure 'show advanced options', 1; END TRY
    BEGIN CATCH PRINT 'DENEGADO (fuera de la base): ' + ERROR_MESSAGE(); END CATCH;
    -- DENEGADO 2: tampoco puede leer otra base de datos sin permiso
    BEGIN TRY SELECT TOP 1 name FROM master.sys.sql_logins; END TRY
    BEGIN CATCH PRINT 'DENEGADO (otra base): ' + ERROR_MESSAGE(); END CATCH;
REVERT;
GO

/* ---------- 5. Para el informe ----------
   MINIMO PRIVILEGIO: cada rol recibe solo lo necesario para su trabajo.
   Si un usuario de taquilla se ve comprometido o se equivoca, no puede borrar
   boletos ni ver datos personales; solo puede hacer las dos operaciones permitidas.

   OWNERSHIP CHAINING: los procedimientos y vistas pertenecen a dbo, igual que las
   tablas. Cuando un procedimiento accede a un objeto con el mismo propietario, SQL
   Server NO vuelve a verificar los permisos sobre ese objeto; solo comprueba el
   EXECUTE sobre el procedimiento. Por eso rol_taquilla puede vender boletos sin
   tener INSERT ni SELECT sobre Boletos y Pagos, y la logica (validaciones,
   transaccion, bloqueo) se ejecuta siempre como esta escrita.
   Nota: el encadenamiento no cubre SQL dinamico (EXEC(...)), que se evalua con los
   permisos del llamador. */

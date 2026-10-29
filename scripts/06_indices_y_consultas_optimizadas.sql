/* =============================================================
   BusRD - E3 OPTIMIZACION (Unidad II)
   ============================================================= */

USE BusRD;
SET NOCOUNT ON;

/* =============================================================
   0. PARAMETROS
   ============================================================= */
DECLARE @Grupo INT = 1;
DECLARE @ViajeIDAsignado INT = 16000;
DECLARE @Cedula CHAR(11) = '40200006000';

/* Validaciones basicas */
IF NOT EXISTS (SELECT 1 FROM dbo.Viajes WHERE ViajeID = @ViajeIDAsignado)
BEGIN
    THROW 50001, 'El viaje asignado no existe.', 1;
END;

IF NOT EXISTS (SELECT 1 FROM dbo.Clientes WHERE Cedula = @Cedula)
BEGIN
    THROW 50002, 'La cedula no existe.', 1;
END;

/* =============================================================
   1. LINEA BASE - CONSULTAS ORIGINALES
   ============================================================= */
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

-- C1: Busqueda de asientos disponibles (Original)
SELECT s.NumeroAsiento, s.Ubicacion
FROM dbo.Viajes v
JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.ViajeID = @ViajeIDAsignado
  AND s.NumeroAsiento NOT IN
      (SELECT b.NumeroAsiento
       FROM dbo.Boletos b
       WHERE b.ViajeID = @ViajeIDAsignado
         AND b.Estado = 'Activo')
ORDER BY s.NumeroAsiento;

-- C2: Historial del cliente (Original)
SELECT c.Nombre, c.Apellido, r.Origen, r.Destino,
       v.FechaSalida, b.NumeroAsiento, b.Precio, b.Estado
FROM dbo.Clientes c
JOIN dbo.Boletos b ON b.ClienteID = c.ClienteID
JOIN dbo.Viajes  v ON v.ViajeID   = b.ViajeID
JOIN dbo.Rutas   r ON r.RutaID    = v.RutaID
WHERE LTRIM(RTRIM(c.Cedula)) = @Cedula
ORDER BY v.FechaSalida DESC;

-- C3: Reporte de ingresos mensuales (Original)
SELECT r.Origen, r.Destino, MONTH(b.FechaVenta) AS Mes,
       COUNT(*) AS Boletos, SUM(p.Monto) AS Ingresos
FROM dbo.Boletos b
JOIN dbo.Pagos  p ON p.BoletoID = b.BoletoID
JOIN dbo.Viajes v ON v.ViajeID  = b.ViajeID
JOIN dbo.Rutas  r ON r.RutaID   = v.RutaID
WHERE YEAR(b.FechaVenta) = 2025
  AND b.Estado = 'Activo'
GROUP BY r.Origen, r.Destino, MONTH(b.FechaVenta)
ORDER BY r.Origen, r.Destino, Mes;

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;

/* =============================================================
   2. CREACION DE INDICES
   ============================================================= */

-- Indice para C1 (Boletos activos por viaje y asiento)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.Boletos') AND name = 'IX_Boletos_Activo_Viaje_Asiento')
BEGIN
    CREATE NONCLUSTERED INDEX IX_Boletos_Activo_Viaje_Asiento
        ON dbo.Boletos (ViajeID, NumeroAsiento)
        WHERE Estado = 'Activo';
END;

-- Indice para C2 (Busqueda directa por Cedula)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.Clientes') AND name = 'IX_Clientes_Cedula')
BEGIN
    CREATE NONCLUSTERED INDEX IX_Clientes_Cedula
        ON dbo.Clientes (Cedula)
        INCLUDE (Nombre, Apellido);
END;

-- Indice para C2 (Historial de boletos por cliente)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.Boletos') AND name = 'IX_Boletos_Cliente_Historial')
BEGIN
    CREATE NONCLUSTERED INDEX IX_Boletos_Cliente_Historial
        ON dbo.Boletos (ClienteID, ViajeID)
        INCLUDE (NumeroAsiento, Precio, Estado);
END;

-- Indice para C3 (Filtro por rango de fechas)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.Boletos') AND name = 'IX_Boletos_Activo_FechaVenta')
BEGIN
    CREATE NONCLUSTERED INDEX IX_Boletos_Activo_FechaVenta
        ON dbo.Boletos (FechaVenta)
        INCLUDE (ViajeID)
        WHERE Estado = 'Activo';
END;

-- Indice para C3 (Join eficiente con Pagos)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.Pagos') AND name = 'IX_Pagos_BoletoID')
BEGIN
    CREATE NONCLUSTERED INDEX IX_Pagos_BoletoID
        ON dbo.Pagos (BoletoID)
        INCLUDE (Monto);
END;

-- Actualizacion de estadisticas
UPDATE STATISTICS dbo.Clientes WITH FULLSCAN;
UPDATE STATISTICS dbo.Boletos;
UPDATE STATISTICS dbo.Pagos;

/* =============================================================
   3. CONSULTAS OPTIMIZADAS
   ============================================================= */
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

-- C1 Optimizada (Uso de NOT EXISTS)
SELECT s.NumeroAsiento, s.Ubicacion
FROM dbo.Viajes v
JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.ViajeID = @ViajeIDAsignado
  AND NOT EXISTS
      (SELECT 1
       FROM dbo.Boletos b
       WHERE b.ViajeID = @ViajeIDAsignado
         AND b.NumeroAsiento = s.NumeroAsiento
         AND b.Estado = 'Activo')
ORDER BY s.NumeroAsiento;

-- C2 Optimizada (Predicado SARGABLE sin funciones sobre la columna)
SELECT c.Nombre, c.Apellido, r.Origen, r.Destino,
       v.FechaSalida, b.NumeroAsiento, b.Precio, b.Estado
FROM dbo.Clientes c
JOIN dbo.Boletos b ON b.ClienteID = c.ClienteID
JOIN dbo.Viajes  v ON v.ViajeID   = b.ViajeID
JOIN dbo.Rutas   r ON r.RutaID    = v.RutaID
WHERE c.Cedula = @Cedula
ORDER BY v.FechaSalida DESC;

-- C3 Optimizada (Rango de fechas SARGABLE)
SELECT r.Origen, r.Destino, MONTH(b.FechaVenta) AS Mes,
       COUNT(*) AS Boletos, SUM(p.Monto) AS Ingresos
FROM dbo.Boletos b
JOIN dbo.Pagos  p ON p.BoletoID = b.BoletoID
JOIN dbo.Viajes v ON v.ViajeID  = b.ViajeID
JOIN dbo.Rutas  r ON r.RutaID   = v.RutaID
WHERE b.FechaVenta >= '20250101'
  AND b.FechaVenta <  '20260101'
  AND b.Estado = 'Activo'
GROUP BY r.Origen, r.Destino, MONTH(b.FechaVenta)
ORDER BY r.Origen, r.Destino, Mes;

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;

/* =============================================================
   4. PRUEBA DE EQUIVALENCIA
   ============================================================= */
DROP TABLE IF EXISTS #C1_Original, #C1_Optimizada, #C2_Original, #C2_Optimizada, #C3_Original, #C3_Optimizada;

-- Guardar resultados C1
SELECT s.NumeroAsiento, s.Ubicacion INTO #C1_Original FROM dbo.Viajes v JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID WHERE v.ViajeID = @ViajeIDAsignado AND s.NumeroAsiento NOT IN (SELECT b.NumeroAsiento FROM dbo.Boletos b WHERE b.ViajeID = @ViajeIDAsignado AND b.Estado = 'Activo');
SELECT s.NumeroAsiento, s.Ubicacion INTO #C1_Optimizada FROM dbo.Viajes v JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID WHERE v.ViajeID = @ViajeIDAsignado AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b WHERE b.ViajeID = @ViajeIDAsignado AND b.NumeroAsiento = s.NumeroAsiento AND b.Estado = 'Activo');

-- Guardar resultados C2
SELECT c.Nombre, c.Apellido, r.Origen, r.Destino, v.FechaSalida, b.NumeroAsiento, b.Precio, b.Estado INTO #C2_Original FROM dbo.Clientes c JOIN dbo.Boletos b ON b.ClienteID = c.ClienteID JOIN dbo.Viajes v ON v.ViajeID = b.ViajeID JOIN dbo.Rutas r ON r.RutaID = v.RutaID WHERE LTRIM(RTRIM(c.Cedula)) = @Cedula;
SELECT c.Nombre, c.Apellido, r.Origen, r.Destino, v.FechaSalida, b.NumeroAsiento, b.Precio, b.Estado INTO #C2_Optimizada FROM dbo.Clientes c JOIN dbo.Boletos b ON b.ClienteID = c.ClienteID JOIN dbo.Viajes v ON v.ViajeID = b.ViajeID JOIN dbo.Rutas r ON r.RutaID = v.RutaID WHERE c.Cedula = @Cedula;

-- Guardar resultados C3
SELECT r.Origen, r.Destino, MONTH(b.FechaVenta) AS Mes, COUNT(*) AS Boletos, SUM(p.Monto) AS Ingresos INTO #C3_Original FROM dbo.Boletos b JOIN dbo.Pagos p ON p.BoletoID = b.BoletoID JOIN dbo.Viajes v ON v.ViajeID = b.ViajeID JOIN dbo.Rutas r ON r.RutaID = v.RutaID WHERE YEAR(b.FechaVenta) = 2025 AND b.Estado = 'Activo' GROUP BY r.Origen, r.Destino, MONTH(b.FechaVenta);
SELECT r.Origen, r.Destino, MONTH(b.FechaVenta) AS Mes, COUNT(*) AS Boletos, SUM(p.Monto) AS Ingresos INTO #C3_Optimizada FROM dbo.Boletos b JOIN dbo.Pagos p ON p.BoletoID = b.BoletoID JOIN dbo.Viajes v ON v.ViajeID = b.ViajeID JOIN dbo.Rutas r ON r.RutaID = v.RutaID WHERE b.FechaVenta >= '20250101' AND b.FechaVenta < '20260101' AND b.Estado = 'Activo' GROUP BY r.Origen, r.Destino, MONTH(b.FechaVenta);

-- Validar que la cantidad de filas sea identica
SELECT 'C1' Consulta, (SELECT COUNT(*) FROM #C1_Original) Original, (SELECT COUNT(*) FROM #C1_Optimizada) Optimizada
UNION ALL
SELECT 'C2', (SELECT COUNT(*) FROM #C2_Original), (SELECT COUNT(*) FROM #C2_Optimizada)
UNION ALL
SELECT 'C3', (SELECT COUNT(*) FROM #C3_Original), (SELECT COUNT(*) FROM #C3_Optimizada);

/* =============================================================
   5. INVENTARIO DE INDICES CREADOS
   ============================================================= */
SELECT OBJECT_NAME(i.object_id) AS Tabla, i.name AS Indice, i.type_desc, i.has_filter
FROM sys.indexes i
WHERE i.object_id IN (OBJECT_ID('dbo.Boletos'), OBJECT_ID('dbo.Clientes'), OBJECT_ID('dbo.Pagos'))
  AND i.name IN ('IX_Boletos_Activo_Viaje_Asiento', 'IX_Clientes_Cedula', 'IX_Boletos_Cliente_Historial', 'IX_Boletos_Activo_FechaVenta', 'IX_Pagos_BoletoID')
ORDER BY Tabla, Indice;
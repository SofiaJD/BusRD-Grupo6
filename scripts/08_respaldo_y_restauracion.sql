/* =====================================================================
   08_respaldo_y_restauracion.sql  |  BusRD  |  E5 Respaldo y recuperacion
   Ejecutar en UNA sola ventana de SSMS, de arriba hacia abajo, un bloque
   a la vez (los datos del punto de restauracion viven en la tabla temporal
   #punto, que dura lo que dure la ventana).
   Requiere haber ejecutado 07_seguridad.sql (usa vw_AsientosDisponibles).
   ===================================================================== */
USE master;
GO

/* ---------- 0. Carpeta de respaldos ---------- */
EXEC master.sys.xp_create_subdir N'C:\Backups\BusRD\';
GO

/* ---------- 1. Modelo de recuperacion FULL ----------
   Por que: en SIMPLE el log se trunca solo y no se puede restaurar a un punto en
   el tiempo. Con FULL el log se conserva hasta el siguiente respaldo de log, lo
   que permite RESTORE ... STOPAT justo antes de un error humano (como un DELETE). */
ALTER DATABASE BusRD SET RECOVERY FULL;
SELECT name, recovery_model_desc FROM sys.databases WHERE name = 'BusRD';
GO

/* ---------- 2. Secuencia de respaldo ---------- */
-- Parametro: viaje asignado al grupo
IF OBJECT_ID('tempdb..#punto') IS NOT NULL DROP TABLE #punto;
CREATE TABLE #punto (ViajeID INT, HoraAntesDelete DATETIME NULL, BoletosViajeAntes INT NULL);
INSERT #punto (ViajeID) VALUES (16001);   -- <== CAMBIAR (viaje asignado)

IF OBJECT_ID('tempdb..#vendidos') IS NOT NULL DROP TABLE #vendidos;
CREATE TABLE #vendidos (BoletoID INT, Lote VARCHAR(20));

-- 2.1 FULL
BACKUP DATABASE BusRD TO DISK = N'C:\Backups\BusRD\BusRD_full.bak' WITH INIT, CHECKSUM, STATS = 10;
GO

-- 2.2 Vender 5 boletos
DECLARE @v INT = (SELECT ViajeID FROM #punto), @i INT = 1, @a INT, @b INT;
WHILE @i <= 5
BEGIN
    SELECT TOP 1 @a = AsientoID FROM BusRD.dbo.vw_AsientosDisponibles WHERE ViajeID = @v ORDER BY AsientoID DESC;
    EXEC BusRD.dbo.sp_VenderBoleto @ViajeID = @v, @AsientoID = @a, @ClienteID = @i,
         @Canal = 'Taquilla', @Metodo = 'Efectivo', @BoletoID = @b OUTPUT;
    INSERT #vendidos VALUES (@b, 'antes_diferencial');
    SET @i += 1;
END;
SELECT * FROM #vendidos;
GO

-- 2.3 DIFERENCIAL
BACKUP DATABASE BusRD TO DISK = N'C:\Backups\BusRD\BusRD_diff.bak' WITH DIFFERENTIAL, INIT, CHECKSUM, STATS = 10;
GO

-- 2.4 Vender 3 boletos mas
DECLARE @v INT = (SELECT ViajeID FROM #punto), @i INT = 6, @a INT, @b INT;
WHILE @i <= 8
BEGIN
    SELECT TOP 1 @a = AsientoID FROM BusRD.dbo.vw_AsientosDisponibles WHERE ViajeID = @v ORDER BY AsientoID DESC;
    EXEC BusRD.dbo.sp_VenderBoleto @ViajeID = @v, @AsientoID = @a, @ClienteID = @i,
         @Canal = 'Web', @Metodo = 'Tarjeta', @BoletoID = @b OUTPUT;
    INSERT #vendidos VALUES (@b, 'antes_log');
    SET @i += 1;
END;
SELECT * FROM #vendidos;
GO

-- 2.5 LOG
BACKUP LOG BusRD TO DISK = N'C:\Backups\BusRD\BusRD_log1.trn' WITH INIT, CHECKSUM, STATS = 10;
GO

-- 2.6 Anotar la hora exacta (guardada en #punto y mostrada para la captura)
UPDATE #punto
SET HoraAntesDelete   = GETDATE(),
    BoletosViajeAntes = (SELECT COUNT(*) FROM BusRD.dbo.Boletos b WHERE b.ViajeID = #punto.ViajeID);
SELECT 'HORA ANTES DEL DELETE' AS Nota, CONVERT(VARCHAR(23), HoraAntesDelete, 121) AS Hora, BoletosViajeAntes FROM #punto;
WAITFOR DELAY '00:00:03';   -- margen para que el STOPAT quede antes del error
GO

-- 2.7 Simular el error: borrar TODOS los boletos del viaje
--     (primero los pagos, por la llave foranea Pagos -> Boletos)
DECLARE @v INT = (SELECT ViajeID FROM #punto);
BEGIN TRAN;
    DELETE p FROM BusRD.dbo.Pagos p JOIN BusRD.dbo.Boletos b ON b.BoletoID = p.BoletoID WHERE b.ViajeID = @v;
    DELETE FROM BusRD.dbo.Boletos WHERE ViajeID = @v;
COMMIT;
SELECT COUNT(*) AS BoletosDelViajeDespuesDelDelete FROM BusRD.dbo.Boletos WHERE ViajeID = @v;
GO

-- 2.8 Respaldo de LOG DE COLA (tail-log): captura el DELETE y deja la base en RESTORING
BACKUP LOG BusRD TO DISK = N'C:\Backups\BusRD\BusRD_tail.trn' WITH NORECOVERY, INIT, CHECKSUM, STATS = 10;
GO

/* ---------- 3. Restaurar en BusRD_Recuperada hasta antes del DELETE ---------- */
IF DB_ID('BusRD_Recuperada') IS NOT NULL DROP DATABASE BusRD_Recuperada;

DECLARE @datos SYSNAME, @log SYSNAME, @dir NVARCHAR(260), @t VARCHAR(23), @sql NVARCHAR(MAX);
SELECT @datos = name FROM master.sys.master_files WHERE database_id = DB_ID('BusRD') AND type_desc = 'ROWS';
SELECT @log   = name FROM master.sys.master_files WHERE database_id = DB_ID('BusRD') AND type_desc = 'LOG';
SET @dir = CONVERT(NVARCHAR(260), SERVERPROPERTY('InstanceDefaultDataPath'));
SELECT @t = CONVERT(VARCHAR(23), HoraAntesDelete, 121) FROM #punto;

SET @sql = N'
RESTORE DATABASE BusRD_Recuperada FROM DISK = N''C:\Backups\BusRD\BusRD_full.bak''
  WITH MOVE N''' + @datos + N''' TO N''' + @dir + N'BusRD_Recuperada.mdf'',
       MOVE N''' + @log   + N''' TO N''' + @dir + N'BusRD_Recuperada_log.ldf'', NORECOVERY, REPLACE;
RESTORE DATABASE BusRD_Recuperada FROM DISK = N''C:\Backups\BusRD\BusRD_diff.bak'' WITH NORECOVERY;
RESTORE LOG BusRD_Recuperada FROM DISK = N''C:\Backups\BusRD\BusRD_log1.trn'' WITH NORECOVERY;
RESTORE LOG BusRD_Recuperada FROM DISK = N''C:\Backups\BusRD\BusRD_tail.trn'' WITH STOPAT = ''' + @t + N''', RECOVERY;';
PRINT @sql;
EXEC sys.sp_executesql @sql;
GO

-- La base original quedo en RESTORING por el tail-log: se vuelve a poner en linea
RESTORE DATABASE BusRD WITH RECOVERY;
GO

/* ---------- 4. Verificacion ---------- */
-- 4.1 Los 8 boletos vendidos existen en la base recuperada
SELECT COUNT(*) AS Vendidos_En_Recuperada
FROM BusRD_Recuperada.dbo.Boletos b
WHERE b.BoletoID IN (SELECT BoletoID FROM #vendidos);          -- esperado: 8

-- 4.2 Los boletos borrados se recuperaron (comparar con el conteo previo al DELETE)
SELECT p.BoletosViajeAntes AS BoletosAntesDelDelete,
       (SELECT COUNT(*) FROM BusRD_Recuperada.dbo.Boletos b WHERE b.ViajeID = p.ViajeID) AS EnRecuperada,
       (SELECT COUNT(*) FROM BusRD.dbo.Boletos b WHERE b.ViajeID = p.ViajeID)            AS EnOriginalConElError
FROM #punto p;                                                  -- Recuperada = Antes, Original = 0
GO

/* ---------- 5. Politica de respaldos propuesta ----------
   | Tipo        | Frecuencia                    | Retencion           | Motivo |
   |-------------|-------------------------------|---------------------|--------|
   | FULL        | Semanal (domingo, 2:00 a.m.)  | 4 semanas           | Base de restauracion; ventana de baja venta |
   | DIFERENCIAL | Diario (2:00 a.m., lun-sab)   | 2 semanas           | Acorta la cadena de restauracion |
   | LOG         | Cada 15 minutos               | 14 dias             | Perder como maximo 15 min de ventas; permite STOPAT |
   | FULL mensual| Primer domingo de mes         | 12 meses (fuera del servidor) | Auditoria y recuperacion historica |
   Ademas: copiar los respaldos a otro servidor o nube, usar WITH CHECKSUM, probar
   una restauracion completa cada mes y vigilar el espacio del disco de respaldos. */

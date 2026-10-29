/* ---------------------------------------------------------
   BusRD - E1 Integridad del modelo

   Requisitos:
   - Base recien creada con 01_BusRD_base.sql, con la fecha
     del bloque de Boletos corregida a '2026-10-14T12:00:00'.
   - La demo de doble venta con sp_VenderBoleto_v0 se hace antes
     de correr este script. Al final se crea un indice que ya no
     permite vender el mismo asiento dos veces.

   Orden del script y por que importa:
   primero se limpian los datos y despues se crean las restricciones.
   Al reves no funciona: SQL Server revisa los datos existentes al
   crear una FK o un CHECK, y si encuentra uno que la viola, no la crea.
   --------------------------------------------------------- */
USE BusRD;
GO


/* =========================================================
   1. ASIENTOS VENDIDOS DOS VECES
   ========================================================= */

-- Diagnostico.
-- GROUP BY junta todas las filas del mismo viaje y asiento, y HAVING
-- filtra los grupos (WHERE filtra filas, HAVING filtra grupos ya armados).
-- Resultado esperado: 60 grupos con 2 boletos activos cada uno.
SELECT ViajeID, NumeroAsiento, COUNT(*) AS BoletosActivos
FROM dbo.Boletos
WHERE Estado = 'Activo'
GROUP BY ViajeID, NumeroAsiento
HAVING COUNT(*) > 1
ORDER BY ViajeID, NumeroAsiento;

-- Detalle de cada caso.
-- Con GROUP BY se pierde el detalle de cada boleto. Las funciones de
-- ventana (OVER) arman los mismos grupos con PARTITION BY pero sin
-- colapsar las filas, asi se ve cada boleto y su posicion en el grupo.
-- ROW_NUMBER numera por FechaVenta: el 1 es el que se vendio primero.
-- El BoletoID va de desempate por si dos ventas tienen la misma hora;
-- sin eso, el orden entre empates puede cambiar entre ejecuciones.
--
-- Regla: se queda el vendido primero. Cuando ese cliente compro, el
-- asiento estaba libre. En los 60 casos el segundo se vendio un minuto
-- despues y por Web: es justo la carrera entre taquilla y web.
WITH Activos AS (
    SELECT BoletoID, ViajeID, NumeroAsiento, FechaVenta, Canal,
           COUNT(*)     OVER (PARTITION BY ViajeID, NumeroAsiento) AS Cantidad,
           ROW_NUMBER() OVER (PARTITION BY ViajeID, NumeroAsiento
                              ORDER BY FechaVenta, BoletoID)      AS OrdenVenta
    FROM dbo.Boletos
    WHERE Estado = 'Activo'
)
SELECT ViajeID, NumeroAsiento, BoletoID, FechaVenta, Canal,
       CASE WHEN OrdenVenta = 1 THEN 'Se queda' ELSE 'Se anula' END AS Accion
FROM Activos
WHERE Cantidad > 1
ORDER BY ViajeID, NumeroAsiento, OrdenVenta;
GO

-- Lista de boletos a anular.
-- Se usa una tabla temporal (#) y no una variable de tabla (@) porque
-- la temporal vive toda la sesion y sobrevive a los GO. Una variable
-- de tabla muere al terminar el lote donde se declaro.
--
-- FIRST_VALUE trae el BoletoID de la primera fila de cada grupo, o sea
-- el que se queda. El ROWS UNBOUNDED PRECEDING no cambia el resultado,
-- pero sin el SQL Server usa por defecto RANGE, que es mas lento porque
-- trabaja con una tabla de trabajo en disco.
IF OBJECT_ID('tempdb..#Anular') IS NOT NULL DROP TABLE #Anular;

WITH Activos AS (
    SELECT BoletoID, ViajeID, NumeroAsiento,
           ROW_NUMBER() OVER (PARTITION BY ViajeID, NumeroAsiento
                              ORDER BY FechaVenta, BoletoID) AS OrdenVenta,
           FIRST_VALUE(BoletoID) OVER (PARTITION BY ViajeID, NumeroAsiento
                                       ORDER BY FechaVenta, BoletoID
                                       ROWS UNBOUNDED PRECEDING) AS BoletoQueSeQueda
    FROM dbo.Boletos
    WHERE Estado = 'Activo'
)
SELECT BoletoID AS BoletoAnulado, BoletoQueSeQueda, ViajeID, NumeroAsiento
INTO #Anular
FROM Activos
WHERE OrdenVenta > 1;

SELECT COUNT(*) AS BoletosAAnular FROM #Anular;   -- 60
GO

-- Tabla de auditoria.
-- Cuando se corrigen datos en produccion, el cambio tiene que poder
-- explicarse despues: que se toco, cuando y por que. Si un cliente
-- reclama por su boleto anulado, aqui esta la respuesta.
IF OBJECT_ID('dbo.Depuracion_BoletosDuplicados', 'U') IS NULL
CREATE TABLE dbo.Depuracion_BoletosDuplicados(
    BoletoAnulado     INT           NOT NULL PRIMARY KEY,
    BoletoQueSeQueda  INT           NOT NULL,
    ViajeID           INT           NOT NULL,
    NumeroAsiento     INT           NOT NULL,
    MontoReversado    DECIMAL(10,2) NULL,
    FechaDepuracion   DATETIME2(0)  NOT NULL
);
GO

-- Correccion.
-- Son tres cambios que dependen entre si: auditar, anular y reversar.
-- Si fallara el tercero con los dos primeros ya hechos, quedarian boletos
-- anulados con el dinero todavia cobrado. La transaccion evita ese estado
-- intermedio: o pasan los tres o no pasa ninguno.
--
-- XACT_ABORT ON hace que cualquier error dentro de la transaccion la deje
-- marcada para deshacerse. Sin esto, algunos errores solo cancelan la
-- instruccion que fallo y la transaccion sigue abierta con lo demas hecho.
--
-- En el CATCH se usa XACT_STATE() en vez de @@TRANCOUNT: devuelve 1 si la
-- transaccion esta activa, -1 si quedo marcada como fallida y 0 si no hay
-- ninguna. En los dos primeros casos hay que hacer ROLLBACK.
--
-- THROW sin parametros vuelve a lanzar el error original, con su numero
-- y mensaje, para que quien ejecuta el script vea que fue lo que fallo.
SET XACT_ABORT ON;

DECLARE @Ahora DATETIME2(0) = SYSDATETIME();

BEGIN TRY
    BEGIN TRANSACTION;

    -- Guardar el registro de auditoria antes de tocar los datos:
    -- (el monto queda guardado para comprobar despues el reverso)
    INSERT INTO dbo.Depuracion_BoletosDuplicados (
        BoletoAnulado,
        BoletoQueSeQueda,
        ViajeID,
        NumeroAsiento,
        MontoReversado,
        FechaDepuracion
    )
    SELECT a.BoletoAnulado,
           a.BoletoQueSeQueda,
           a.ViajeID,
           a.NumeroAsiento,
           (SELECT SUM(p.Monto)
            FROM dbo.Pagos p
            WHERE p.BoletoID = a.BoletoAnulado
              AND p.Monto > 0),
           @Ahora
    FROM #Anular a;

    -- Anular el boleto vendido despues:
    -- (no se borra: la venta existio, con su cliente, hora y canal, y
    -- borrarla es perder la evidencia del problema. UPDATE con JOIN es
    -- sintaxis propia de T-SQL; en otros motores se usa WHERE ... IN)
    UPDATE b
    SET Estado = 'Anulado'
    FROM dbo.Boletos b
    INNER JOIN #Anular a ON a.BoletoAnulado = b.BoletoID;

    -- Registrar la reversion del pago con monto negativo:
    -- (criterio contable: un movimiento no se borra, se contrarresta.
    -- El pago original de +420 se queda y entra uno de -420, saldo 0.
    -- Es la misma convencion de sp_AnularBoleto)
    INSERT INTO dbo.Pagos (
        BoletoID,
        Monto,
        Metodo,
        FechaPago
    )
    SELECT p.BoletoID,
           -p.Monto,
           p.Metodo,
           @Ahora
    FROM dbo.Pagos p
    INNER JOIN #Anular a ON a.BoletoAnulado = p.BoletoID
    WHERE p.Monto > 0;

    -- Confirmar la anulacion y su reversion:
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
    BEGIN
        ROLLBACK TRANSACTION;
    END;

    THROW;
END CATCH;
GO

-- Comprobacion.
-- Ningun asiento con dos activos (esperado: 0)
SELECT COUNT(*) AS AsientosConDobleVenta
FROM (SELECT ViajeID, NumeroAsiento
      FROM dbo.Boletos WHERE Estado = 'Activo'
      GROUP BY ViajeID, NumeroAsiento
      HAVING COUNT(*) > 1) x;

-- Todos los anulados con saldo 0 (esperado: ninguna fila)
SELECT d.BoletoAnulado, SUM(p.Monto) AS Saldo
FROM dbo.Depuracion_BoletosDuplicados d
JOIN dbo.Pagos p ON p.BoletoID = d.BoletoAnulado
GROUP BY d.BoletoAnulado
HAVING SUM(p.Monto) <> 0;
GO


/* =========================================================
   2. PAGOS HUERFANOS
   ========================================================= */

-- Diagnostico.
-- Se usa NOT EXISTS y no NOT IN a proposito. Si la subconsulta de un
-- NOT IN devuelve aunque sea un NULL, la condicion nunca es verdadera y
-- la consulta devuelve cero filas sin dar error. NOT EXISTS no tiene
-- ese problema. Aqui no hay NULLs, pero es un buen habito
-- (la consulta C1 del script 03 usa NOT IN).
--
-- Resultado esperado: 15 pagos de 300 en efectivo, BoletoID 900001 a 900015.
SELECT p.PagoID, p.BoletoID, p.Monto, p.Metodo, p.FechaPago
FROM dbo.Pagos p
WHERE NOT EXISTS (SELECT 1 FROM dbo.Boletos b WHERE b.BoletoID = p.BoletoID)
ORDER BY p.PagoID;
GO

-- Tabla de depuracion.
-- Estos pagos no se pueden reparar: no hay ningun dato que diga a que
-- venta pertenecen. Pero son RD$4,500 cobrados, asi que no se tiran.
-- Se sacan de Pagos (si no, la FK no se puede crear) y se guardan
-- aparte para que contabilidad los concilie.
IF OBJECT_ID('dbo.Depuracion_PagosHuerfanos', 'U') IS NULL
CREATE TABLE dbo.Depuracion_PagosHuerfanos(
    PagoID           INT           NOT NULL PRIMARY KEY,
    BoletoID         INT           NOT NULL,
    Monto            DECIMAL(10,2) NOT NULL,
    Metodo           VARCHAR(15)   NOT NULL,
    FechaPago        DATETIME2(0)  NOT NULL,
    FechaDepuracion  DATETIME2(0)  NOT NULL
);
GO

-- Mover y borrar en una sola instruccion.
-- La clausula OUTPUT da acceso a la pseudo-tabla "deleted", la misma que
-- usan los triggers, con las filas tal como estaban antes de borrarse.
-- Hacerlo con un INSERT y despues un DELETE por separado deja una ventana
-- en la que alguien podria cambiar los datos entre una y otra.
-- Detalle: la tabla destino de un OUTPUT INTO no puede tener triggers
-- ni FK activas. Por eso la de depuracion no tiene ninguna.
--
-- Una sola instruccion ya es atomica por si misma, pero se deja dentro de
-- la misma estructura de transaccion que el resto para mantener un solo
-- patron en todos los scripts del grupo.
SET XACT_ABORT ON;

BEGIN TRY
    BEGIN TRANSACTION;

    -- Mover los pagos huerfanos a depuracion y quitarlos de Pagos:
    DELETE p
    OUTPUT deleted.PagoID,
           deleted.BoletoID,
           deleted.Monto,
           deleted.Metodo,
           deleted.FechaPago,
           SYSDATETIME()
    INTO dbo.Depuracion_PagosHuerfanos (
        PagoID,
        BoletoID,
        Monto,
        Metodo,
        FechaPago,
        FechaDepuracion
    )
    FROM dbo.Pagos p
    WHERE NOT EXISTS (SELECT 1
                      FROM dbo.Boletos b
                      WHERE b.BoletoID = p.BoletoID);

    -- Confirmar el movimiento:
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0
    BEGIN
        ROLLBACK TRANSACTION;
    END;

    THROW;
END CATCH;
GO

-- Comprobacion: 0 en Pagos y 15 en depuracion
SELECT
    (SELECT COUNT(*) FROM dbo.Pagos p
     WHERE NOT EXISTS (SELECT 1 FROM dbo.Boletos b
                       WHERE b.BoletoID = p.BoletoID))  AS HuerfanosEnPagos,
    (SELECT COUNT(*) FROM dbo.Depuracion_PagosHuerfanos) AS MovidosADepuracion;
GO


/* =========================================================
   3. RESTRICCIONES
   ========================================================= */

-- Estado inicial: ninguna FK, CHECK ni UNIQUE.
SELECT
    (SELECT COUNT(*) FROM sys.foreign_keys)                      AS FK,
    (SELECT COUNT(*) FROM sys.check_constraints)                 AS CHK,
    (SELECT COUNT(*) FROM sys.key_constraints WHERE type = 'UQ') AS UQ;

-- Sin reglas, la base acepta cualquier cosa. Los tres cambios entran
-- sin error; el ROLLBACK los deshace para no ensuciar la base.
BEGIN TRANSACTION;
    INSERT dbo.Pagos(BoletoID, Monto, Metodo, FechaPago)
    VALUES (999999, 300, 'Efectivo', SYSDATETIME());     -- pago de un boleto que no existe
    UPDATE TOP (1) dbo.Boletos SET Canal = 'Telefono';     -- canal inventado
    UPDATE TOP (1) dbo.Boletos SET Precio = 0;             -- boleto gratis
    PRINT 'Sin restricciones: los 3 cambios se aceptaron (y se deshacen)';
ROLLBACK TRANSACTION;
GO

-- Llaves foraneas.
-- WITH CHECK obliga a SQL Server a revisar las filas que ya existen.
-- Con WITH NOCHECK la FK se crea igual pero solo vigila los datos nuevos,
-- y queda marcada como "no confiable": el optimizador no la usa para
-- simplificar planes (por ejemplo, para saltarse un JOIN que la FK
-- garantiza que siempre encuentra pareja).
--
-- Sin ON DELETE CASCADE, a proposito. Con cascada, borrar un boleto
-- borraria tambien su pago sin avisar. Sin ella, ese DELETE falla, que
-- es justo lo que hacia falta cuando alguien borro boletos por error.
--
-- Una FK no crea un indice sobre la columna, a diferencia de una PK o
-- un UNIQUE. Indexar Boletos.ClienteID o Pagos.BoletoID es parte de E3.
ALTER TABLE dbo.Asientos WITH CHECK ADD CONSTRAINT FK_Asientos_Autobuses
    FOREIGN KEY (AutobusID) REFERENCES dbo.Autobuses(AutobusID);
ALTER TABLE dbo.Viajes   WITH CHECK ADD CONSTRAINT FK_Viajes_Rutas
    FOREIGN KEY (RutaID) REFERENCES dbo.Rutas(RutaID);
ALTER TABLE dbo.Viajes   WITH CHECK ADD CONSTRAINT FK_Viajes_Autobuses
    FOREIGN KEY (AutobusID) REFERENCES dbo.Autobuses(AutobusID);
ALTER TABLE dbo.Boletos  WITH CHECK ADD CONSTRAINT FK_Boletos_Viajes
    FOREIGN KEY (ViajeID) REFERENCES dbo.Viajes(ViajeID);
ALTER TABLE dbo.Boletos  WITH CHECK ADD CONSTRAINT FK_Boletos_Clientes
    FOREIGN KEY (ClienteID) REFERENCES dbo.Clientes(ClienteID);
ALTER TABLE dbo.Pagos    WITH CHECK ADD CONSTRAINT FK_Pagos_Boletos
    FOREIGN KEY (BoletoID) REFERENCES dbo.Boletos(BoletoID);

-- La relacion que falta: Boletos -> Asientos.
-- La PK de Asientos es (AutobusID, NumeroAsiento) y una FK tiene que
-- apuntar a la llave completa. Boletos solo tiene NumeroAsiento; el
-- autobus sale de Viajes. Una FK no puede pasar por una tercera tabla,
-- asi que esa validacion queda en sp_VenderBoleto.
GO

-- CHECK de dominio: solo los valores que maneja el negocio.
-- Ademas de bloquear valores inventados, atrapa errores de escritura
-- como 'activo', 'Activo ' o 'Taquila', que antes entraban sin problema
-- y despues no aparecian en ningun reporte.
ALTER TABLE dbo.Boletos   WITH CHECK ADD CONSTRAINT CK_Boletos_Estado     CHECK (Estado IN ('Activo','Anulado'));
ALTER TABLE dbo.Boletos   WITH CHECK ADD CONSTRAINT CK_Boletos_Canal      CHECK (Canal  IN ('Taquilla','Web'));
ALTER TABLE dbo.Pagos     WITH CHECK ADD CONSTRAINT CK_Pagos_Metodo       CHECK (Metodo IN ('Efectivo','Tarjeta','Transferencia'));
ALTER TABLE dbo.Viajes    WITH CHECK ADD CONSTRAINT CK_Viajes_Estado      CHECK (Estado IN ('Programado','Completado','Cancelado'));
ALTER TABLE dbo.Autobuses WITH CHECK ADD CONSTRAINT CK_Autobuses_Tipo     CHECK (Tipo   IN ('Estandar','Ejecutivo'));
ALTER TABLE dbo.Asientos  WITH CHECK ADD CONSTRAINT CK_Asientos_Ubicacion CHECK (Ubicacion IN ('Ventana','Pasillo'));
GO

-- CHECK de rango.
-- El tope de 5,000 no es un precio real (el mas caro hoy es 550). Sirve
-- para atrapar un cero de mas al digitar: 4,200 en vez de 420 pasa,
-- 42,000 no.
-- Monto acepta negativos por los reversos de anulacion; lo unico que no
-- acepta es 0, porque un pago de cero no representa nada.
ALTER TABLE dbo.Boletos   WITH CHECK ADD CONSTRAINT CK_Boletos_Precio      CHECK (Precio > 0 AND Precio <= 5000);
ALTER TABLE dbo.Pagos     WITH CHECK ADD CONSTRAINT CK_Pagos_Monto         CHECK (Monto <> 0 AND Monto BETWEEN -5000 AND 5000);
ALTER TABLE dbo.Autobuses WITH CHECK ADD CONSTRAINT CK_Autobuses_Capacidad CHECK (Capacidad BETWEEN 1 AND 60);
ALTER TABLE dbo.Asientos  WITH CHECK ADD CONSTRAINT CK_Asientos_Numero     CHECK (NumeroAsiento BETWEEN 1 AND 60);
ALTER TABLE dbo.Rutas     WITH CHECK ADD CONSTRAINT CK_Rutas_DistanciaKm   CHECK (DistanciaKm > 0);
ALTER TABLE dbo.Rutas     WITH CHECK ADD CONSTRAINT CK_Rutas_PrecioBase    CHECK (PrecioBase > 0 AND PrecioBase <= 5000);
ALTER TABLE dbo.Rutas     WITH CHECK ADD CONSTRAINT CK_Rutas_OrigenDestino CHECK (Origen <> Destino);

-- Cedula: 11 digitos y nada mas.
-- '[^0-9]' significa "cualquier caracter que no sea un digito", asi que
-- la condicion se lee: no puede contener ningun no-digito.
-- Truco del CHAR(11): si la cedula viene corta, SQL Server la rellena con
-- espacios hasta 11, y el espacio no es digito. Asi la misma regla valida
-- el largo. Y como ya no puede haber espacios, el LTRIM(RTRIM()) de la
-- consulta C2 sobra (y quitarlo es lo que la vuelve sargable en E3).
ALTER TABLE dbo.Clientes  WITH CHECK ADD CONSTRAINT CK_Clientes_Cedula     CHECK (Cedula NOT LIKE '%[^0-9]%');

-- Email: un CHECK que evalua NULL no falla, porque la condicion da
-- "desconocido" y solo se rechaza lo que da falso. El "IS NULL OR" no
-- hace falta para que funcione, pero deja claro que el email es opcional.
ALTER TABLE dbo.Clientes  WITH CHECK ADD CONSTRAINT CK_Clientes_Email      CHECK (Email IS NULL OR Email LIKE '%_@_%._%');
GO

-- Unicidad.
-- Cada UNIQUE crea un indice por debajo para poder comprobar rapido si el
-- valor ya existe. El de Cedula es el que va a usar la consulta C2 cuando
-- busque un cliente.
-- Diferencia con el estandar SQL: en SQL Server un UNIQUE admite un solo
-- NULL en la columna. Aqui no afecta porque Cedula y Placa son NOT NULL.
ALTER TABLE dbo.Clientes  ADD CONSTRAINT UQ_Clientes_Cedula UNIQUE (Cedula);
ALTER TABLE dbo.Autobuses ADD CONSTRAINT UQ_Autobuses_Placa UNIQUE (Placa);
GO

-- Inventario de lo creado.
-- NoConfiable tiene que salir en 0 en todas las FK y CHECK. Un 1
-- significaria que se creo con NOCHECK o que alguien la deshabilito.
SELECT OBJECT_NAME(parent_object_id) AS Tabla, name AS Restriccion,
       type_desc AS Tipo, CAST(is_not_trusted AS INT) AS NoConfiable
FROM sys.foreign_keys
UNION ALL
SELECT OBJECT_NAME(parent_object_id), name, type_desc, CAST(is_not_trusted AS INT)
FROM sys.check_constraints
UNION ALL
SELECT OBJECT_NAME(parent_object_id), name, type_desc, NULL
FROM sys.key_constraints WHERE type = 'UQ'
ORDER BY Tabla, Tipo, Restriccion;
GO

-- Los mismos cambios de antes. Ahora cada uno tiene que fallar.
-- No hace falta transaccion: si la instruccion falla, no cambia nada.
BEGIN TRY
    INSERT dbo.Pagos(BoletoID, Monto, Metodo, FechaPago)
    VALUES (999999, 300, 'Efectivo', SYSDATETIME());
END TRY
BEGIN CATCH PRINT 'Rechazado, pago sin boleto: ' + ERROR_MESSAGE(); END CATCH;

BEGIN TRY
    UPDATE TOP (1) dbo.Boletos SET Canal = 'Telefono';
END TRY
BEGIN CATCH PRINT 'Rechazado, canal invalido: ' + ERROR_MESSAGE(); END CATCH;

BEGIN TRY
    UPDATE TOP (1) dbo.Boletos SET Precio = 0;
END TRY
BEGIN CATCH PRINT 'Rechazado, precio 0: ' + ERROR_MESSAGE(); END CATCH;

BEGIN TRY
    INSERT dbo.Clientes(Cedula, Nombre, Apellido, FechaRegistro)
    SELECT TOP (1) Cedula, 'Prueba', 'Repetida', CAST(SYSDATETIME() AS DATE) FROM dbo.Clientes;
END TRY
BEGIN CATCH PRINT 'Rechazado, cedula repetida: ' + ERROR_MESSAGE(); END CATCH;
GO


/* =========================================================
   4. UN SOLO BOLETO ACTIVO POR ASIENTO
   ========================================================= */

-- La limpieza arreglo los 60 casos, pero nada impide que vuelva a pasar.
-- Prueba: un segundo boleto activo en un asiento ocupado entra sin error.
DECLARE @v INT, @a INT;
SELECT TOP (1) @v = ViajeID, @a = NumeroAsiento
FROM dbo.Boletos WHERE Estado = 'Activo' ORDER BY BoletoID;

BEGIN TRANSACTION;
    INSERT dbo.Boletos(ViajeID, NumeroAsiento, ClienteID, FechaVenta, Canal, Precio, Estado)
    VALUES (@v, @a, 1, SYSDATETIME(), 'Web', 300, 'Activo');

    SELECT COUNT(*) AS ActivosEnEseAsiento   -- 2: la base lo acepto
    FROM dbo.Boletos
    WHERE ViajeID = @v AND NumeroAsiento = @a AND Estado = 'Activo';
ROLLBACK TRANSACTION;
GO

-- Indice unico filtrado.
-- El WHERE del indice hace que solo contenga las filas con Estado =
-- 'Activo'. La unicidad se aplica solo entre esas filas.
--
-- Por que no un UNIQUE (ViajeID, NumeroAsiento) normal: el boleto anulado
-- sigue en la tabla, y un UNIQUE normal lo contaria. El asiento quedaria
-- bloqueado para siempre aunque nadie lo este usando. Con el filtro, al
-- anular un boleto este sale del indice y el asiento queda libre.
--
-- Los indices filtrados exigen ANSI_NULLS y QUOTED_IDENTIFIER en ON en
-- toda sesion que modifique la tabla. SSMS los trae en ON por defecto.
-- Un procedimiento guarda el valor que tenia al crearse, asi que si
-- alguien crea sp_VenderBoleto con QUOTED_IDENTIFIER en OFF, sus INSERT
-- van a fallar con este indice.
--
-- Efecto extra: este indice es justo el que necesita la consulta C1
-- (asientos ocupados de un viaje filtrando por Estado = 'Activo').
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE UNIQUE NONCLUSTERED INDEX UX_Boletos_Viaje_Asiento_Activo
    ON dbo.Boletos(ViajeID, NumeroAsiento)
    WHERE Estado = 'Activo';
GO

-- El mismo INSERT de antes ahora falla.
-- El error es el 2601 (llave duplicada en un indice unico). Si la regla
-- fuera una restriccion UNIQUE, el error seria el 2627. Mismo efecto,
-- distinto origen.
DECLARE @v INT, @a INT;
SELECT TOP (1) @v = ViajeID, @a = NumeroAsiento
FROM dbo.Boletos WHERE Estado = 'Activo' ORDER BY BoletoID;

BEGIN TRY
    INSERT dbo.Boletos(ViajeID, NumeroAsiento, ClienteID, FechaVenta, Canal, Precio, Estado)
    VALUES (@v, @a, 1, SYSDATETIME(), 'Web', 300, 'Activo');
    PRINT 'Se acepto: revisar el indice';
END TRY
BEGIN CATCH
    PRINT CONCAT('Rechazado, error ', ERROR_NUMBER(), ': ', ERROR_MESSAGE());
END CATCH;
GO

-- La otra mitad de la prueba: un asiento cuyo unico boleto esta anulado
-- si tiene que poder venderse. Se busca uno, se vende y se deshace.
DECLARE @v INT, @a INT;
SELECT TOP (1) @v = b.ViajeID, @a = b.NumeroAsiento
FROM dbo.Boletos b
WHERE b.Estado = 'Anulado'
  AND NOT EXISTS (SELECT 1 FROM dbo.Boletos x
                  WHERE x.ViajeID = b.ViajeID AND x.NumeroAsiento = b.NumeroAsiento
                    AND x.Estado = 'Activo')
ORDER BY b.BoletoID;

BEGIN TRANSACTION;
    INSERT dbo.Boletos(ViajeID, NumeroAsiento, ClienteID, FechaVenta, Canal, Precio, Estado)
    VALUES (@v, @a, 1, SYSDATETIME(), 'Taquilla', 300, 'Activo');
    PRINT CONCAT('Reventa permitida: viaje ', @v, ', asiento ', @a, ' (se deshace)');
ROLLBACK TRANSACTION;
GO

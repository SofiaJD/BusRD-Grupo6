--Procedimiento almacenado para evitar la venta de boletos duplicados: 

USE BusRD;
GO

CREATE OR ALTER PROCEDURE dbo.sp_VenderBoleto
    @ViajeID INT,
    @NumeroAsiento INT,
    @ClienteID INT,
    @Canal VARCHAR(10),
    @Metodo VARCHAR(15),
    @BoletoID INT OUTPUT,
    @SimularDemora BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @AutobusID INT;
    DECLARE @Precio DECIMAL(10,2);
    DECLARE @EstadoViaje VARCHAR(20);

    SET @BoletoID = NULL;

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Validar que el viaje exista y esté programado:
        SELECT
            @AutobusID = v.AutobusID,
            @Precio = r.PrecioBase,
            @EstadoViaje = v.Estado
        FROM dbo.Viajes AS v
        INNER JOIN dbo.Rutas AS r
            ON r.RutaID = v.RutaID
        WHERE v.ViajeID = @ViajeID;

        IF @EstadoViaje IS NULL
        BEGIN
            THROW 50001, 'El viaje indicado no existe.', 1;
        END;

        IF @EstadoViaje <> 'Programado'
        BEGIN
            THROW 50002, 'El viaje no esta programado.', 1;
        END;

        -- Validar que el asiento pertenezca al autobus del viaje:
        IF NOT EXISTS (
            SELECT 1
            FROM dbo.Asientos
            WHERE AutobusID = @AutobusID
              AND NumeroAsiento = @NumeroAsiento
        )
        BEGIN
            THROW 50003,
                'El asiento no pertenece al autobus del viaje.',
                1;
        END;

        -- Validar que el cliente exista:
        IF NOT EXISTS (
            SELECT 1
            FROM dbo.Clientes
            WHERE ClienteID = @ClienteID
        )
        BEGIN
            THROW 50004, 'El cliente indicado no existe.', 1;
        END;

        -- Validar que el canal de venta sea valido:
        IF @Canal IS NULL
           OR @Canal NOT IN ('Taquilla', 'Web')
        BEGIN
            THROW 50005, 'El canal de venta no es valido.', 1;
        END;

        -- Validar que el metodo de pago sea valido:
        IF @Metodo IS NULL
           OR @Metodo NOT IN (
               'Efectivo', 'Tarjeta', 'Transferencia'
           )
        BEGIN
            THROW 50006, 'El metodo de pago no es valido.', 1;
        END;

        -- Comprobar disponibilidad y proteger el asiento contra ventas simultáneas:
        IF EXISTS (
            SELECT 1
            FROM dbo.Boletos WITH (UPDLOCK, HOLDLOCK)
            WHERE ViajeID = @ViajeID
              AND NumeroAsiento = @NumeroAsiento
              AND Estado = 'Activo'
        )
        BEGIN
            THROW 50007,
                'El asiento ya tiene un boleto activo para este viaje.',
                1;
        END;

        -- Demora opcional para demostrar la concurrencia.
        IF @SimularDemora = 1
        BEGIN
            WAITFOR DELAY '00:00:10';
        END;

        -- Registro del boleto:
        INSERT INTO dbo.Boletos (
            ViajeID,
            NumeroAsiento,
            ClienteID,
            FechaVenta,
            Canal,
            Precio,
            Estado
        )
        VALUES (
            @ViajeID,
            @NumeroAsiento,
            @ClienteID,
            GETDATE(),
            @Canal,
            @Precio,
            'Activo'
        );

        SET @BoletoID = CONVERT(INT, SCOPE_IDENTITY());

        -- Registro del pago dentro de la misma transacción:
        INSERT INTO dbo.Pagos (
            BoletoID,
            Monto,
            Metodo,
            FechaPago
        )
        VALUES (
            @BoletoID,
            @Precio,
            @Metodo,
            GETDATE()
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
        BEGIN
            ROLLBACK TRANSACTION;
        END;

        SET @BoletoID = NULL;

        THROW;
    END CATCH;
END;
GO

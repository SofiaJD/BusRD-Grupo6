-- Procedimiento almacenado para anular un boleto vendido: 

USE BusRD;
GO

CREATE OR ALTER PROCEDURE dbo.sp_AnularBoleto
    @BoletoID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Estado VARCHAR(20);
    DECLARE @Monto DECIMAL(10,2);
    DECLARE @Metodo VARCHAR(15);

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Buscar y bloquear el boleto que se desea anular:
        SELECT @Estado = Estado
        FROM dbo.Boletos WITH (UPDLOCK, HOLDLOCK)
        WHERE BoletoID = @BoletoID;

        -- Validar que el boleto exista:
        IF @Estado IS NULL
        BEGIN
            THROW 50101, 'El boleto indicado no existe.', 1;
        END;

        -- Validar que el boleto esté activo:
        IF @Estado <> 'Activo'
        BEGIN
            THROW 50102, 'El boleto no esta activo o ya fue anulado.', 1;
        END;

        -- Obtener el pago que se va a revertir:
        SELECT TOP (1)
            @Monto = Monto,
            @Metodo = Metodo
        FROM dbo.Pagos
        WHERE BoletoID = @BoletoID
          AND Monto > 0
        ORDER BY FechaPago DESC, PagoID DESC;

        -- Verificar que exista un pago:
        IF @Monto IS NULL
        BEGIN
            THROW 50103, 'No existe un pago registrado para el boleto.', 1;
        END;

        -- Cambiar el estado del boleto:
        UPDATE dbo.Boletos
        SET Estado = 'Anulado'
        WHERE BoletoID = @BoletoID;

        -- Registrar la reversión del pago con monto negativo:
        INSERT INTO dbo.Pagos (
            BoletoID,
            Monto,
            Metodo,
            FechaPago
        )
        VALUES (
            @BoletoID,
            -@Monto,
            @Metodo,
            GETDATE()
        );

        -- Confirmar la anulación y su reversión:
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
        BEGIN
            ROLLBACK TRANSACTION;
        END;

        THROW;
    END CATCH;
END;
GO

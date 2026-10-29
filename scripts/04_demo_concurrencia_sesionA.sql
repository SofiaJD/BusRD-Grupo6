-- Sesión A del demo para probar concurrencia: 
USE BusRD;
GO

DECLARE @NuevoBoletoID INT;

EXEC dbo.sp_VenderBoleto
    @ViajeID = 1329,
    @NumeroAsiento = 2,
    @ClienteID = 1,
    @Canal = 'Taquilla',
    @Metodo = 'Efectivo',
    @BoletoID = @NuevoBoletoID OUTPUT,
    @SimularDemora = 1;

SELECT @NuevoBoletoID AS BoletoIDGenerado;
GO

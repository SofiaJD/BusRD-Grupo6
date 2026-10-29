--Sesión B del demo para probar concurrencia: 
USE BusRD;
GO

DECLARE @NuevoBoletoID INT;

EXEC dbo.sp_VenderBoleto
    @ViajeID = 1329,
    @NumeroAsiento = 2,
    @ClienteID = 2,
    @Canal = 'Web',
    @Metodo = 'Tarjeta',
    @BoletoID = @NuevoBoletoID OUTPUT,
    @SimularDemora = 0;

SELECT @NuevoBoletoID AS BoletoIDGenerado;
GO

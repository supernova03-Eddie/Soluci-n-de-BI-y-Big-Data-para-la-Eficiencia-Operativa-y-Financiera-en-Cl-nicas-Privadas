-- =======================================================================
-- PROYECTO BI - RED DE CLÍNICAS PRIVADAS (SUSALUD)
-- CURSO: BASE DE DATOS AVANZADAS Y BIG DATA
-- =======================================================================

-- 1. CREACIÓN DE LA BASE DE DATOS (DATA WAREHOUSE)
CREATE DATABASE DW_Clinicas_Privadas;
GO

USE DW_Clinicas_Privadas;
GO

-- =======================================================================
-- 2. CREACIÓN DE TABLAS DE DIMENSIONES
-- =======================================================================

-- Dimensión Tiempo (Obligatoria para Power BI y DAX)
CREATE TABLE Dim_Tiempo (
    Id_Tiempo INT PRIMARY KEY, -- Formato: AAAAMMDD (Ej: 20250901)
    Fecha DATE NOT NULL,
    Anio INT NOT NULL,
    Mes INT NOT NULL,
    Nombre_Mes VARCHAR(20) NOT NULL,
    Trimestre INT NOT NULL
);
GO

-- Dimensión IPRESS (Clínicas y Centros Médicos)
CREATE TABLE Dim_IPRESS (
    Id_IPRESS INT IDENTITY(1,1) PRIMARY KEY, -- Llave subrogada autoincremental
    Codigo_IPRESS_Cripto VARCHAR(8) NOT NULL UNIQUE, -- Llave natural de SUSALUD
    Nombre_IPRESS VARCHAR(150), -- Se llenará luego cruzando con RENIPRESS
    Ubigeo_IPRESS VARCHAR(6)
);
GO

-- Dimensión Paciente
CREATE TABLE Dim_Paciente (
    Id_Paciente INT IDENTITY(1,1) PRIMARY KEY,
    Numero_Doc_Cripto VARCHAR(15) NOT NULL,
    Tipo_Afiliacion VARCHAR(50),
    Sexo_Paciente CHAR(1),
    Ubigeo_Afiliado VARCHAR(6)
);
GO

-- Dimensión Diagnóstico (CIE-10)
CREATE TABLE Dim_Diagnostico (
    Id_Diagnostico INT IDENTITY(1,1) PRIMARY KEY,
    Codigo_CIE10 VARCHAR(5) NOT NULL UNIQUE, -- Campo PRIMER_DIAGNOSTICO de SUSALUD
    Descripcion_Diagnostico VARCHAR(200)
);
GO

-- =======================================================================
-- 3. CREACIÓN DE LA TABLA DE HECHOS (FACT TABLE)
-- =======================================================================

CREATE TABLE Fact_Atenciones (
    Id_Atencion INT IDENTITY(1,1) PRIMARY KEY,
    
    -- Llaves Foráneas conectadas a las Dimensiones
    Id_Tiempo INT FOREIGN KEY REFERENCES Dim_Tiempo(Id_Tiempo),
    Id_IPRESS INT FOREIGN KEY REFERENCES Dim_IPRESS(Id_IPRESS),
    Id_Paciente INT FOREIGN KEY REFERENCES Dim_Paciente(Id_Paciente),
    Id_Diagnostico INT FOREIGN KEY REFERENCES Dim_Diagnostico(Id_Diagnostico),
    
    -- Atributos degenerados (Datos de seguimiento transaccional)
    Correlativo_Atencion VARCHAR(5),
    Tipo_Hospitalizacion CHAR(1), -- 'C' Clínica, 'Q' Quirúrgica, 'N' No aplica
    
    -- Métricas / Medidas (Para los KPIs)
    Nro_Dias_Estancia INT DEFAULT 0,
    Gasto_Farmacia DECIMAL(12,2) DEFAULT 0.00,
    Gasto_Examenes_Lab DECIMAL(12,2) DEFAULT 0.00,
    Gasto_Examenes_Img DECIMAL(12,2) DEFAULT 0.00,
    Total_Gastos_Cubiertos DECIMAL(12,2) DEFAULT 0.00,
    Total_Liquidado DECIMAL(12,2) DEFAULT 0.00
);
GO

PRINT '¡Data Warehouse DW_Clinicas_Privadas creado exitosamente con su Esquema Estrella!';




USE DW_Clinicas_Privadas;
GO

-- Tabla de LOG para Auditoria

IF OBJECT_ID('dbo.Log_ETL_Errores', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.Log_ETL_Errores (
        Id_Log INT IDENTITY(1,1) PRIMARY KEY,
        Fecha_Error DATETIME DEFAULT GETDATE(),
        Nombre_Procedimiento VARCHAR(100),
        Numero_Error INT,
        Mensaje_Error VARCHAR(MAX)
    );
END;
GO

-- Procedimiento almacenado para el ETL

CREATE OR ALTER PROCEDURE dbo.sp_Cargar_DW_Atenciones
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Filas_Staging INT = 0;
    DECLARE @Filas_Cargadas INT = 0;
    DECLARE @Total_Liquidado_Staging DECIMAL(18,2) = 0.00;
    DECLARE @Total_Liquidado_DW DECIMAL(18,2) = 0.00;

    BEGIN TRY
        BEGIN TRANSACTION;

        PRINT '>>> [ETL] Iniciando proceso de carga automatizado...';

        INSERT INTO Dim_IPRESS (Codigo_IPRESS_Cripto, Nombre_IPRESS)
        SELECT DISTINCT 
            TRIM(s.CODIGO_IPRESS_CRIPTO),
            ISNULL(TRIM(s.NOMBRE_IPRESS), 'Establecimiento No Especificado')
        FROM Staging_Atenciones s
        WHERE s.CODIGO_IPRESS_CRIPTO IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM Dim_IPRESS d 
              WHERE d.Codigo_IPRESS_Cripto = TRIM(s.CODIGO_IPRESS_CRIPTO)
          );

        INSERT INTO Dim_Diagnostico (Codigo_CIE10, Descripcion_Diagnostico)
        SELECT DISTINCT 
            UPPER(TRIM(s.PRIMER_DIAGNOSTICO)),
            'Diagnóstico Registrado en Portal SUSALUD'
        FROM Staging_Atenciones s
        WHERE s.PRIMER_DIAGNOSTICO IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM Dim_Diagnostico d 
              WHERE d.Codigo_CIE10 = UPPER(TRIM(s.PRIMER_DIAGNOSTICO))
          );

        INSERT INTO Dim_Paciente (Numero_Doc_Cripto, Sexo_Paciente)
        SELECT DISTINCT 
            TRIM(s.NUMERO_DOC_IDENTIDAD_CRIPTO),
            ISNULL(s.SEXO, 'U')
        FROM Staging_Atenciones s
        WHERE s.NUMERO_DOC_IDENTIDAD_CRIPTO IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM Dim_Paciente d 
              WHERE d.Numero_Doc_Cripto = TRIM(s.NUMERO_DOC_IDENTIDAD_CRIPTO)
          );

        INSERT INTO Fact_Atenciones (
            Id_Tiempo, Id_IPRESS, Id_Paciente, Id_Diagnostico,
            Correlativo_Atencion, Tipo_Hospitalizacion, Nro_Dias_Estancia,
            Gasto_Farmacia, Gasto_Examenes_Lab, Gasto_Examenes_Img,
            Total_Gastos_Cubiertos, Total_Liquidado
        )
        SELECT 
            TRY_CAST(CONVERT(VARCHAR(8), CAST(s.FECHA_PRESTACION AS DATE), 112) AS INT) AS Id_Tiempo,
            i.Id_IPRESS,
            p.Id_Paciente,
            d.Id_Diagnostico,
            s.CORRELATIVO_ATENCION,
            s.TIPO_HOSPITALIZACION,
            ISNULL(TRY_CAST(s.NRO_DIAS_ESTANCIA AS INT), 0),
            ISNULL(TRY_CAST(s.GASTO_EN_FARMACIA AS DECIMAL(12,2)), 0.00),
            ISNULL(TRY_CAST(s.GASTO_EXAMENES_LAB AS DECIMAL(12,2)), 0.00),
            ISNULL(TRY_CAST(s.GASTO_EXAMENES_IMG AS DECIMAL(12,2)), 0.00),
            ISNULL(TRY_CAST(s.TOTAL_GASTOS_CUBIERTOS AS DECIMAL(12,2)), 0.00),
            ISNULL(TRY_CAST(s.TOTAL_LIQUIDADO AS DECIMAL(12,2)), 0.00)
        FROM Staging_Atenciones s
        INNER JOIN Dim_IPRESS i ON i.Codigo_IPRESS_Cripto = TRIM(s.CODIGO_IPRESS_CRIPTO)
        INNER JOIN Dim_Paciente p ON p.Numero_Doc_Cripto = TRIM(s.NUMERO_DOC_IDENTIDAD_CRIPTO)
        INNER JOIN Dim_Diagnostico d ON d.Codigo_CIE10 = UPPER(TRIM(s.PRIMER_DIAGNOSTICO));

        SELECT @Filas_Staging = COUNT(*), @Total_Liquidado_Staging = SUM(ISNULL(TRY_CAST(TOTAL_LIQUIDADO AS DECIMAL(12,2)), 0.00))
        FROM Staging_Atenciones;

        SELECT @Filas_Cargadas = COUNT(*), @Total_Liquidado_DW = SUM(Total_Liquidado)
        FROM Fact_Atenciones;

        IF (@Total_Liquidado_Staging <> @Total_Liquidado_DW)
        BEGIN
            RAISERROR('Descuadre en reconciliación de datos: los montos liquidados no coinciden.', 16, 1);
        END

        COMMIT TRANSACTION;
        PRINT '>>> [ETL] Proceso finalizado y reconciliado con éxito.';

    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;

        -- Registrar el error en la tabla de Log
        INSERT INTO dbo.Log_ETL_Errores (Nombre_Procedimiento, Numero_Error, Mensaje_Error)
        VALUES ('sp_Cargar_DW_Atenciones', ERROR_NUMBER(), ERROR_MESSAGE());

        PRINT '>>> [ETL ERROR] Se produjo un error durante la ejecución. Ver detalles en Log_ETL_Errores.';
    END CATCH
END;
GO